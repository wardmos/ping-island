import Foundation

/// Cumulative token consumption parsed from a single Claude Code transcript
/// (`~/.claude/projects/<project>/<session-id>.jsonl`). Unlike Codex rollout
/// files, Claude transcripts store per-message `usage` objects rather than a
/// running total, so the loader sums every assistant message in the session.
struct ClaudeSessionTokenUsage: Equatable, Sendable {
    let sessionID: String
    let sourceFilePath: String?
    let capturedAt: Date?
    let fileSize: UInt64?
    let contentHash: String?
    let totals: AgentUsageTokenTotals

    init(
        sessionID: String,
        sourceFilePath: String? = nil,
        capturedAt: Date?,
        fileSize: UInt64? = nil,
        contentHash: String? = nil,
        totals: AgentUsageTokenTotals
    ) {
        self.sessionID = sessionID
        self.sourceFilePath = sourceFilePath
        self.capturedAt = capturedAt
        self.fileSize = fileSize
        self.contentHash = contentHash
        self.totals = totals
    }
}

enum ClaudeTokenUsageLoader {
    nonisolated static let defaultRootURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/projects", isDirectory: true)

    // Enumeration recurses into per-session `subagents/agent-*.jsonl`, so the
    // file count far exceeds the number of top-level sessions. The limit must
    // stay well above that or active sessions get dropped and tokens undercounted.
    private nonisolated static let defaultCandidateScanLimit = 4096
    private nonisolated static let defaultMaxBytesPerFile = 64 * 1024 * 1024
    private nonisolated static let cacheLock = NSLock()
    nonisolated(unsafe) private static var fileCache: [String: ClaudeSessionTokenUsage] = [:]

    private struct Candidate {
        let fileURL: URL
        let modifiedAt: Date
        let fileSize: UInt64
    }

    /// Sums per-session cumulative token usage across the most recently
    /// modified transcripts. Each call returns one entry per session file that
    /// has at least one assistant message carrying usage.
    nonisolated static func load(
        fromRootURL rootURL: URL = defaultRootURL,
        fileManager: FileManager = .default,
        candidateScanLimit: Int = defaultCandidateScanLimit,
        maxBytesPerFile: Int = defaultMaxBytesPerFile
    ) throws -> [ClaudeSessionTokenUsage] {
        guard fileManager.fileExists(atPath: rootURL.path),
              let enumerator = fileManager.enumerator(
                at: rootURL,
                includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey],
                options: [.skipsHiddenFiles]
              ) else {
            return []
        }

        var candidates: [Candidate] = []
        for case let fileURL as URL in enumerator {
            guard fileURL.pathExtension == "jsonl",
                  let resourceValues = try? fileURL.resourceValues(
                    forKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
                  ),
                  resourceValues.isRegularFile == true else {
                continue
            }

            candidates.append(
                Candidate(
                    fileURL: fileURL,
                    modifiedAt: resourceValues.contentModificationDate ?? .distantPast,
                    fileSize: UInt64(max(0, resourceValues.fileSize ?? 0))
                )
            )
        }

        let sortedCandidates = candidates.sorted { lhs, rhs in
            if lhs.modifiedAt == rhs.modifiedAt {
                return lhs.fileURL.path.localizedStandardCompare(rhs.fileURL.path) == .orderedDescending
            }
            return lhs.modifiedAt > rhs.modifiedAt
        }
        let limitedCandidates = Array(sortedCandidates.prefix(max(1, candidateScanLimit)))

        var sessions: [ClaudeSessionTokenUsage] = []
        for candidate in limitedCandidates {
            let fingerprint = fileFingerprint(for: candidate)
            if let cached = cachedSessionUsage(for: fingerprint) {
                sessions.append(cached)
                continue
            }

            let usage = sessionUsage(
                from: candidate.fileURL,
                modifiedAt: candidate.modifiedAt,
                fileSize: candidate.fileSize,
                maxBytes: maxBytesPerFile
            )
            cache(sessionUsage: usage, for: fingerprint)
            if let usage { sessions.append(usage) }
        }

