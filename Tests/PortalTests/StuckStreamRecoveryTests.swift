import Foundation
import Testing
@testable import Portal

/// A long session would stick on "Thinking…" with the thought graph frozen on
/// whatever operation it had last applied. The session kept running on the
/// gateway; nothing in the UI could clear it. Only Stop (which calls
/// `finishStreaming` directly) or an app relaunch recovered it.
///
/// Every path here is a *latch*: local `isStreaming` gets stuck true — or gets
/// stuck disagreeing with the gateway — and no later event can unstick it. Three
/// independent ones existed, which is why the bug was intermittent: it needed
/// whichever one the session happened to hit.
///
///  1. **The one-way drop guard.** `applySessionEvent` drops live-turn events
///     when `!state.isStreaming`, to discard frames the gateway drains after a
///     Stop. But `messageComplete` is itself a live-turn event, so once local
///     state desynced to `false` mid-turn (a reconnect, an `error` frame for a
///     turn the agent kept running, a resume whose persisted history lagged the
///     live turn) the terminal event was dropped along with the deltas and the
///     turn could never finish locally. `resumesLiveTurn` makes the turn-ENDING
///     events re-entry points: honouring one can only settle state.
///  2. **The unstampable completion.** Both `messageComplete` handlers bail when
///     they can't find the streaming message to write into — and used to bail
///     without clearing `isStreaming`. A latched flag holds the avatar on
///     "Thinking…" *and* trips `submitPrompt`'s `guard !isStreaming`, so the
///     session could neither finish nor accept a new prompt.
///  3. **Eviction of a live transcript.** `evictColdSessionMessages` drops
///     message arrays past 6 warm sessions, which is safe only because
///     transcripts reload from disk. A streaming session's is the exception: it
///     holds the in-flight assistant shell, which exists nowhere else until
///     `message.complete` persists it, and `restoreSessionState` deliberately
///     skips the disk reload while streaming. Evicting it destroyed the shell
///     that (2) then couldn't find — reproducing the user's exact recipe: a long
///     session (7+ warm states before eviction triggers at all) plus a click
///     away and back (the snapshot that runs it).
///
/// The drop guard's original purpose is still pinned below: a post-Stop
/// `messageDelta` must still be discarded, or an interrupted turn resurrects.
@Suite("Stuck stream recovery")
@MainActor
internal struct StuckStreamRecoveryTests {

    private func complete(_ text: String = "done", status: String = "complete") -> GatewayEvent {
        .messageComplete(payload: MessageCompletePayload(
            text: text,
            status: status,
            usage: nil,
            reasoning: nil,
            rendered: nil,
            warning: nil
        ))
    }

    // MARK: - 1. The one-way drop guard

    /// The core desync heal. `messageComplete` arriving for a session whose
    /// local `isStreaming` has fallen to false must settle the turn — before the
    /// fix it was dropped as a "late live-turn event" and the session was wedged
    /// until relaunch.
    @Test("a completion for a desynced session settles the turn")
    internal func completionHealsDesyncedSession() {
        let vm = ChatViewModel()
        let sid = "desync-\(UUID().uuidString)"
        _ = vm.beginSwitchToSession(key: sid)

        vm.receiveGatewayEventForTesting(.messageStart, sessionID: sid)
        #expect(vm.isStreaming)

        // Desync exactly as a mid-turn reconnect + resume does: the gateway turn
        // is still running, but local state now says it isn't.
        vm.forceStreamingStateForTesting(false, sessionID: sid)
        #expect(!vm.isStreaming)

        vm.receiveGatewayEventForTesting(complete("the answer"), sessionID: sid)

        #expect(!vm.isStreaming)
        #expect(vm.avatarState == .idle)
        let assistant = vm.messages.last { $0.role == .assistant }
        #expect(assistant?.content == "the answer")
        #expect(assistant?.isStreaming == false)
    }

    /// The avatar is what the user actually reported ("it'll just say
    /// thinking"), so pin it directly rather than only pinning `isStreaming`.
    @Test("a desynced session does not hold the avatar on thinking")
    internal func desyncedSessionClearsThinkingAvatar() {
        let vm = ChatViewModel()
        let sid = "desync-avatar-\(UUID().uuidString)"
        _ = vm.beginSwitchToSession(key: sid)

        vm.receiveGatewayEventForTesting(.messageStart, sessionID: sid)
        vm.receiveGatewayEventForTesting(.thinkingDelta(text: "considering"), sessionID: sid)
        vm.forceStreamingStateForTesting(false, sessionID: sid)

        vm.receiveGatewayEventForTesting(complete(), sessionID: sid)
        #expect(vm.avatarState == .idle)
    }

