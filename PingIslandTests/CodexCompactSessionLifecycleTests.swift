import Foundation
import XCTest
@testable import Ping_Island

final class CodexCompactSessionLifecycleTests: XCTestCase {
    func testCompactSessionStartCreatesProcessingSessionWhenFirstObserved() async {
        let sessionId = "codex-compact-first-observation-\(UUID().uuidString)"
        let store = SessionStore.shared
        let event = makeHook(sessionId: sessionId, source: "compact")

        XCTAssertEqual(event.sessionPhase, .processing)
        XCTAssertEqual(event.determinePhase(), .processing)
        await store.process(.hookReceived(event))

        let session = await store.session(for: sessionId)
        XCTAssertEqual(session?.phase, .processing)

        await store.process(.sessionArchived(sessionId: sessionId))
    }

    func testCompactSessionStartAppliesExistingLifecyclePhaseRules() async {
        let store = SessionStore.shared
        let approval = SessionPhase.waitingForApproval(PermissionContext(
            toolUseId: "pending-tool", toolName: "Read", toolInput: nil, receivedAt: Date()
        ))
        let question = SessionIntervention(
            id: "pending-question", kind: .question, title: "Choose", message: "Which option?",
            options: [], questions: [], supportsSessionScope: false, metadata: [:]
        )
        let cases: [(initial: SessionPhase, expected: SessionPhase, intervention: SessionIntervention?)] = [
            (.processing, .processing, nil), (.compacting, .processing, nil), (.ended, .ended, nil),
            (approval, approval, nil), (.waitingForInput, .waitingForInput, question)
        ]

        for ingress in [SessionIngress.hookBridge, .remoteBridge] {
            for testCase in cases {
                let sessionId = "codex-compact-phase-\(UUID().uuidString)"
                let clientInfo = SessionClientInfo.codexApp(threadId: sessionId)

                await store.upsertCodexSession(
                    sessionId: sessionId,
                    name: "Existing task",
                    preview: "Existing lifecycle state",
                    cwd: "/tmp/\(sessionId)",
                    phase: testCase.initial,
                    intervention: testCase.intervention,
                    clientInfo: clientInfo
                )
                await store.process(.hookReceived(makeHook(
                    sessionId: sessionId,
                    source: "compact", ingress: ingress
                )))

                let session = await store.session(for: sessionId)
                XCTAssertEqual(session?.phase, testCase.expected)
                XCTAssertEqual(session?.intervention, testCase.intervention)

                await store.process(.sessionArchived(sessionId: sessionId))
            }
        }
    }

    func testCompactSessionStartResumesRemoteDiscoveryWithoutCompletingATurn() async throws {
        let sessionId = "codex-compact-discovery-\(UUID().uuidString)"
        let store = SessionStore.shared
        await store.process(.hookReceived(makeHook(
            sessionId: sessionId, event: "RemoteCodexThreadUpdated", ingress: .remoteBridge
        )))
        let discoveredSession = await store.session(for: sessionId)
        let discovered = try XCTUnwrap(discoveredSession)
        XCTAssertEqual(discovered.phase, .idle)
        XCTAssertFalse(discovered.hasRemoteCodexTurnCompletion)

        await store.process(.hookReceived(makeHook(
            sessionId: sessionId, source: "compact", ingress: .remoteBridge
        )))
        let resumed = await store.session(for: sessionId)
        XCTAssertEqual(resumed?.phase, .processing)
        XCTAssertEqual(resumed?.completionSequence, discovered.completionSequence)
        XCTAssertNil(resumed.flatMap(SessionCompletionKey.make(for:)))
        await store.process(.sessionArchived(sessionId: sessionId))
    }

