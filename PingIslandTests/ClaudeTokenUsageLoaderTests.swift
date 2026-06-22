import XCTest
@testable import Ping_Island

final class ClaudeTokenUsageLoaderTests: XCTestCase {
    func testLoadSumsAssistantUsagePerSession() throws {
        let rootURL = temporaryRootURL(named: "claude-token")
        let sessionID = "ba553837-491d-45fc-b868-3b23b13e3cef"
        let transcriptURL = rootURL
            .appendingPathComponent("-home-me-project", isDirectory: true)
            .appendingPathComponent("\(sessionID).jsonl")

        defer {
            try? FileManager.default.removeItem(at: rootURL)
        }

        try writeTranscript(
            [
                assistantLine(
                    timestamp: "2026-06-21T16:09:48.978Z",
                    requestID: "req-1",
                    usage: [
                        "input_tokens": 100,
                        "cache_creation_input_tokens": 10,
                        "cache_read_input_tokens": 1_000,
                        "output_tokens": 50,
                    ]
                ),
                userLine(timestamp: "2026-06-21T16:10:00.000Z", text: "next request"),
                assistantLine(
                    timestamp: "2026-06-21T16:11:30.500Z",
                    requestID: "req-2",
                    usage: [
                        "input_tokens": 200,
                        "cache_creation_input_tokens": 0,
                        "cache_read_input_tokens": 2_000,
                        "output_tokens": 80,
                    ]
                ),
            ],
            to: transcriptURL
        )

        let sessions = try ClaudeTokenUsageLoader.load(fromRootURL: rootURL)

        XCTAssertEqual(sessions.count, 1)
        let session = try XCTUnwrap(sessions.first)
        XCTAssertEqual(session.sessionID, sessionID)
        XCTAssertEqual(session.totals, AgentUsageTokenTotals(input: 3_310, output: 130, total: 3_440))
        XCTAssertEqual(session.capturedAt, isoDate("2026-06-21T16:11:30.500Z"))
    }

    func testLoadDeduplicatesRepeatedRequestIDsWithinFile() throws {
        let rootURL = temporaryRootURL(named: "claude-token-dedup")
        let transcriptURL = rootURL
            .appendingPathComponent("-home-me-project", isDirectory: true)
            .appendingPathComponent("11111111-2222-3333-4444-555555555555.jsonl")

        defer {
            try? FileManager.default.removeItem(at: rootURL)
        }

        let duplicated = assistantLine(
            timestamp: "2026-06-21T16:09:48.978Z",
            requestID: "req-dup",
            usage: [
                "input_tokens": 100,
                "cache_read_input_tokens": 0,
                "output_tokens": 25,
            ]
        )

        try writeTranscript([duplicated, duplicated], to: transcriptURL)

        let sessions = try ClaudeTokenUsageLoader.load(fromRootURL: rootURL)

        XCTAssertEqual(sessions.first?.totals, AgentUsageTokenTotals(input: 100, output: 25, total: 125))
    }

    func testLoadSkipsTranscriptsLargerThanMaxBytes() throws {
        let rootURL = temporaryRootURL(named: "claude-token-large")
        let transcriptURL = rootURL
            .appendingPathComponent("-home-me-project", isDirectory: true)
            .appendingPathComponent("99999999-2222-3333-4444-555555555555.jsonl")

        defer {
            try? FileManager.default.removeItem(at: rootURL)
        }

        try writeTranscript(
            [
                assistantLine(
                    timestamp: "2026-06-21T16:09:48.978Z",
                    requestID: "req-1",
                    usage: ["input_tokens": 100, "output_tokens": 50]
                ),
            ],
            to: transcriptURL
        )

        let sessions = try ClaudeTokenUsageLoader.load(fromRootURL: rootURL, maxBytesPerFile: 8)

        XCTAssertTrue(sessions.isEmpty)
    }

    func testLoadReturnsEmptyWhenNoTranscriptsExist() throws {
        let rootURL = temporaryRootURL(named: "claude-token-empty")
        defer {
            try? FileManager.default.removeItem(at: rootURL)
        }
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)

        let sessions = try ClaudeTokenUsageLoader.load(fromRootURL: rootURL)

        XCTAssertTrue(sessions.isEmpty)
    }
}

private func temporaryRootURL(named name: String) -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("ping-island-\(name)-\(UUID().uuidString)", isDirectory: true)
}

private func writeTranscript(_ lines: [String], to url: URL) throws {
    let directoryURL = url.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    try lines.joined(separator: "\n").appending("\n").write(to: url, atomically: true, encoding: .utf8)
}

private func assistantLine(
    timestamp: String,
    requestID: String,
    usage: [String: Any]
) -> String {
    let object: [String: Any] = [
        "type": "assistant",
        "timestamp": timestamp,
        "requestId": requestID,
        "uuid": UUID().uuidString,
        "message": [
            "id": "msg-\(requestID)",
            "model": "claude-opus-4-8",
            "usage": usage,
        ],
    ]
    let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    return String(decoding: data, as: UTF8.self)
}

private func userLine(timestamp: String, text: String) -> String {
    let object: [String: Any] = [
        "type": "user",
        "timestamp": timestamp,
        "uuid": UUID().uuidString,
        "message": ["content": text],
    ]
    let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    return String(decoding: data, as: UTF8.self)
}

private func isoDate(_ value: String) -> Date? {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.date(from: value)
}
