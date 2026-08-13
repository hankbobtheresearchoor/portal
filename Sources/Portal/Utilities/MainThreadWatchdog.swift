import Foundation
import os

// MARK: - Main-thread hang watchdog
//
// The missing tripwire. This app has fixed the same bug class — a beachball /
// spinning cursor from the main thread blocking — at least a dozen times
// (#107, #111, #138, #145, #146, #193, #210, #217, …). Every one was found the
// same way: a human noticed the cursor spinning and went hunting. There was no
// automated detector, so a hang only became visible when someone happened to be
// watching the UI at the instant it stalled.
//
// The three root-cause classes are all the same symptom — the main run loop
// doesn't get back to `beforeWaiting` in time:
//   1. Expensive pure work in a SwiftUI `body` (parse / layout / highlight).
//   2. Layout-oscillation loops (width↔height feedback).
//   3. Synchronous file I/O + JSON decode on the main actor.
//
// This watchdog catches ALL THREE with one mechanism, at the exact stack that
// caused the stall — so a hang becomes a red console fault (or an assertion,
// with `--hang-fatal`) in dev / CI *before* it reaches a user.
//
// HOW IT WORKS
//   - A CFRunLoopObserver on the MAIN run loop marks the thread "busy" when a
//     turn starts (afterWaiting) and "idle" when it's about to sleep
//     (beforeWaiting). A turn that never reaches beforeWaiting is a hang.
//   - A dedicated background monitor thread polls: if the main thread has been
//     busy longer than `thresholdSeconds`, it SUSPENDS the main thread (so its
//     registers are stable), reads its frame pointer + PC via thread_get_state,
//     walks the frame chain, RESUMES it, then symbolicates and reports. The
//     suspend/resume window is just a register read + a stack-memory walk — no
//     allocation, no logging, no main-thread dependency (or it would deadlock).
//
// TWO FAILURE SHAPES, ONE MECHANISM
//   The single-turn hang above is only HALF the beachball surface. A LAYOUT
//   STORM is the opposite signature: not one long turn, but thousands of short
//   ones — each well under `thresholdSeconds`, so the hang detector never trips
//   — that collectively peg the run loop and spin the cursor (the SessionList /
//   ChatViewModel feedback loop behind #254 was exactly this). To catch it, the
//   observer also accumulates each completed busy interval, and the monitor
//   computes the BUSY FRACTION over a rolling window: if the main thread is busy
//   more than `stormBusyFraction` of any `stormWindowSeconds` window across more
//   than one turn, that's a storm. It samples the same suspended-thread stack and
//   fires the same fault — so the storm becomes visible to the tooling instead
//   of only to a human watching the wheel. See #254 (the fix) + this detector
//   (the tripwire that would have caught it).
//
// OBSERVER ORDER IS LOAD-BEARING
//   Both shapes are measured by the run-loop bracket, and a bracket is only as
//   good as its ordering. This file's first version marked busy/idle from one
//   order-0 observer, which put SwiftUI's entire view-graph update — it runs
//   inside a `beforeWaiting` observer — on the IDLE side of the bracket, and a
//   main thread looping on layout at 100% CPU registered as 100% idle. See
//   `busyObserverOrder` for the full account. The lesson generalizes: anything
//   measuring a run-loop turn from inside that turn has to reason explicitly
//   about who else is called out to, and when.
//
// The DETECTION machinery below compiles into BOTH debug and release builds —
// so the same beachball that reached a user can be captured on their machine,
// not just reproduced in a debugger. What differs by configuration is only
// whether it's ENABLED and whether it can escalate to a crash:
//
//   • DEBUG            — on by default (opt out `--no-hang-watchdog`); a
//                        detected stall faults the log, and with `--hang-fatal`
//                        also asserts (so CI UI tests fail on a beachball).
//   • Release, default — OFF. A diagnostic that suspends the main thread to
//                        sample is not something to run on every user's Mac.
//   • Release, opted in — on, LOG-ONLY, never fatal. Turn on with the launch
//                        arg `--hang-watchdog` or the hidden default
//                        `PortalDiagnostics.hangWatchdog` = true. `--hang-fatal`
//                        is compiled out of release entirely, so release capture
//                        can never crash the app — it faults the log and moves on.

