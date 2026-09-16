import Foundation
import XCTest
@testable import Ping_Island

final class RemoteCodexStopCompletionTests: XCTestCase {
    func testEmptyStopAfterSnapshotDiscoveryCompletesOnceWithoutPrompt() async throws {
        let sessionId = "codex-remote-snapshot-stop-\(UUID().uuidString)"
        let store = SessionStore.shared
        var sounds = SessionSoundEdgeTracker()
        sounds.prime(with: [])

        await processSnapshot(sessionId: sessionId, store: store)
        let discoveredSession = await store.session(for: sessionId)
        let discovered = try XCTUnwrap(discoveredSession)
        XCTAssertNil(SessionCompletionKey.make(for: discovered))
        XCTAssertNotEqual(sounds.edge(for: [discovered])?.event, .taskCompleted)

        await processStop(nil, sessionId: sessionId, store: store)
        let stoppedSession = await store.session(for: sessionId)
        let stopped = try XCTUnwrap(stoppedSession)
        let key = try XCTUnwrap(SessionCompletionKey.make(for: stopped))
        XCTAssertEqual(sounds.edge(for: [stopped])?.event, .taskCompleted)
        XCTAssertTrue(SessionCompletionNotificationPolicy.shouldQueueCompletedNotification(
            for: stopped, previousPhase: discovered.phase,
            previousCompletionKey: SessionCompletionKey.make(for: discovered), isEnabled: true
        ))

        for reply in [nil, "Done.", "Done."] as [String?] {
            await processSnapshot(sessionId: sessionId, store: store)
            let snapshotSession = await store.session(for: sessionId)
            let snapshot = try XCTUnwrap(snapshotSession)
            XCTAssertEqual(SessionCompletionKey.make(for: snapshot), key)
            XCTAssertNil(sounds.edge(for: [snapshot]))

            await processStop(reply, sessionId: sessionId, store: store)
            let refreshedSession = await store.session(for: sessionId)
            let refreshed = try XCTUnwrap(refreshedSession)
            XCTAssertEqual(SessionCompletionKey.make(for: refreshed), key)
            XCTAssertNil(sounds.edge(for: [refreshed]))
            XCTAssertFalse(SessionCompletionNotificationPolicy.shouldQueueCompletedNotification(
                for: refreshed, previousPhase: snapshot.phase, previousCompletionKey: key,
                isEnabled: true
            ))
        }

        await store.process(.sessionArchived(sessionId: sessionId))
    }

    func testTranscriptEnrichmentPreservesStopAfterSnapshotDiscovery() async throws {
        let sessionId = "codex-remote-snapshot-enrichment-\(UUID().uuidString)"
        let store = SessionStore.shared
        await processSnapshot(sessionId: sessionId, store: store)
        let originalSession = await store.session(for: sessionId)
        let original = try XCTUnwrap(originalSession)

        await processStop(nil, sessionId: sessionId, store: store)
        let stopped = await store.session(for: sessionId)
        let key = try XCTUnwrap(stopped.flatMap(SessionCompletionKey.make(for:)))
        let committed = await store.commitTranscriptUpdate(original, basedOn: original)
        XCTAssertEqual(committed.flatMap(SessionCompletionKey.make(for:)), key)

        await store.process(.sessionArchived(sessionId: sessionId))
    }

    func testTranscriptEnrichmentDoesNotRestoreStopDuringNewTurn() async throws {
        let sessionId = "codex-remote-new-turn-enrichment-\(UUID().uuidString)"
        let store = SessionStore.shared
        await processStop(nil, sessionId: sessionId, store: store)
        let originalSession = await store.session(for: sessionId)
        let original = try XCTUnwrap(originalSession)

        await processPrompt(nil, sessionId: sessionId, store: store)
        let committed = await store.commitTranscriptUpdate(original, basedOn: original)
        XCTAssertEqual(committed?.phase, .processing)
        XCTAssertEqual(committed?.hasRemoteCodexTurnCompletion, false)
        XCTAssertNil(committed.flatMap(SessionCompletionKey.make(for:)))

        await store.process(.sessionArchived(sessionId: sessionId))
    }