    func testCompactSessionStartPreservesConcurrentUpdateWithSameActivityTimestamp() async {
        let sessionId = "codex-compact-reentrant-\(UUID().uuidString)"
        let store = SessionStore.shared

        await store.setHookEventPostPersistHandlerForTesting { persistedSessionId in
            guard persistedSessionId == sessionId,
                  let seeded = await store.session(for: sessionId) else { return }
            await store.upsertCodexSession(
                sessionId: sessionId, name: "Concurrent update", preview: nil,
                cwd: "/tmp/\(sessionId)", phase: .ended, intervention: nil,
                clientInfo: .codexApp(threadId: sessionId),
                createdAt: seeded.createdAt, activityAt: seeded.lastActivity,
                allowSyntheticActivityTimestamp: false
            )
            let concurrent = await store.session(for: sessionId)
            XCTAssertEqual(concurrent?.phase, .ended)
            XCTAssertEqual(concurrent?.lastActivity, seeded.lastActivity)
        }
        await store.process(.hookReceived(makeHook(sessionId: sessionId, source: "compact")))
        await store.setHookEventPostPersistHandlerForTesting(nil)

        let finalSession = await store.session(for: sessionId)
        XCTAssertEqual(finalSession?.phase, .ended)

        await store.process(.sessionArchived(sessionId: sessionId))
    }

    func testCompactSessionStartDoesNotRestoreSessionArchivedDuringEnrichment() async {
        let sessionId = "codex-compact-archived-\(UUID().uuidString)"
        let store = SessionStore.shared
        await store.setHookEventPostPersistHandlerForTesting { persistedSessionId in
            guard persistedSessionId == sessionId else { return }
            await store.process(.sessionArchived(sessionId: sessionId))
        }
        await store.process(.hookReceived(makeHook(sessionId: sessionId, source: "compact")))
        await store.setHookEventPostPersistHandlerForTesting(nil)
        let session = await store.session(for: sessionId)
        XCTAssertNil(session)
    }

    func testCompactSessionStartPreservesCompletionAndInterruption() async throws {
        let store = SessionStore.shared
        for ingress in [SessionIngress.hookBridge, .remoteBridge] {
            for interrupted in [false, true] {
                let sessionId = "codex-compact-finished-\(UUID().uuidString)"
                await store.upsertCodexSession(
                    sessionId: sessionId, name: "Finished task", preview: "Done",
                    cwd: "/tmp/\(sessionId)", phase: .idle, intervention: nil,
                    clientInfo: .codexApp(threadId: sessionId)
                )
                if interrupted {
                    await store.process(.interruptDetected(sessionId: sessionId))
                } else if ingress == .remoteBridge {
                    await store.process(.hookReceived(makeHook(
                        sessionId: sessionId, event: "Stop", ingress: ingress
                    )))
                }
                let beforeSession = await store.session(for: sessionId)
                let before = try XCTUnwrap(beforeSession)
                let completionKey = SessionCompletionKey.make(for: before)
                XCTAssertEqual(completionKey == nil, interrupted)

                await store.process(.hookReceived(makeHook(
                    sessionId: sessionId, source: "compact", ingress: ingress
                )))
                let afterSession = await store.session(for: sessionId)
                let after = try XCTUnwrap(afterSession)
                XCTAssertEqual(after.phase, .idle)
                XCTAssertEqual(after.isCodexTurnInterrupted, interrupted)
                XCTAssertEqual(after.hasRemoteCodexTurnCompletion, before.hasRemoteCodexTurnCompletion)
                XCTAssertEqual(after.completionSequence, before.completionSequence)
                XCTAssertEqual(SessionCompletionKey.make(for: after), completionKey)
                await store.process(.sessionArchived(sessionId: sessionId))
            }
        }
    }

    private func makeHook(
        sessionId: String,
        source: String? = nil,
        event: String = "SessionStart",
        ingress: SessionIngress = .hookBridge
    ) -> HookEvent {
        HookEvent(
            sessionId: sessionId,
            cwd: "/tmp/\(sessionId)",
            event: event,
            status: "waiting_for_input",
            provider: .codex,
            clientInfo: ingress == .remoteBridge ? .codexCLI() : .codexApp(threadId: sessionId),
            pid: nil,
            tty: nil,
            tool: nil,
            toolInput: nil,
            toolUseId: nil,
            notificationType: nil,
            message: nil,
            ingress: ingress,
            sessionStartSource: source
        )
    }
}