/// Whether the hang watchdog runs this launch. See the tiers above.
///
/// DEBUG started life opt-in (`--hang-watchdog`), which meant ordinary
/// `make run` sessions never had it — beachballs kept reaching users undetected
/// and every one required a debugger session to localize. Detection must be the
/// default there for the fault log to replace the debugger. In release it's the
/// reverse: default-off, opt in explicitly, because sampling suspends the main
/// thread and this is a diagnostic rather than a shipping feature.
private let hangWatchdogEnabled: Bool = {
    let arguments = ProcessInfo.processInfo.arguments
    #if DEBUG
    // On by default; `--hang-watchdog` still accepted as a no-op for muscle memory.
    return !arguments.contains("--no-hang-watchdog")
    #else
    // Off by default; opt in via launch arg or a hidden UserDefaults key so a
    // field diagnostic can be turned on without a custom build.
    if arguments.contains("--hang-watchdog") { return true }
    return UserDefaults.standard.bool(forKey: "PortalDiagnostics.hangWatchdog")
    #endif
}()

/// When set (`--hang-fatal`), a detected stall trips `assertionFailure` instead
/// of only logging a fault — use this in CI UI tests so a hang fails the run.
/// DEBUG-only: the flag (and every use of it) is compiled out of release, so a
/// release capture is structurally incapable of crashing the app.
#if DEBUG
private let hangFatalEnabled: Bool = ProcessInfo.processInfo.arguments.contains("--hang-fatal")
#endif

/// Detects main-thread stalls and reports the offending call stack.
///
/// `@unchecked Sendable`: shared mutable state (`isBusy`, `busySince`,
/// `reportedCurrentHang`) is guarded by `lock`, matching the manual-sync
/// pattern LeakTracker uses to satisfy Swift 6 strict concurrency.
internal final class MainThreadWatchdog: @unchecked Sendable {
    // no_new_singletons exempt in .swiftlint.yml alongside the rest of the perf
    // infra (PerfInstrumentation, PerfSampler) — dev-only, DEBUG-gated tooling.
    internal static let shared = MainThreadWatchdog()

    /// A turn longer than this is treated as a hang. 250ms is well past the
    /// ~100ms perceptible-jank threshold but short enough to catch real stalls;
    /// override with `--hang-threshold-ms=N`.
    private let thresholdSeconds: TimeInterval
    /// How often the monitor thread checks. Finer = lower detection latency but
    /// more wakeups; 50ms keeps the watchdog itself cheap.
    private let pollSeconds: TimeInterval = 0.05

    /// Rolling window over which storm busy-fraction is measured. 1s is long
    /// enough to average out a single legitimately-heavy turn but short enough
    /// that a sustained storm trips within ~a second of onset.
    private let stormWindowSeconds: TimeInterval = 1.0
    /// Fraction of the window the main thread must be busy (across ANY number of
    /// turns) to count as a storm. 0.8 means "spinning 4/5 of the time" — well
    /// clear of normal streaming/animation load, which idles between frames.
    /// Override with `--storm-busy-fraction=N` (0–1).
    private let stormBusyFraction: Double
    /// How long the busy fraction must stay saturated before it counts as a
    /// storm. This is the line between a beachball and an animation, and it only
    /// became necessary once the observer-ordering fix (see `busyObserverOrder`)
    /// put framework work inside the measured span — which is where nearly all of
    /// it lives.
    ///
    /// A UI animating at display refresh rate legitimately wakes the run loop
    /// 120–150 times a second, and a few milliseconds of CoreAnimation commit per
    /// frame is 80%+ of a 1s window. Measured on a real launch, that reported
    /// "81% busy across 151 short turns" with a stack deep in
    /// `CA::Context::commit_transaction` — a true reading of a perfectly healthy
    /// app. Reporting it would be worse than useless: the CI gate runs under
    /// `--hang-fatal`, so a false storm crashes the build on any animated launch,
    /// and a tripwire that cries wolf gets disabled.
    ///
    /// Duration separates them cleanly. Animations are bounded — a transition, a
    /// spinner, a scroll — and settle in well under a second. A relayout feedback
    /// loop never settles: the beachball this was written for held 100% CPU for
    /// fifteen minutes. 3s is comfortably longer than any animation this app runs
    /// and still reports a real loop while the user is only starting to wonder why
    /// the cursor is spinning.
    private let stormSustainSeconds: TimeInterval = 3.0
    /// When the busy fraction first crossed `stormBusyFraction` and stayed there.
    /// Zero when not currently saturated. Guarded by `lock`.
    private var stormSaturatedSince: CFAbsoluteTime = 0