    func testStopPromotesFinalReplyAndCompletesTurn() async {
        let sessionId = "codex-remote-stop-\(UUID().uuidString)"
        let store = SessionStore.shared

        await processPrompt("Complete the remote task.", sessionId: sessionId, store: store)
        await processStop("Remote work is complete.", sessionId: sessionId, store: store)

        let session = await store.session(for: sessionId)
        XCTAssertEqual(session?.phase, .idle)
        XCTAssertEqual(session?.lastMessageRole, "assistant")
        XCTAssertEqual(session?.lastMessage, "Remote work is complete.")
        XCTAssertEqual(assistantMessages(in: session), ["Remote work is complete."])
        XCTAssertTrue(session.map(SessionCompletionStateEvaluator.isCompletedReadySession) ?? false)

        await store.process(.sessionArchived(sessionId: sessionId))
    }

    func testRepeatedStopDoesNotDuplicateAssistantTail() async {
        let sessionId = "codex-remote-stop-repeat-\(UUID().uuidString)"
        let store = SessionStore.shared

        await processPrompt("Complete the remote task.", sessionId: sessionId, store: store)
        await processStop("Remote work is complete.", sessionId: sessionId, store: store)
        let firstSession = await store.session(for: sessionId)
        let firstKey = firstSession.flatMap(SessionCompletionKey.make(for:))
        XCTAssertNotNil(firstKey)
        await processStop("Remote work is complete.", sessionId: sessionId, store: store)
        await processStop(nil, sessionId: sessionId, store: store)

        let session = await store.session(for: sessionId)
        XCTAssertEqual(assistantMessages(in: session), ["Remote work is complete."])
        XCTAssertEqual(session?.previewText, "Remote work is complete.")
        XCTAssertEqual(session.flatMap(SessionCompletionKey.make(for:)), firstKey)

        await store.process(.sessionArchived(sessionId: sessionId))
    }

    func testLiteralStopReplyCountsAsCompletion() async {
        let sessionId = "codex-remote-stop-literal-\(UUID().uuidString)"
        let store = SessionStore.shared

        await processPrompt("Reply with one word.", sessionId: sessionId, store: store)
        await processStop("Stop", sessionId: sessionId, store: store)

        let session = await store.session(for: sessionId)
        XCTAssertEqual(session?.phase, .idle)
        XCTAssertEqual(session?.lastMessageRole, "assistant")
        XCTAssertEqual(assistantMessages(in: session), ["Stop"])
        XCTAssertTrue(session.map(SessionCompletionStateEvaluator.isCompletedReadySession) ?? false)

        await store.process(.sessionArchived(sessionId: sessionId))
    }

    func testStopWithoutFinalReplyCompletesNewTurnWithoutReusingEarlierReply() async {
        let store = SessionStore.shared
        let prompts: [(message: String?, expectedPreview: String?)] = [
            ("Complete the second task.", "Complete the second task."),
            (nil, nil), ("", nil), (" \n\t", nil)
        ]

        for (prompt, expectedPreview) in prompts {
            let sessionId = "codex-remote-stop-empty-\(UUID().uuidString)"
            await processPrompt("Complete the first task.", sessionId: sessionId, store: store)
            await processStop("Done.", sessionId: sessionId, store: store)
            let firstSession = await store.session(for: sessionId)
            let firstKey = firstSession.flatMap(SessionCompletionKey.make(for:))
            XCTAssertNotNil(firstKey)
            await processPrompt(prompt, sessionId: sessionId, store: store)
            let processing = await store.session(for: sessionId)
            XCTAssertNil(processing?.previewText)
            XCTAssertEqual(processing?.lastMessage, expectedPreview)
            await processStop(nil, sessionId: sessionId, store: store)

            let session = await store.session(for: sessionId)
            XCTAssertEqual(session?.phase, .idle)
            XCTAssertEqual(session?.lastMessageRole, "user")
            XCTAssertNil(session?.previewText)
            XCTAssertEqual(session?.lastMessage, expectedPreview)
            XCTAssertEqual(assistantMessages(in: session), ["Done."])
            XCTAssertTrue(session.map(SessionCompletionStateEvaluator.isCompletedReadySession) ?? false)
            XCTAssertNil(session.flatMap { SessionCompletionPreviewBuilder.latestAssistantText(for: $0) })
            let completionKey = session.flatMap(SessionCompletionKey.make(for:))
            XCTAssertNotNil(completionKey)
            XCTAssertNotEqual(completionKey, firstKey)

            await store.process(.sessionArchived(sessionId: sessionId))
        }
    }

