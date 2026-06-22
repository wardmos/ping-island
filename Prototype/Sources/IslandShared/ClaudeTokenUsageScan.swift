import Foundation

/// One transcript's cumulative token usage, encoded as the wire format that the
/// bridge prints on stdout for `--mode scan-claude-tokens` and the macOS app
/// decodes over SSH. `capturedAtEpoch` is seconds since 1970 to avoid any
/// JSON date-strategy mismatch between encoder and decoder.
public struct ClaudeTokenUsageScanItem: Codable, Equatable, Sendable {
    public let sessionID: String
    public let capturedAtEpoch: Double?
    public let input: Int
    public let cacheWrite: Int
    public let cacheRead: Int
    public let output: Int
    public let total: Int

    public init(
        sessionID: String,
        capturedAtEpoch: Double?,
        input: Int,
        cacheWrite: Int,
        cacheRead: Int,
        output: Int,
        total: Int
    ) {
        self.sessionID = sessionID
        self.capturedAtEpoch = capturedAtEpoch
        self.input = input
        self.cacheWrite = cacheWrite
        self.cacheRead = cacheRead
        self.output = output
        self.total = total
    }
}

/// Sums per-session token usage from Claude Code transcripts on the host where
/// this runs. On a remote SSH host the bridge invokes this so the macOS app can
/// pull the numbers it cannot see locally. Parsing mirrors the app-side
/// `ClaudeTokenUsageLoader`; there is no in-process cache because each bridge
/// invocation is a fresh, short-lived process.
public enum ClaudeTokenUsageScanner {
    public static let defaultRootURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/projects", isDirectory: true)

    public static func scan(
        fromRootURL rootURL: URL = defaultRootURL,
        fileManager: FileManager = .default,
        candidateScanLimit: Int = 48,
        maxBytesPerFile: Int = 64 * 1024 * 1024
    ) -> [ClaudeTokenUsageScanItem] {
        guard fileManager.fileExists(atPath: rootURL.path),
              let enumerator = fileManager.enumerator(
                at: rootURL,
                includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey],
                options: [.skipsHiddenFiles]
              ) else {
            return []
        }

        var candidates: [(url: URL, modifiedAt: Date, size: UInt64)] = []
        for case let fileURL as URL in enumerator {
            guard fileURL.pathExtension == "jsonl",
                  let values = try? fileURL.resourceValues(
                    forKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
                  ),
                  values.isRegularFile == true else {
                continue
            }
            candidates.append((
                fileURL,
                values.contentModificationDate ?? .distantPast,
                UInt64(max(0, values.fileSize ?? 0))
            ))
        }

        candidates.sort { lhs, rhs in
            if lhs.modifiedAt == rhs.modifiedAt {
                return lhs.url.path.localizedStandardCompare(rhs.url.path) == .orderedDescending
            }
            return lhs.modifiedAt > rhs.modifiedAt
        }

        var items: [ClaudeTokenUsageScanItem] = []
        for candidate in candidates.prefix(max(1, candidateScanLimit)) {
            if let item = scanFile(
                at: candidate.url,
                modifiedAt: candidate.modifiedAt,
                fileSize: candidate.size,
                maxBytes: maxBytesPerFile
            ) {
                items.append(item)
            }
        }
        return items
    }

    private static func scanFile(
        at fileURL: URL,
        modifiedAt: Date,
        fileSize: UInt64,
        maxBytes: Int
    ) -> ClaudeTokenUsageScanItem? {
        guard fileSize > 0,
              maxBytes > 0,
              fileSize <= UInt64(maxBytes),
              let data = try? Data(contentsOf: fileURL) else {
            return nil
        }

        let contents = String(decoding: data, as: UTF8.self)
        var input = 0
        var cacheWrite = 0
        var cacheRead = 0
        var output = 0
        var latest: Date?
        var seen = Set<String>()
        var sawUsage = false

        for line in contents.split(separator: "\n", omittingEmptySubsequences: true) {
            guard line.contains("\"usage\""), line.contains("\"assistant\"") else {
                continue
            }
            guard let object = jsonObject(for: String(line)),
                  object["type"] as? String == "assistant",
                  let message = object["message"] as? [String: Any],
                  let usage = message["usage"] as? [String: Any] else {
                continue
            }
            if let id = string(object["requestId"]) ?? string(object["uuid"]) ?? string(message["id"]),
               !seen.insert(id).inserted {
                continue
            }
            input += integer(usage["input_tokens"])
            cacheWrite += integer(usage["cache_creation_input_tokens"])
            cacheRead += integer(usage["cache_read_input_tokens"])
            output += integer(usage["output_tokens"])
            sawUsage = true
            if let timestamp = timestamp(object["timestamp"]),
               latest == nil || timestamp > latest! {
                latest = timestamp
            }
        }

        guard sawUsage else {
            return nil
        }
        let total = input + cacheWrite + cacheRead + output
        guard total > 0 else {
            return nil
        }

        return ClaudeTokenUsageScanItem(
            sessionID: fileURL.deletingPathExtension().lastPathComponent,
            capturedAtEpoch: (latest ?? modifiedAt).timeIntervalSince1970,
            input: input,
            cacheWrite: cacheWrite,
            cacheRead: cacheRead,
            output: output,
            total: total
        )
    }

    private static func jsonObject(for line: String) -> [String: Any]? {
        guard !line.isEmpty,
              let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else {
            return nil
        }
        return object
    }

    private static func integer(_ value: Any?) -> Int {
        switch value {
        case let number as NSNumber:
            return max(0, number.intValue)
        case let string as String:
            return max(0, Int(string) ?? 0)
        default:
            return 0
        }
    }

    private static func string(_ value: Any?) -> String? {
        guard let string = value as? String, !string.isEmpty else {
            return nil
        }
        return string
    }

    private static func timestamp(_ value: Any?) -> Date? {
        guard let string = value as? String else {
            return nil
        }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: string) {
            return date
        }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: string)
    }
}