    /// Don't call a brief flurry a storm: require the window to actually span
    /// the intended duration AND contain enough turns that this is a churn loop,
    /// not one heavy turn the hang detector already owns.
    ///
    /// 2, not 20. The two detectors have to TILE the space, and at 20 they left a
    /// gap wide enough to hide a beachball in: 20 turns saturating a 1s window
    /// means each averages ~40ms, so a loop of, say, 8 turns of 100ms each pegs
    /// the CPU exactly as hard while being rejected by the storm detector (too
    /// few turns) *and* by the hang detector (each turn under 250ms). Two turns
    /// is the minimum that distinguishes a loop from the single long turn the
    /// hang path already owns — and `checkForStorm` only runs when no hang is in
    /// progress, so that handoff stays clean. The busy FRACTION is what rules out
    /// false positives here; the turn count only has to say "more than one".
    private let stormMinTurns = 2

    // MARK: Observer ordering (the blind spot this file shipped with)

    /// CFRunLoop calls same-activity observers in ascending `order`, and that
    /// ordering is the difference between seeing a beachball and being blind to
    /// it. In a SwiftUI app nearly all of a turn's expensive work — the entire
    /// view-graph update — runs *inside* a `beforeWaiting` observer:
    ///
    ///     __CFRunLoopDoObservers → NSRunLoop.flushObservers
    ///       → NSHostingView.beginTransaction → Update.ensure
    ///       → GraphHost.flushTransactions → AG::Graph::UpdateStack::update
    ///
    /// This watchdog originally registered ONE observer for both activities at
    /// order 0 — the same order SwiftUI's uses — so ours ran first and marked
    /// the thread idle immediately *before* the layout pass it was supposed to
    /// be timing. Every millisecond of that pass then fell outside the busy
    /// span: `checkForHang` bailed on `guard busy` and the storm detector summed
    /// only the sliver of each turn preceding the flush. A main thread pegged at
    /// 100% CPU in an infinite relayout loop read as 100% idle, and the
    /// beachball this whole file exists to catch went unreported.
    ///
    /// Fix: bracket the turn from the OUTSIDE with two observers — mark busy
    /// first among `afterWaiting` observers and idle LAST among `beforeWaiting`
    /// ones — so a framework flush is inside the span whatever order it picks.
    /// Finite sentinels rather than `CFIndex.min`/`.max`: these are already far
    /// past any real framework order (CoreAnimation's commit observer is
    /// 2_000_000) and leave no room for overflow in CFRunLoop's own comparisons.
    /// `internal` so a test can assert the invariant that keeps us honest.
    internal static let busyObserverOrder: CFIndex = -1_000_000_000
    /// See `busyObserverOrder`. Must stay strictly greater than it, and greater
    /// than any observer doing work we need to measure.
    internal static let idleObserverOrder: CFIndex = 1_000_000_000

    private let lock = NSLock()
    private var isBusy = false
    private var busySince: CFAbsoluteTime = 0
    /// One report per hang — don't spam every poll while the thread stays stuck.
    private var reportedCurrentHang = false