    func testMissingPromptDoesNotPairEarlierQuestionWithNewReply() async {
        let store = SessionStore.shared
        for prompt in [nil, "", " \n\t"] as [String?] {
            let sessionId = "codex-remote-missing-question-\(UUID().uuidString)"
            await processPrompt("Question A", sessionId: sessionId, store: store)
            await processStop("Reply A", sessionId: sessionId, store: store)
            await processPrompt(prompt, sessionId: sessionId, store: store)
            await processStop("Reply B", sessionId: sessionId, store: store)

            let completed = await store.session(for: sessionId)
            XCTAssertNotNil(completed)
            XCTAssertNil(completed.flatMap { SessionCompletionPreviewBuilder.latestUserText(for: $0) })
            XCTAssertEqual(completed.flatMap { SessionCompletionPreviewBuilder.latestAssistantText(for: $0) }, "Reply B")
            XCTAssertEqual(completed?.conversationInfo.firstUserMessage, "Question A")
            XCTAssertEqual(assistantMessages(in: completed), ["Reply A", "Reply B"])

            await processPrompt("Question C", sessionId: sessionId, store: store)
            await processStop("Reply C", sessionId: sessionId, store: store)
            let next = await store.session(for: sessionId)
            XCTAssertEqual(next.flatMap { SessionCompletionPreviewBuilder.latestUserText(for: $0) }, "Question C")
            XCTAssertEqual(next.flatMap { SessionCompletionPreviewBuilder.latestAssistantText(for: $0) }, "Reply C")
            await store.process(.sessionArchived(sessionId: sessionId))
        }
    }

    func testSameReplyCompletesNewTurnAfterMissingPromptBody() async {
        let sessionId = "codex-remote-stop-missing-prompt-\(UUID().uuidString)"
        let store = SessionStore.shared

        await processPrompt("Complete the first task.", sessionId: sessionId, store: store)
        await processStop("Done.", sessionId: sessionId, store: store)
        let firstSession = await store.session(for: sessionId)
        let firstKey = firstSession.flatMap(SessionCompletionKey.make(for:))
        XCTAssertNotNil(firstKey)

        await processPrompt(nil, sessionId: sessionId, store: store)
        await processStop("Done.", sessionId: sessionId, store: store)

        let session = await store.session(for: sessionId)
        XCTAssertEqual(session?.phase, .idle)
        XCTAssertEqual(assistantMessages(in: session), ["Done.", "Done."])
        XCTAssertTrue(session.map(SessionCompletionStateEvaluator.isCompletedReadySession) ?? false)
        let completionKey = session.flatMap(SessionCompletionKey.make(for:))
        XCTAssertNotNil(completionKey)
        XCTAssertNotEqual(completionKey, firstKey)

        await store.process(.sessionArchived(sessionId: sessionId))
    }

    @MainActor
    func testEmptyStopAfterMissingPromptAndToolIDDoesNotReuseEarlierCompletion() async {
        let sessionId = "codex-remote-stop-missing-boundary-\(UUID().uuidString)"
        let store = SessionStore.shared

        await processPrompt("Complete the first task.", sessionId: sessionId, store: store)
        await processStop("Done.", sessionId: sessionId, store: store)
        let firstSession = await store.session(for: sessionId)
        let firstKey = firstSession.flatMap(SessionCompletionKey.make(for:))
        XCTAssertNotNil(firstKey)

        for event in ["PreToolUse", "PostToolUse"] {
            await store.process(.hookReceived(makeEvent(
                sessionId: sessionId,
                event: event,
                status: event == "PreToolUse" ? "running_tool" : "processing",
                message: nil,
                tool: "shell"
            )))
        }
        let activeSession = await store.session(for: sessionId)
        XCTAssertEqual(activeSession?.hasRemoteCodexTurnCompletion, false)
        await processStop(nil, sessionId: sessionId, store: store)

        let session = await store.session(for: sessionId)
        XCTAssertEqual(session?.phase, .idle)
        XCTAssertEqual(assistantMessages(in: session), ["Done."])
        XCTAssertTrue(session.map(SessionCompletionStateEvaluator.isCompletedReadySession) ?? false)
        XCTAssertNil(session.flatMap { SessionCompletionPreviewBuilder.latestAssistantText(for: $0) })
        let emptyStopKey = session.flatMap(SessionCompletionKey.make(for:))
        XCTAssertNotNil(emptyStopKey)
        XCTAssertNotEqual(emptyStopKey, firstKey)
        XCTAssertTrue(session.map {
            SessionCompletionNotificationPolicy.shouldQueueCompletedNotification(
                for: $0, previousPhase: .processing, isEnabled: true
            )
        } ?? false)

        // A delayed final reply enriches the completed turn without changing its identity.
        await processStop("Done.", sessionId: sessionId, store: store)
        let completedSession = await store.session(for: sessionId)
        XCTAssertEqual(assistantMessages(in: completedSession), ["Done.", "Done."])
        XCTAssertEqual(completedSession.flatMap { SessionCompletionPreviewBuilder.latestAssistantText(for: $0) }, "Done.")
        let completionKey = completedSession.flatMap(SessionCompletionKey.make(for:))
        XCTAssertNotNil(completionKey)
        XCTAssertNotEqual(completionKey, firstKey)
        XCTAssertEqual(completionKey, emptyStopKey)
        XCTAssertFalse(completedSession.map {
            SessionCompletionNotificationPolicy.shouldQueueCompletedNotification(
                for: $0,
                previousPhase: session?.phase,
                previousCompletionKey: emptyStopKey,
                isEnabled: true
            )
        } ?? true)

        await store.process(.sessionArchived(sessionId: sessionId))
    }

