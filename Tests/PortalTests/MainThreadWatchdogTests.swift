import Foundation
import Testing
@testable import Portal

// The storm detector's core is a busy-fraction sum over a rolling window: the
// signature no single-turn hang threshold can see (#254's SessionList relayout
// loop was thousands of sub-250ms turns). These exercise that math directly —
// the run-loop plumbing that feeds it is covered by the macOS hang gate.
//
// The watchdog is `#if DEBUG`; the test target builds DEBUG, so it's visible.
#if DEBUG
@Suite("Main-thread storm detection")
internal struct MainThreadWatchdogTests {

    // A 1s window at t ∈ [10, 11], matching the detector's stormWindowSeconds.
    private let windowStart: CFAbsoluteTime = 10
    private let windowEnd: CFAbsoluteTime = 11

    private func busy(
        _ intervals: [(start: CFAbsoluteTime, end: CFAbsoluteTime)]
    ) -> TimeInterval {
        MainThreadWatchdog.busySeconds(in: intervals, from: windowStart, to: windowEnd)
    }

    @Test("Many short turns sum toward the busy fraction")
    internal func shortTurnsSum() {
        // 45 turns of 20ms each = 900ms busy in a 1s window → 0.9 fraction.
        // Each turn is far under any 250ms hang threshold, yet together they
        // saturate the run loop — exactly the storm the hang detector misses.
        var intervals: [(start: CFAbsoluteTime, end: CFAbsoluteTime)] = []
        var t = windowStart
        for _ in 0..<45 {
            intervals.append((start: t, end: t + 0.020))
            t += 0.022 // 20ms busy + 2ms idle per turn
        }
        let fraction = busy(intervals) / 1.0
        #expect(abs(fraction - 0.9) < 1e-6)
        #expect(fraction >= 0.8) // trips the default 0.8 threshold
    }

    @Test("A mostly-idle window stays below threshold")
    internal func idleWindowBelowThreshold() {
        // 40 turns of 5ms each = 200ms busy → 0.2 fraction. Normal streaming /
        // animation load idles between frames; it must NOT read as a storm.
        var intervals: [(start: CFAbsoluteTime, end: CFAbsoluteTime)] = []
        var t = windowStart
        for _ in 0..<40 {
            intervals.append((start: t, end: t + 0.005))
            t += 0.025
        }
        #expect(busy(intervals) / 1.0 < 0.8)
    }

    @Test("Intervals straddling the window edge count only their in-window part")
    internal func clipsToWindow() {
        // A turn that started before the window opened (busy 9.5→10.5) only
        // contributes its in-window half; likewise one running past the end.
        let intervals: [(start: CFAbsoluteTime, end: CFAbsoluteTime)] = [
            (start: 9.5, end: 10.5),   // clipped to [10, 10.5] = 0.5
            (start: 10.9, end: 11.4),  // clipped to [10.9, 11] = 0.1
        ]
        #expect(abs(busy(intervals) - 0.6) < 1e-9)
    }

    @Test("A fully-out-of-window interval contributes nothing")
    internal func excludesStaleIntervals() {
        let intervals: [(start: CFAbsoluteTime, end: CFAbsoluteTime)] = [
            (start: 8.0, end: 9.0), // entirely before the window
        ]
        #expect(busy(intervals) == 0)
    }

    @Test("One long turn fills the window (the hang detector's territory too)")
    internal func singleLongTurn() {
        // A single turn busy the whole window reads as 100% — but this is the
        // hang detector's job (it fires at 250ms); the storm path yields to a
        // hang in progress. The math still reports it faithfully.
        let intervals: [(start: CFAbsoluteTime, end: CFAbsoluteTime)] = [
            (start: 10.0, end: 11.0),
        ]
        #expect(abs(busy(intervals) - 1.0) < 1e-9)
    }

    @Test("An empty window is zero busy, not a divide-by-nonsense")
    internal func emptyWindow() {
        #expect(busy([]) == 0)
    }

    @Test("A few heavy sub-threshold turns read as a storm")
    internal func fewHeavyTurnsAreAStorm() {
        // The gap the old stormMinTurns = 20 left open: 8 turns of 120ms = 960ms
        // busy in a 1s window. The CPU is pegged, but the hang detector sees no
        // turn past 250ms and a 20-turn floor would have rejected it as a flurry.
        // Both tripwires silent, beachball on screen.
        var intervals: [(start: CFAbsoluteTime, end: CFAbsoluteTime)] = []
        var t = windowStart
        for _ in 0..<8 {
            intervals.append((start: t, end: t + 0.120))
            t += 0.125
        }
        let fraction = busy(intervals) / 1.0
        #expect(fraction >= 0.8)
        #expect(intervals.count >= 2)   // clears the floor that now applies
        #expect(intervals.allSatisfy { $0.end - $0.start < 0.250 })  // no hang fires
    }