    /// Completed busy intervals (start, end), pruned to the rolling storm
    /// window. Appended on each `beforeWaiting`; summed by the monitor thread to
    /// compute the busy fraction. Guarded by `lock`.
    private var busyIntervals: [(start: CFAbsoluteTime, end: CFAbsoluteTime)] = []
    /// When the last `beforeWaiting` fired. Lets `markIdle` attribute a span to
    /// an iteration that never slept (and so never got an `afterWaiting`).
    /// Guarded by `lock`. Zero until the first turn completes.
    private var lastIdleAt: CFAbsoluteTime = 0
    /// Latch so a sustained storm reports once, not every poll. Cleared when the
    /// busy fraction falls back below the threshold (edge-triggered, like the
    /// hang latch clearing on the next `afterWaiting`).
    private var reportedCurrentStorm = false

    /// Persistent mach port for the main thread. `pthread_mach_thread_np` does
    /// not create a send right that must be deallocated (unlike
    /// `mach_thread_self`), so it's safe to cache.
    private var mainMachThread: thread_t = 0
    /// Two observers, not one — see `busyObserverOrder`.
    private var observers: [CFRunLoopObserver] = []
    private var monitor: Thread?
    private var started = false

    private init() {
        var seconds = 0.25
        var fraction = 0.8
        for arg in ProcessInfo.processInfo.arguments {
            if arg.hasPrefix("--hang-threshold-ms="),
               let ms = Double(arg.dropFirst("--hang-threshold-ms=".count)), ms > 0 {
                seconds = ms / 1000
            } else if arg.hasPrefix("--storm-busy-fraction="),
                      let f = Double(arg.dropFirst("--storm-busy-fraction=".count)), f > 0, f <= 1 {
                fraction = f
            }
        }
        self.thresholdSeconds = seconds
        self.stormBusyFraction = fraction
    }

    /// Install the run-loop observer (must be called on the main thread) and
    /// spin up the background monitor. Idempotent.
    @MainActor
    internal func start() {
        guard hangWatchdogEnabled, !started else { return }
        started = true
        mainMachThread = pthread_mach_thread_np(pthread_self())

        // Bracket each turn from the OUTSIDE with two separately-ordered
        // observers: busy first on afterWaiting, idle last on beforeWaiting.
        // A single order-0 observer for both activities put SwiftUI's entire
        // view-graph update — which runs inside a beforeWaiting observer — on
        // the idle side of the bracket. See `busyObserverOrder`.
        let begin = CFRunLoopObserverCreateWithHandler(
            kCFAllocatorDefault, CFRunLoopActivity.afterWaiting.rawValue, true,
            Self.busyObserverOrder
        ) { [weak self] _, _ in
            self?.markBusy(at: CFAbsoluteTimeGetCurrent())
        }
        let end = CFRunLoopObserverCreateWithHandler(
            kCFAllocatorDefault, CFRunLoopActivity.beforeWaiting.rawValue, true,
            Self.idleObserverOrder
        ) { [weak self] _, _ in
            self?.markIdle(at: CFAbsoluteTimeGetCurrent())
        }
        for obs in [begin, end].compactMap({ $0 }) {
            CFRunLoopAddObserver(CFRunLoopGetMain(), obs, .commonModes)
            observers.append(obs)
        }

        let t = Thread { [weak self] in self?.monitorLoop() }
        t.name = "com.ethenotethan.Portal.hang-watchdog"
        t.qualityOfService = .background
        t.start()
        monitor = t

        let ms = Int(thresholdSeconds * 1000)
        let stormPct = Int(stormBusyFraction * 100)
        let stormMs = Int(stormWindowSeconds * 1000)
        #if DEBUG
        let fatal = hangFatalEnabled
        #else
        let fatal = false  // release capture is log-only; --hang-fatal is compiled out
        #endif
        perfLog.debug("hang watchdog started (hang=\(ms)ms storm=\(stormPct)%/\(stormMs)ms fatal=\(fatal))")
    }

    /// A turn began. Split out of the observer handler so the two orders can
    /// share one lock discipline (and so `start()` stays readable).
    private func markBusy(at now: CFAbsoluteTime) {
        lock.lock()
        isBusy = true
        busySince = now
        reportedCurrentHang = false
        lock.unlock()
    }

