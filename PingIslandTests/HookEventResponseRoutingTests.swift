import XCTest
@testable import Ping_Island

final class HookEventResponseRoutingTests: XCTestCase {
    func testTerminalRoutedPermissionRequestStillExpectsResponse() {
        let event = HookEvent(
            sessionId: "claude-session",
            cwd: "/tmp/project",
            event: "PermissionRequest",
            status: "waiting_for_approval",
            provider: .claude,
            clientInfo: SessionClientInfo(kind: .claudeCode, name: "Claude Code"),
            pid: nil,
            tty: nil,
            tool: "Edit",
            toolInput: nil,
            toolUseId: nil,
            notificationType: nil,
            message: nil,
            suppressInAppPrompt: true
        )

        XCTAssertTrue(event.expectsResponse)
    }

    func testTerminalRoutedAskUserQuestionDoesNotExpectResponse() {
        let event = HookEvent(
            sessionId: "claude-session",
            cwd: "/tmp/project",
            event: "PreToolUse",
            status: "waiting_for_input",
            provider: .claude,
            clientInfo: SessionClientInfo(kind: .claudeCode, name: "Claude Code"),
            pid: nil,
            tty: nil,
            tool: "AskUserQuestion",
            toolInput: ["questions": AnyCodable([["question": "Pick one"]])],
            toolUseId: "question-tool",
            notificationType: nil,
            message: nil,
            suppressInAppPrompt: true
        )

        XCTAssertFalse(event.expectsResponse)
    }

    func testTerminalRoutedPermissionRequestAskUserQuestionDoesNotExpectResponse() {
        let event = HookEvent(
            sessionId: "claude-session",
            cwd: "/tmp/project",
            event: "PermissionRequest",
            status: "waiting_for_approval",
            provider: .claude,
            clientInfo: SessionClientInfo(kind: .claudeCode, profileID: "claude_code", name: "Claude Code"),
            pid: nil,
            tty: nil,
            tool: "AskUserQuestion",
            toolInput: ["questions": AnyCodable([["question": "Pick one"]])],
            toolUseId: "question-tool",
            notificationType: nil,
            message: nil,
            suppressInAppPrompt: true
        )

        XCTAssertFalse(event.expectsResponse)
    }

    func testTerminalRoutedPermissionRequestAskFollowupQuestionDoesNotExpectResponse() {
        let event = HookEvent(
            sessionId: "claude-session",
            cwd: "/tmp/project",
            event: "PermissionRequest",
            status: "waiting_for_approval",
            provider: .claude,
            clientInfo: SessionClientInfo(kind: .claudeCode, profileID: "claude_code", name: "Claude Code"),
            pid: nil,
            tty: nil,
            tool: "AskFollowupQuestion",
            toolInput: ["questions": AnyCodable([["question": "Pick one"]])],
            toolUseId: "question-tool",
            notificationType: nil,
            message: nil,
            suppressInAppPrompt: true
        )

        XCTAssertFalse(event.expectsResponse)
    }
}