    @MainActor
    func testEmptyStopsNotifyOncePerTurnAndLateRepliesDoNotReplay() async throws {
        let sessionId = "codex-remote-empty-stop-notifications-\(UUID().uuidString)"
        let store = SessionStore.shared
        let registry = SessionCompletionNotificationRegistry()
        var sounds = SessionSoundEdgeTracker()
        var previousKey: SessionCompletionKey?

        for turn in 1...2 {
            await processPrompt("Complete task \(turn).", sessionId: sessionId, store: store)
            let processingSession = await store.session(for: sessionId)
            let processing = try XCTUnwrap(processingSession)
            XCTAssertFalse(processing.hasRemoteCodexTurnCompletion)
            if turn == 1 {
                sounds.prime(with: [processing])
            } else {
                _ = sounds.edge(for: [processing])
            }

            await processStop(nil, sessionId: sessionId, store: store)
            let stoppedSession = await store.session(for: sessionId)
            let stopped = try XCTUnwrap(stoppedSession)
            let key = try XCTUnwrap(SessionCompletionKey.make(for: stopped))
            XCTAssertNotEqual(key, previousKey)
            XCTAssertTrue(SessionCompletionNotificationPolicy.shouldQueueCompletedNotification(
                for: stopped, previousPhase: processing.phase, isEnabled: true
            ))
            XCTAssertEqual(sounds.edge(for: [stopped])?.event, .taskCompleted)
            registry.enqueue(SessionCompletionNotification(session: stopped, kind: .completed))
            let notification = try XCTUnwrap(registry.dequeueNext())
            XCTAssertEqual(notification.identity, .completed(key))

            for reply in [nil, "Done.", "Done."] as [String?] {
                await processStop(reply, sessionId: sessionId, store: store)
                let refreshedSession = await store.session(for: sessionId)
                let refreshed = try XCTUnwrap(refreshedSession)
                XCTAssertEqual(SessionCompletionKey.make(for: refreshed), key)
                XCTAssertFalse(SessionCompletionNotificationPolicy.shouldQueueCompletedNotification(
                    for: refreshed, previousPhase: .idle, previousCompletionKey: key, isEnabled: true
                ))
                XCTAssertNil(sounds.edge(for: [refreshed]))
                registry.enqueue(SessionCompletionNotification(session: refreshed, kind: .completed))
                XCTAssertNil(registry.dequeueNext())
            }
            previousKey = key
        }

        let session = await store.session(for: sessionId)
        XCTAssertEqual(assistantMessages(in: session), ["Done.", "Done."])
        await store.process(.sessionArchived(sessionId: sessionId))
    }