    /// The turn finished — record its busy span so the monitor can sum busy time
    /// across many short turns (the storm signature). Prunes here too so the
    /// array can't grow unbounded on the observer path.
    ///
    /// `afterWaiting` fires only after the loop actually SLEPT. When a turn
    /// enqueues more work (a relayout invalidating layout again — the very loop
    /// this detector hunts), CFRunLoop skips the sleep and comes straight back
    /// around to `beforeWaiting`, so consecutive idle marks arrive with no busy
    /// mark between them. Attributing nothing to those iterations would re-open
    /// the blind spot one level down, so infer the span from the previous idle
    /// mark: with no wait in between, every microsecond since then was spent
    /// working. That inference is what makes a non-sleeping spin visible.
    private func markIdle(at now: CFAbsoluteTime) {
        lock.lock()
        if isBusy {
            busyIntervals.append((start: busySince, end: now))
        } else if lastIdleAt != 0 {
            // Cap the inferred span at the hang threshold rather than the whole
            // window. An inference is a guess, and it must not be able to trip
            // the detector by itself: the CI gate runs under `--hang-fatal`, so a
            // false storm crashes the build. Capped at 250ms, one bad guess
            // contributes at most a 0.25 fraction — well under the 0.8 threshold
            // — while a real non-sleeping spin (many consecutive sub-threshold
            // iterations, the signature that matters) is still counted in full on
            // every iteration and sums past it. Bounded when wrong, exact when
            // right.
            let start = max(lastIdleAt, now - thresholdSeconds)
            if now > start { busyIntervals.append((start: start, end: now)) }
        }
        pruneBusyIntervals(before: now - stormWindowSeconds)
        isBusy = false
        lastIdleAt = now
        lock.unlock()
    }

    // MARK: Monitor loop (background thread)

    private func monitorLoop() {
        while !Thread.current.isCancelled {
            Thread.sleep(forTimeInterval: pollSeconds)
            // Two independent tripwires, same suspend-and-sample machinery: a
            // single overrun turn (hang) or a rolling window of many short ones
            // (storm). A hang in progress takes precedence — its stack is the
            // more actionable one — so only look for a storm if not hung.
            if !checkForHang() {
                checkForStorm()
            }
        }
    }

    /// One long turn: main thread busy past `thresholdSeconds` without reaching
    /// `beforeWaiting`. Returns true if a hang is currently in progress (whether
    /// or not it was reported this poll), so the caller can skip the storm check.
    private func checkForHang() -> Bool {
        lock.lock()
        let busy = isBusy
        let since = busySince
        let alreadyReported = reportedCurrentHang
        lock.unlock()

        guard busy else { return false }
        let elapsed = CFAbsoluteTimeGetCurrent() - since
        guard elapsed >= thresholdSeconds else { return false }

        if alreadyReported { return true }  // hung, already logged — still hung

        // Latch first so we report this hang exactly once even if the walk
        // below is momentarily slow.
        lock.lock()
        reportedCurrentHang = true
        lock.unlock()

        let frames = captureMainThreadStack()
        report(kind: .hang, elapsed: elapsed, busyFraction: 1, frames: frames)
        return true
    }