    /// The guard still has to do its original job. A `messageDelta` after the
    /// turn ended locally is a post-Stop drain and must NOT be appended, or an
    /// interrupted turn keeps growing text in the UI.
    @Test("a late delta after the stream ended is still dropped")
    internal func lateDeltaIsStillDropped() {
        let vm = ChatViewModel()
        let sid = "late-delta-\(UUID().uuidString)"
        _ = vm.beginSwitchToSession(key: sid)

        vm.receiveGatewayEventForTesting(.messageStart, sessionID: sid)
        vm.forceStreamingStateForTesting(false, sessionID: sid)

        vm.receiveGatewayEventForTesting(
            .messageDelta(text: "should not appear", rendered: nil),
            sessionID: sid
        )
        let assistant = vm.messages.last { $0.role == .assistant }
        #expect(assistant?.content.contains("should not appear") == false)
        #expect(!vm.isStreaming)
    }

    /// `error` is a turn ending too, so it must reach the handler that clears
    /// the flags and surfaces the message — dropping it left the same wedge with
    /// the failure invisible.
    @Test("an error for a desynced session still surfaces and settles")
    internal func errorHealsDesyncedSession() {
        let vm = ChatViewModel()
        let sid = "desync-error-\(UUID().uuidString)"
        _ = vm.beginSwitchToSession(key: sid)

        vm.receiveGatewayEventForTesting(.messageStart, sessionID: sid)
        vm.forceStreamingStateForTesting(false, sessionID: sid)

        vm.receiveGatewayEventForTesting(.error(message: "upstream died"), sessionID: sid)
        #expect(vm.error == "upstream died")
        #expect(!vm.isStreaming)
    }

    /// A session this client has no cached state for is not evidence that its
    /// turn ended — `SessionRuntimeState()`'s `isStreaming == false` is a
    /// default, not an observation. Dropping on it discarded every frame of a
    /// turn another client started on a shared session.
    @Test("frames for an uncached session are applied, not dropped")
    internal func unknownSessionIsNotTreatedAsEnded() {
        let vm = ChatViewModel()
        let visible = "visible-\(UUID().uuidString)"
        let stranger = "uncached-\(UUID().uuidString)"
        _ = vm.beginSwitchToSession(key: visible)

        // No beginSwitchToSession for `stranger` — nothing cached at all. A
        // toolStart is a live-turn event, so the guard saw it first.
        vm.receiveGatewayEventForTesting(
            .toolStart(payload: ToolStartPayload(toolID: "t1", name: "bash", context: "ls")),
            sessionID: stranger
        )
        #expect(vm.streamingSessionIDsForTesting.contains(stranger) == false)
        // The point is that state was CREATED for it rather than the frame
        // vanishing: the tool call is now recorded against that session.
        #expect(vm.activeToolCallsForTesting(sessionID: stranger)?.isEmpty == false)
    }

    // MARK: - 2. The unstampable completion

    /// Latch (2) in isolation: a completion that cannot find its message must
    /// still clear the flag. Otherwise the stuck flag also blocks the next
    /// prompt, matching "stop the session to figure out how to resume".
    @Test("a completion with no message to stamp still clears isStreaming")
    internal func unstampableCompletionClearsFlag() {
        let vm = ChatViewModel()
        let sid = "unstampable-\(UUID().uuidString)"
        _ = vm.beginSwitchToSession(key: sid)

        vm.receiveGatewayEventForTesting(.messageStart, sessionID: sid)
        #expect(vm.isStreaming)
        // Destroy the shell the completion would stamp, leaving isStreaming set
        // — exactly the state eviction used to produce.
        vm.dropCachedMessagesForTesting(sessionID: sid)

        vm.receiveGatewayEventForTesting(complete(), sessionID: sid)
        #expect(!vm.isStreaming)
        #expect(vm.avatarState == .idle)
    }

    /// The same latch on the BACKGROUND path, which is where it actually bit: a
    /// visible session gets settled by `finishStreaming` regardless, but a
    /// background one is only ever settled inside the handler that just bailed.
    /// A session left latched here stays stuck after the user clicks back to it.
    @Test("an unstampable completion clears a background session's flag")
    internal func unstampableBackgroundCompletionClearsFlag() {
        let vm = ChatViewModel()
        let background = "unstampable-bg-\(UUID().uuidString)"
        let visible = "visible-bg-\(UUID().uuidString)"

        _ = vm.beginSwitchToSession(key: background)
        vm.receiveGatewayEventForTesting(.messageStart, sessionID: background)
        _ = vm.beginSwitchToSession(key: visible)

        vm.dropCachedMessagesForTesting(sessionID: background)
        vm.receiveGatewayEventForTesting(complete(), sessionID: background)

        #expect(vm.streamingSessionIDsForTesting.contains(background) == false)
        // And clicking back doesn't restore the wedge.
        _ = vm.beginSwitchToSession(key: background)
        #expect(!vm.isStreaming)
        #expect(vm.avatarState == .idle)
    }