        return sessions
    }

    private nonisolated static func sessionUsage(
        from fileURL: URL,
        modifiedAt: Date,
        fileSize: UInt64,
        maxBytes: Int
    ) -> ClaudeSessionTokenUsage? {
        // Whole-file read is required to keep the per-session sum monotonic
        // across refreshes. Skip pathologically large transcripts rather than
        // partial-read them, which would slide the summation window and break
        // the baseline delta computed by AgentUsageStore.
        guard fileSize > 0,
              maxBytes > 0,
              fileSize <= UInt64(maxBytes),
              let data = try? Data(contentsOf: fileURL) else {
            return nil
        }

        let contents = String(decoding: data, as: UTF8.self)

        var inputTokens = 0
        var cacheCreationTokens = 0
        var cacheReadTokens = 0
        var outputTokens = 0
        var latestTimestamp: Date?
        var seenMessageIDs = Set<String>()
        var sawUsage = false

        for line in contents.split(separator: "\n", omittingEmptySubsequences: true) {
            // Cheap pre-filter before paying for JSON parsing.
            guard line.contains("\"usage\""), line.contains("\"assistant\"") else {
                continue
            }
            guard let object = jsonObject(for: String(line)),
                  object["type"] as? String == "assistant",
                  let message = object["message"] as? [String: Any],
                  let usage = message["usage"] as? [String: Any] else {
                continue
            }

            // Guard against history that was copied into a resumed transcript:
            // the same assistant turn must not be summed twice within one file.
            if let id = string(from: object["requestId"])
                ?? string(from: object["uuid"])
                ?? string(from: message["id"]),
               !seenMessageIDs.insert(id).inserted {
                continue
            }

            inputTokens += integer(from: usage["input_tokens"]) ?? 0
            cacheCreationTokens += integer(from: usage["cache_creation_input_tokens"]) ?? 0
            cacheReadTokens += integer(from: usage["cache_read_input_tokens"]) ?? 0
            outputTokens += integer(from: usage["output_tokens"]) ?? 0
            sawUsage = true

            if let timestamp = timestamp(from: object["timestamp"]),
               latestTimestamp == nil || timestamp > latestTimestamp! {
                latestTimestamp = timestamp
            }
        }

        guard sawUsage else {
            return nil
        }

        // Keep cache traffic in its own buckets: cache reads dominate volume but
        // bill far below fresh input, so lumping them into `input` would wildly
        // overstate the cost estimate.
        let totals = AgentUsageTokenTotals(
            input: inputTokens,
            cacheWrite: cacheCreationTokens,
            cacheRead: cacheReadTokens,
            output: outputTokens,
            total: inputTokens + cacheCreationTokens + cacheReadTokens + outputTokens
        )
        guard totals.resolvedTotal > 0 else {
            return nil
        }

        return ClaudeSessionTokenUsage(
            sessionID: sessionID(for: fileURL),
            sourceFilePath: fileURL.path,
            capturedAt: latestTimestamp ?? modifiedAt,
            fileSize: UInt64(data.count),
            contentHash: fnv1aHashHex(for: data),
            totals: totals
        )
    }

    private nonisolated static func sessionID(for fileURL: URL) -> String {
        fileURL.deletingPathExtension().lastPathComponent
    }

    private nonisolated static func fileFingerprint(for candidate: Candidate) -> String {
        [
            candidate.fileURL.resolvingSymlinksInPath().path,
            String(candidate.modifiedAt.timeIntervalSinceReferenceDate),
            String(candidate.fileSize)
        ].joined(separator: "|")
    }

    private nonisolated static func cachedSessionUsage(for fingerprint: String) -> ClaudeSessionTokenUsage? {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return fileCache[fingerprint]
    }

    private nonisolated static func cache(sessionUsage: ClaudeSessionTokenUsage?, for fingerprint: String) {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if fileCache.count > 512 {
            fileCache.removeAll(keepingCapacity: true)
        }
        if let sessionUsage {
            fileCache[fingerprint] = sessionUsage
        }
    }

    private nonisolated static func jsonObject(for line: String) -> [String: Any]? {
        guard !line.isEmpty else {
            return nil
        }
        let data = Data(line.utf8)
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any] else {
            return nil
        }
        return dictionary
    }

    private nonisolated static func integer(from value: Any?) -> Int? {
        switch value {
        case let number as NSNumber:
            return number.intValue
        case let string as String:
            return Int(string)
        default:
            return nil
        }
    }

    private nonisolated static func string(from value: Any?) -> String? {
        guard let string = value as? String else {
            return nil
        }
        return string.isEmpty ? nil : string
    }

    private nonisolated static func timestamp(from value: Any?) -> Date? {
        guard let string = value as? String else {
            return nil
        }

        let fractionalFormatter = ISO8601DateFormatter()
        fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractionalFormatter.date(from: string) {
            return date
        }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)
    }

    private nonisolated static func fnv1aHashHex(for data: Data) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in data {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return String(format: "%016llx", hash)
    }
}