    /// Repeated turns with no idle between them: sum the busy intervals over the
    /// rolling window — completed ones plus the turn in flight — and, if the main
    /// thread was busy more than `stormBusyFraction` of it across at least
    /// `stormMinTurns` turns, sample and report once. The latch clears
    /// (edge-triggered) once the fraction drops back down, so a storm that
    /// recurs after settling reports again.
    private func checkForStorm() {
        let now = CFAbsoluteTimeGetCurrent()
        let windowStart = now - stormWindowSeconds

        lock.lock()
        pruneBusyIntervals(before: windowStart)
        var intervals = busyIntervals
        // Include the turn in flight. Only completed intervals get appended (at
        // beforeWaiting), so summing those alone systematically undercounts the
        // fraction by however much of the current turn has elapsed — up to a full
        // poll interval on every sample, in a metric whose whole job is to be
        // compared against a threshold. `busySeconds` clips to the window, so an
        // open span that started before it opened contributes only its tail.
        if isBusy { intervals.append((start: busySince, end: now)) }
        let alreadyReported = reportedCurrentStorm
        lock.unlock()

        let busySeconds = Self.busySeconds(in: intervals, from: windowStart, to: now)
        let fraction = busySeconds / stormWindowSeconds

        // Track how long saturation has held, so a bounded animation (legitimately
        // 80%+ busy while it runs) can be told apart from a loop that never ends.
        let saturatedFor: TimeInterval
        lock.lock()
        if fraction >= stormBusyFraction {
            if stormSaturatedSince == 0 { stormSaturatedSince = now }
            saturatedFor = now - stormSaturatedSince
        } else {
            stormSaturatedSince = 0
            saturatedFor = 0
        }
        lock.unlock()

        let decision = Self.stormDecision(
            busyFraction: fraction, turns: intervals.count,
            threshold: stormBusyFraction, minTurns: stormMinTurns,
            saturatedFor: saturatedFor, sustainSeconds: stormSustainSeconds,
            alreadyReported: alreadyReported
        )
        if decision.clearLatch {
            lock.lock(); reportedCurrentStorm = false; lock.unlock()
        }
        guard decision.report else { return }

        lock.lock(); reportedCurrentStorm = true; lock.unlock()

        // Sample the stack the same way as a hang — odds are high the main
        // thread is mid-turn (it's busy 80%+ of the time), so the frames point
        // at the churn. An empty sample (caught between turns) still reports the
        // storm; the turn count + fraction alone localize it to a churn loop.
        let frames = captureMainThreadStack()
        report(kind: .storm(turns: intervals.count), elapsed: busySeconds,
               busyFraction: fraction, frames: frames)
    }

    /// Whether this poll should report a storm, and whether the once-per-storm
    /// latch should clear. Pure (no clock, no lock) so the tripwire's decision
    /// can be tested directly: the live path only fires from a saturated real run
    /// loop, and an end-to-end probe can't reach it (main-queue blocks don't run
    /// during a launch with no window), so a bug here would otherwise be
    /// invisible — which is precisely how the original ordering bug survived.
    /// `internal` for `@testable` access.
    /// `saturatedFor` is how long the fraction has been continuously above
    /// `threshold`; a storm must sustain past `sustainSeconds` to be reported, so
    /// bounded animation load never trips it. See `stormSustainSeconds`.
    internal static func stormDecision(
        busyFraction: Double, turns: Int, threshold: Double, minTurns: Int,
        saturatedFor: TimeInterval, sustainSeconds: TimeInterval,
        alreadyReported: Bool
    ) -> (report: Bool, clearLatch: Bool) {
        guard busyFraction >= threshold, turns >= minTurns else {
            // Edge-triggered: only the fraction dropping back down rearms the
            // latch, so a storm that settles and recurs reports again — but a
            // window that merely thins below `minTurns` while still saturated
            // does not re-arm and re-report the same ongoing storm.
            return (report: false, clearLatch: alreadyReported && busyFraction < threshold)
        }
        // Saturated, but not yet for long enough to distinguish a stuck loop from
        // an animation. Stay quiet and keep watching.
        guard saturatedFor >= sustainSeconds else { return (report: false, clearLatch: false) }
        return (report: !alreadyReported, clearLatch: false)
    }

    /// Drop busy intervals that ended before the window start. Caller holds
    /// `lock`. Intervals are appended in time order, so a prefix trim suffices.
    private func pruneBusyIntervals(before cutoff: CFAbsoluteTime) {
        var drop = 0
        while drop < busyIntervals.count && busyIntervals[drop].end < cutoff {
            drop += 1
        }
        if drop > 0 { busyIntervals.removeFirst(drop) }
    }

    /// Total busy time within `[from, to]`, clipping each interval to the window
    /// so a turn straddling the window edge only counts its in-window portion.
    /// Pure (no clock, no lock) so the storm math is unit-testable. `internal`
    /// for `@testable` access.
    internal static func busySeconds(
        in intervals: [(start: CFAbsoluteTime, end: CFAbsoluteTime)],
        from windowStart: CFAbsoluteTime, to windowEnd: CFAbsoluteTime
    ) -> TimeInterval {
        var total: TimeInterval = 0
        for interval in intervals {
            let start = max(interval.start, windowStart)
            let end = min(interval.end, windowEnd)
            if end > start { total += end - start }
        }
        return total
    }

