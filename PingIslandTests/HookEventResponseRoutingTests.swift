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

    func testExplicitNonResponsivePermissionRequestDoesNotSurfaceApproval() {
        let intervention = SessionIntervention(
            id: "toolu_nonresponsive",
            kind: .approval,
            title: "Claude needs approval",
            message: "WebSearch",
            options: [
                SessionInterventionOption(id: "approve", title: "Allow Once", detail: nil),
                SessionInterventionOption(id: "deny", title: "Deny", detail: nil)
            ],
            questions: [],
            supportsSessionScope: true,
            metadata: ["tool_name": "WebSearch"]
        )

        let event = HookEvent(
            sessionId: "claude-session",
            cwd: "/tmp/project",
            event: "PermissionRequest",
            status: "waiting_for_approval",
            provider: .claude,
            clientInfo: SessionClientInfo(kind: .claudeCode, name: "Claude Code"),
            pid: nil,
            tty: nil,
            tool: "WebSearch",
            toolInput: ["query": AnyCodable("AI news")],
            toolUseId: "toolu_nonresponsive",
            notificationType: nil,
            message: nil,
            bridgeIntervention: intervention,
            bridgeExpectsResponse: false
        )

        XCTAssertFalse(event.expectsResponse)
        XCTAssertNil(event.intervention)
        guard case .processing = event.determinePhase() else {
            XCTFail("Expected non-responsive permission request to determine processing phase")
            return
        }
        guard case .processing = event.sessionPhase else {
            XCTFail("Expected non-responsive permission request session phase to stay processing")
            return
        }
    }
}