    func testSameReplyCompletesNewTurnAfterMissingPromptEvent() async {
        let sessionId = "codex-remote-stop-missing-event-\(UUID().uuidString)"
        let store = SessionStore.shared

        await processPrompt("Complete the first task.", sessionId: sessionId, store: store)
        await processStop("Done.", sessionId: sessionId, store: store)
        let firstSession = await store.session(for: sessionId)
        let firstKey = firstSession.flatMap(SessionCompletionKey.make(for:))
        XCTAssertNotNil(firstKey)

        for event in ["PreToolUse", "PostToolUse"] {
            await store.process(.hookReceived(makeEvent(
                sessionId: sessionId,
                event: event,
                status: event == "PreToolUse" ? "running_tool" : "processing",
                message: nil,
                tool: "shell",
                toolUseId: "remote-tool-\(sessionId)"
            )))
        }
        await processStop("Done.", sessionId: sessionId, store: store)

        let session = await store.session(for: sessionId)
        XCTAssertEqual(session?.phase, .idle)
        XCTAssertEqual(assistantMessages(in: session), ["Done.", "Done."])
        let completionKey = session.flatMap(SessionCompletionKey.make(for:))
        XCTAssertNotNil(completionKey)
        XCTAssertNotEqual(completionKey, firstKey)

        await processStop("Done.", sessionId: sessionId, store: store)
        let replayedSession = await store.session(for: sessionId)
        XCTAssertEqual(assistantMessages(in: replayedSession), ["Done.", "Done."])
        XCTAssertEqual(replayedSession.flatMap(SessionCompletionKey.make(for:)), completionKey)

        await store.process(.sessionArchived(sessionId: sessionId))
    }

    func testConversationPreservesFormattingWithoutInjectedReminders() async {
        let sessionId = "codex-remote-stop-formatting-\(UUID().uuidString)"
        let store = SessionStore.shared
        let prompt = "Review this code:\n\n```python\nif ready:\n    run()\n```"
        let reply = "## Result\n\n```python\nif ready:\n    run_safely()\n```\n\n- Updated the call."

        await processPrompt("<system-reminder>Client context</system-reminder>\n\(prompt)", sessionId: sessionId, store: store)
        await processStop("\(reply)\n<system-reminder>Client context</system-reminder>", sessionId: sessionId, store: store)
        await processStop(reply, sessionId: sessionId, store: store)

        let session = await store.session(for: sessionId)
        let userMessages = session?.chatItems.compactMap { item -> String? in
            guard case .user(let message) = item.type else { return nil }
            return message
        }
        XCTAssertEqual(userMessages, [prompt])
        XCTAssertEqual(assistantMessages(in: session), [reply])
        XCTAssertEqual(session?.conversationInfo.firstUserMessage, prompt)
        XCTAssertEqual(session?.conversationInfo.lastMessage, reply)
        XCTAssertEqual(session?.previewText, reply)
        XCTAssertTrue(session.map(SessionCompletionStateEvaluator.isCompletedReadySession) ?? false)

        await store.process(.sessionArchived(sessionId: sessionId))
    }

    private func processPrompt(_ message: String?, sessionId: String, store: SessionStore) async {
        await store.process(.hookReceived(makeEvent(
            sessionId: sessionId,
            event: "UserPromptSubmit",
            status: "processing",
            message: message
        )))
    }

    private func processSnapshot(sessionId: String, store: SessionStore) async {
        await store.process(.hookReceived(makeEvent(
            sessionId: sessionId,
            event: "RemoteCodexThreadUpdated",
            status: "idle",
            message: "Remote task snapshot"
        )))
    }

    private func processStop(_ message: String?, sessionId: String, store: SessionStore) async {
        await store.process(.hookReceived(makeEvent(
            sessionId: sessionId,
            event: "Stop",
            status: "waiting_for_input",
            message: message
        )))
    }

    private func makeEvent(
        sessionId: String,
        event: String,
        status: String,
        message: String?,
        tool: String? = nil,
        toolUseId: String? = nil
    ) -> HookEvent {
        HookEvent(
            sessionId: sessionId,
            cwd: "/tmp/remote-project-\(sessionId)",
            event: event,
            status: status,
            provider: .codex,
            clientInfo: .codexCLI(),
            pid: nil,
            tty: nil,
            tool: tool,
            toolInput: nil,
            toolUseId: toolUseId,
            notificationType: nil,
            message: message,
            ingress: .remoteBridge
        )
    }

    private func assistantMessages(in session: SessionState?) -> [String] {
        session?.chatItems.compactMap { item in
            guard case .assistant(let message) = item.type else { return nil }
            return message
        } ?? []
    }
}