    /// Suspend the main thread, read its register state + walk the frame chain,
    /// then resume. Returns raw return-address program counters (symbolicated
    /// later, after the thread is running again, to keep the suspend window
    /// minimal). Empty on an unsupported architecture or a failed read.
    private func captureMainThreadStack() -> [UInt] {
        guard mainMachThread != 0 else { return [] }
        guard thread_suspend(mainMachThread) == KERN_SUCCESS else { return [] }
        defer { thread_resume(mainMachThread) }
        return Self.walkStack(of: mainMachThread)
    }

    // MARK: Reporting

    /// The two beachball shapes this watchdog reports. Both fault + (under
    /// `--hang-fatal`) assert through the same path; only the framing differs.
    private enum StallKind {
        case hang                 // one turn overran the threshold
        case storm(turns: Int)    // many short turns saturated the window
    }

    private func report(kind: StallKind, elapsed: TimeInterval,
                        busyFraction: Double, frames: [UInt]) {
        let ms = Int(elapsed * 1000)
        let symbols = Self.symbolicate(frames)
        let trace = symbols.isEmpty
            ? "  <no symbols — unsupported architecture or unreadable stack>"
            : symbols.enumerated().map { "  \($0.offset): \($0.element)" }.joined(separator: "\n")

        let header: String
        let assertMessage: String
        switch kind {
        case .hang:
            header = """
            🔴 MAIN-THREAD HANG: main thread blocked \(ms)ms (threshold \(Int(thresholdSeconds * 1000))ms).
            This is a beachball. The stack below is the work that stalled the UI — \
            move it off the main actor, memoize it (RenderMemo), or break the layout loop.
            """
            assertMessage = "Main-thread hang (\(ms)ms) — see perf log for the culprit stack"
        case .storm(let turns):
            let pct = Int(busyFraction * 100)
            header = """
            🔴 MAIN-THREAD STORM: main thread busy \(pct)% of the last \
            \(Int(stormWindowSeconds * 1000))ms across \(turns) short turns \
            (threshold \(Int(stormBusyFraction * 100))%), sustained for over \
            \(Int(stormSustainSeconds))s — long past any animation.
            This is a beachball with NO single slow turn — a churn/relayout loop \
            (the #254 SessionList↔ChatViewModel class). The stack below is one \
            sample of the loop; break the feedback cycle driving the re-renders.
            """
            assertMessage = "Main-thread storm (\(turns) turns, \(pct)% busy) — see perf log for a loop sample"
        }
        perfLog.fault("\(header)\n\(trace)")

        #if DEBUG
        if hangFatalEnabled {
            // Escalate to a hard stop so CI UI tests fail on a beachball. Deferred
            // to the main actor so the trap's own backtrace points at the run loop.
            // DEBUG-only: a release capture never crashes — it just faulted above.
            Task { @MainActor in assertionFailure(assertMessage) }
        }
        #else
        _ = assertMessage  // built for the DEBUG escalation only; unused in release
        #endif
    }

    // MARK: Stack walking (architecture-specific)