    @Test("Busy marked before the frameworks run, idle after them")
    internal func observerOrderBracketsFrameworkWork() {
        // The bug that made this whole detector silent during a live beachball:
        // SwiftUI runs the view-graph update inside a `beforeWaiting` observer,
        // so marking idle at the same order (0) as SwiftUI's observer put the
        // expensive work outside the busy span. Busy must be marked first among
        // afterWaiting observers and idle LAST among beforeWaiting ones.
        #expect(MainThreadWatchdog.busyObserverOrder < MainThreadWatchdog.idleObserverOrder)
        // CoreAnimation's commit observer sits at 2_000_000 and SwiftUI's at 0 —
        // the idle mark has to come after any of them to contain their work.
        #expect(MainThreadWatchdog.idleObserverOrder > 2_000_000)
        #expect(MainThreadWatchdog.busyObserverOrder < 0)
    }

    // MARK: - Report decision + latch
    //
    // The live storm path only fires from a genuinely saturated run loop, and it
    // can't be driven end-to-end: main-queue blocks don't execute during a launch
    // with no window, so a synthetic-spin probe never runs. That's exactly the
    // conditions under which the original observer-ordering bug went unnoticed for
    // this detector's whole life, so the decision is pinned here instead.

    private func decide(
        fraction: Double, turns: Int, reported: Bool, saturatedFor: TimeInterval = 5
    ) -> (report: Bool, clearLatch: Bool) {
        MainThreadWatchdog.stormDecision(
            busyFraction: fraction, turns: turns, threshold: 0.8, minTurns: 2,
            saturatedFor: saturatedFor, sustainSeconds: 3,
            alreadyReported: reported
        )
    }

    @Test("A high-refresh animation is not a storm")
    internal func animationIsNotAStorm() {
        // Measured on a real launch once framework work landed inside the busy
        // span: "81% busy across 151 short turns", stack deep in
        // CA::Context::commit_transaction — a healthy app animating at display
        // refresh rate. Duration is what separates it from a stuck loop, and the
        // CI gate runs --hang-fatal, so reporting this would crash the build.
        #expect(!decide(fraction: 0.81, turns: 151, reported: false, saturatedFor: 0.2).report)
        #expect(!decide(fraction: 0.95, turns: 120, reported: false, saturatedFor: 2.9).report)
        // Past the sustain window it is no longer explicable as an animation.
        #expect(decide(fraction: 0.81, turns: 151, reported: false, saturatedFor: 3.0).report)
    }

    @Test("A saturated window reports once, not on every poll")
    internal func stormReportsOnce() {
        #expect(decide(fraction: 0.95, turns: 12, reported: false).report)
        // Same storm, next poll 50ms later — must stay quiet or the log floods.
        #expect(!decide(fraction: 0.95, turns: 12, reported: true).report)
    }

    @Test("The latch rearms only after the storm actually subsides")
    internal func stormLatchIsEdgeTriggered() {
        #expect(decide(fraction: 0.2, turns: 5, reported: true).clearLatch)
        // Still saturated → do NOT rearm, or the same ongoing storm re-reports.
        #expect(!decide(fraction: 0.9, turns: 12, reported: true).clearLatch)
        // A settled window with the latch already clear has nothing to clear.
        #expect(!decide(fraction: 0.1, turns: 3, reported: false).clearLatch)
        // Rearmed: a storm that recurs after settling reports again.
        #expect(decide(fraction: 0.95, turns: 12, reported: false).report)
    }

    @Test("A single-turn window is left to the hang detector")
    internal func singleTurnNotAStorm() {
        // One turn saturating the window is a hang, not a churn loop — and
        // checkForStorm only runs when no hang is in progress, so reporting it
        // here would double-report the same stall under the wrong framing.
        #expect(!decide(fraction: 1.0, turns: 1, reported: false).report)
        #expect(decide(fraction: 1.0, turns: 2, reported: false).report)
    }

    @Test("A spin that never sleeps still accumulates busy time")
    internal func nonSleepingSpinAccumulates() {
        // When a turn enqueues more work, CFRunLoop skips the sleep and returns
        // straight to beforeWaiting — consecutive idle marks with no afterWaiting
        // between them, which is precisely the relayout loop this hunts. markIdle
        // infers each span from the previous idle mark; that inference is modeled
        // here as back-to-back intervals covering the window with no gaps.
        var intervals: [(start: CFAbsoluteTime, end: CFAbsoluteTime)] = []
        var t = windowStart
        for _ in 0..<10 {
            intervals.append((start: t, end: t + 0.100))
            t += 0.100   // no idle gap at all — the loop never waits
        }
        #expect(abs(busy(intervals) / 1.0 - 1.0) < 1e-9)
    }
}
#endif