    // MARK: - 3. Eviction of a live transcript

    /// Latch (3). Warm more sessions than the cap while one streams, then run the
    /// snapshot that triggers eviction, and the streaming session must keep its
    /// transcript — it is the one transcript that cannot be reloaded from disk.
    ///
    /// The other sessions must be left STREAMING to get there: switching away
    /// from an idle session already clears its messages (`beginSwitchToSession`),
    /// so idle sessions never accumulate enough warm states to trip the cap at
    /// all. Concurrent live turns are how a real long session reaches it — and
    /// they're the case where losing a shell actually costs something.
    @Test("eviction spares a session with a turn in flight")
    internal func evictionSparesStreamingSession() {
        let vm = ChatViewModel()
        let streaming = "streaming-\(UUID().uuidString)"

        _ = vm.beginSwitchToSession(key: streaming)
        vm.receiveGatewayEventForTesting(.messageStart, sessionID: streaming)
        vm.receiveGatewayEventForTesting(
            .messageDelta(text: "partial answer", rendered: nil),
            sessionID: streaming
        )

        // Warm well past maxWarmSessionStates (6) so eviction has to pick
        // victims, and end on a different visible session so the streaming one
        // isn't the active ID eviction protects unconditionally.
        for index in 0..<9 {
            let other = "other-\(index)-\(UUID().uuidString)"
            _ = vm.beginSwitchToSession(key: other)
            vm.receiveGatewayEventForTesting(.messageStart, sessionID: other)
            vm.receiveGatewayEventForTesting(
                .messageDelta(text: "other partial \(index)", rendered: nil),
                sessionID: other
            )
        }

        // Assert the invariant over EVERY live session, not just `streaming`.
        // Eviction picks victims in dictionary order, so which sessions it would
        // have hit isn't deterministic — but with 10 live turns against a cap of
        // 6 it must hit *some* of them, so the universal claim fails reliably
        // while a claim about one chosen session would be a coin flip.
        for id in vm.streamingSessionIDsForTesting {
            #expect(
                vm.cachedMessageCountForTesting(sessionID: id) ?? 0 > 0,
                """
                Session \(id) has a turn in flight but its transcript was evicted. \
                A streaming session's transcript holds the in-flight assistant \
                shell, which exists nowhere else until message.complete persists \
                it — and restoreSessionState skips the disk reload while \
                streaming. Losing it wedges the session on "Thinking…" because \
                the completion can no longer find the message to stamp.
                """
            )
        }
        #expect(vm.cachedMessageCountForTesting(sessionID: streaming) ?? 0 > 0)

        // And the turn still completes — the whole point of keeping the shell.
        // Click back first, as the user does: a completion that lands while the
        // session is in the BACKGROUND deliberately releases the transcript to
        // disk and reloads it asynchronously, which isn't what's under test.
        _ = vm.beginSwitchToSession(key: streaming)
        #expect(vm.isStreaming)
        vm.receiveGatewayEventForTesting(complete("final answer"), sessionID: streaming)
        #expect(vm.messages.last { $0.role == .assistant }?.content == "final answer")
        #expect(!vm.isStreaming)
        #expect(vm.avatarState == .idle)
    }

    // MARK: - Classifier

    /// `resumesLiveTurn` must stay a subset of turn-ENDING events plus
    /// `messageStart`. Adding a mid-turn event (a delta, a tool frame) would
    /// re-break the post-Stop drain the guard exists for.
    @Test("only turn-boundary events may re-open a stream")
    internal func resumesLiveTurnIsBoundaryOnly() {
        #expect(GatewayEvent.messageStart.resumesLiveTurn)
        #expect(complete().resumesLiveTurn)
        #expect(GatewayEvent.error(message: "x").resumesLiveTurn)

        #expect(!GatewayEvent.messageDelta(text: "x", rendered: nil).resumesLiveTurn)
        #expect(!GatewayEvent.reasoningDelta(text: "x").resumesLiveTurn)
        #expect(!GatewayEvent.thinkingDelta(text: "x").resumesLiveTurn)
        #expect(!GatewayEvent.toolProgress(name: "bash", preview: "x").resumesLiveTurn)
        #expect(!GatewayEvent.toolGenerating(name: "bash").resumesLiveTurn)
    }
}