    /// Read the target thread's frame pointer + PC, then walk saved
    /// {fp, lr} frame records up the stack. The target MUST be suspended by the
    /// caller so its registers and stack memory are stable.
    private static func walkStack(of thread: thread_t) -> [UInt] {
        var pc: UInt = 0
        var fp: UInt = 0

        #if arch(arm64)
        var state = arm_thread_state64_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<arm_thread_state64_t>.size / MemoryLayout<natural_t>.size
        )
        let kr = withUnsafeMutablePointer(to: &state) {
            $0.withMemoryRebound(to: natural_t.self, capacity: Int(count)) {
                thread_get_state(thread, arm_thread_state64_t.flavor, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return [] }
        pc = UInt(state.__pc)
        fp = UInt(state.__fp)
        #elseif arch(x86_64)
        var state = x86_thread_state64_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<x86_thread_state64_t>.size / MemoryLayout<natural_t>.size
        )
        let kr = withUnsafeMutablePointer(to: &state) {
            $0.withMemoryRebound(to: natural_t.self, capacity: Int(count)) {
                thread_get_state(thread, x86_thread_state64_t.flavor, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return [] }
        pc = UInt(state.__rip)
        fp = UInt(state.__rbp)
        #else
        return []
        #endif

        var pcs: [UInt] = pc != 0 ? [pc] : []
        // Frame-pointer walk. Each frame record on the stack is a pair:
        // [saved frame pointer, saved return address]. Guard against a torn or
        // garbage fp: it must be word-aligned, non-zero, and strictly increasing
        // (the stack grows down, so each caller's fp is at a higher address).
        var current = fp
        for _ in 0..<64 {
            guard current != 0, current.isMultiple(of: 8) else { break }
            guard let framePtr = UnsafePointer<UInt>(bitPattern: current) else { break }
            let savedFP = framePtr[0]
            let savedLR = framePtr[1]
            if savedLR != 0 { pcs.append(savedLR) }
            guard savedFP > current else { break }
            current = savedFP
        }
        return pcs
    }

    /// Turn raw return addresses into human-readable frames via dladdr. Runs
    /// after the main thread has resumed — it must not be inside the suspend
    /// window. Drops this file's own frames so the top of the trace is the
    /// culprit, not the watchdog.
    private static func symbolicate(_ pcs: [UInt]) -> [String] {
        pcs.map { pc -> String in
            var info = Dl_info()
            guard dladdr(UnsafeRawPointer(bitPattern: pc), &info) != 0,
                  let namePtr = info.dli_sname else {
                return String(format: "0x%016lx", pc)
            }
            let symbol = String(cString: namePtr)
            return Self.demangle(symbol) ?? symbol
        }
    }

    /// Demangle a Swift symbol via the public `swift_demangle` runtime entry
    /// point (the `_stdlib_demangleName` SPI isn't importable from app code).
    /// Returns nil for C/ObjC symbols, which are already readable.
    private static func demangle(_ symbol: String) -> String? {
        guard symbol.hasPrefix("$s") || symbol.hasPrefix("_$s") else { return nil }
        guard let fn = Self.swiftDemangleFn else { return nil }
        return symbol.withCString { cString in
            guard let out = fn(cString, strlen(cString), nil, nil, 0) else { return nil }
            defer { free(out) }
            return String(cString: out)
        }
    }

    /// C signature of the Swift runtime's `swift_demangle`:
    /// `(mangledName, mangledNameLength, outputBuffer, outputBufferSize, flags)`.
    private typealias SwiftDemangleFn = @convention(c) (
        UnsafePointer<CChar>?, Int, UnsafeMutablePointer<CChar>?, UnsafeMutablePointer<Int>?, UInt32
    ) -> UnsafeMutablePointer<CChar>?

    /// Resolved once. `swift_demangle` isn't exposed to Swift, but it's a public
    /// runtime symbol reachable via dlsym (RTLD_DEFAULT). nil if unavailable —
    /// callers fall back to the mangled name, which still identifies the frame.
    private static let swiftDemangleFn: SwiftDemangleFn? = {
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "swift_demangle") else { return nil }
        return unsafeBitCast(sym, to: SwiftDemangleFn.self)
    }()
}

// arm_thread_state64_t / x86_thread_state64_t don't expose their `flavor`
// constant as a typed member the way some Apple headers do in ObjC; provide it
// so the call sites above read cleanly and stay arch-local.
#if arch(arm64)
private extension arm_thread_state64_t {
    static var flavor: thread_state_flavor_t { thread_state_flavor_t(ARM_THREAD_STATE64) }
}
#elseif arch(x86_64)
private extension x86_thread_state64_t {
    static var flavor: thread_state_flavor_t { thread_state_flavor_t(x86_THREAD_STATE64) }
}
#endif
