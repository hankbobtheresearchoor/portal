import CoreGraphics
import Foundation
import os

private let layoutLog = Logger(subsystem: "com.researchoors.HermesNative", category: "DashboardLayout")

/// The user's arrangement of panels on the thought-graph dashboard canvas.
/// Persisted as one personal layout (not per-session yet) so the composition a
/// user builds is the composition they get back next time they open the graph.
/// Ordered back-to-front: `panels.last` draws on top and is the focused panel.
internal struct DashboardLayout: Codable, Equatable {
    internal var panels: [DashboardPanel]

    internal init(panels: [DashboardPanel] = []) {
        self.panels = panels
    }

    internal var isEmpty: Bool { panels.isEmpty }

    // MARK: Mutation (front-to-back ordering via array position)

    /// Bring a panel to the front (end of array) so it draws over its
    /// neighbors and receives the next drag. No-op if already frontmost or absent.
    internal mutating func bringToFront(_ id: UUID) {
        guard let idx = panels.firstIndex(where: { $0.id == id }), idx != panels.count - 1 else { return }
        let panel = panels.remove(at: idx)
        panels.append(panel)
    }

    internal mutating func remove(_ id: UUID) {
        panels.removeAll { $0.id == id }
    }

    /// Remove all panels of a given kind (e.g. when docking a lens inside the
    /// conversation panel — the canvas tile is removed and replaced by the dock).
    internal mutating func remove(_ kind: PanelKind) {
        panels.removeAll { $0.kind == kind }
    }

    /// Replace a panel's frame in place (after a drag or resize), preserving order.
    internal mutating func setFrame(_ frame: CGRect, for id: UUID) {
        guard let idx = panels.firstIndex(where: { $0.id == id }) else { return }
        panels[idx].frame = frame
    }

    /// Toggle the collapsed state of a panel in place.
    internal mutating func toggleCollapsed(_ id: UUID) {
        guard let idx = panels.firstIndex(where: { $0.id == id }) else { return }
        panels[idx].isCollapsed.toggle()
    }

    /// Clamp every panel into the given canvas bounds (window resized, or a
    /// layout saved on a bigger screen is being restored on a smaller one).
    internal func clamped(to bounds: CGSize) -> DashboardLayout {
        guard bounds.width > 0, bounds.height > 0 else { return self }
        return DashboardLayout(panels: panels.map { $0.clamped(to: bounds) })
    }

    /// Snap a canvas size to whole points. Reflow works entirely in this
    /// quantized domain — see `reflowed(from:to:)` for why that's load-bearing
    /// rather than cosmetic.
    internal static func quantize(_ size: CGSize) -> CGSize {
        CGSize(width: size.width.rounded(), height: size.height.rounded())
    }

    /// Scale every panel's frame proportionally when the canvas changes size, so
    /// a layout that filled the old bounds still fills the new ones (going
    /// fullscreen grows the panels instead of leaving dead space; shrinking packs
    /// them back). Origins and sizes scale by the per-axis ratio, then clamp.
    /// No-op when either size is degenerate, or when neither size changes by a
    /// whole point.
    ///
    /// **This function must be a fixed point**, and that requirement comes from
    /// its caller, not from taste. `DashboardCanvasView` drives it from
    /// `onChange(of: geo.size)` on a `GeometryReader` whose own children are the
    /// panels being resized, so the output is fed back into the input: measure →
    /// write `layout` → relayout → measure again. If a second pass at the same
    /// canvas size can produce even a sub-point-different layout, that feedback
    /// never converges — the view graph re-runs forever, the run loop never
    /// reaches idle, and the app beachballs at 100% CPU.
    ///
    /// The old `guard old != new` looked like it prevented that and didn't. The
    /// sizes SwiftUI reports across passes differ in their last bits, so exact
    /// inequality is *always* true: every pass rescaled from a marginally
    /// different `old`, produced a marginally different layout, wrote `@State`,
    /// and invited another measurement. Replayed with sizes wobbling at 1e-13,
    /// the old code performs 160 state writes in 200 passes; this version
    /// performs none. Same failure mode `ChatLayoutMath` exists to prevent on the
    /// chat surface, same fix — quantize, then compare.
    ///
    /// Quantizing to whole points makes convergence structural rather than
    /// probabilistic: both sizes snap to integers, the scaled frames round, and
    /// `clamped(to:)` preserves integrality when its bounds are integral (its
    /// `min`/`max` only ever select among integral operands). So identical
    /// quantized bounds always yield a byte-identical layout, the `old == new`
    /// guard short-circuits the second pass, and the cycle closes after one step.
    /// A half-point of panel position is invisible; a beachball is not.
    internal func reflowed(from old: CGSize, to new: CGSize) -> DashboardLayout {
        let oldQ = Self.quantize(old)
        let newQ = Self.quantize(new)
        guard oldQ.width > 0, oldQ.height > 0, newQ.width > 0, newQ.height > 0 else {
            return clamped(to: newQ)
        }
        guard oldQ != newQ else { return self }
        let sx = newQ.width / oldQ.width
        let sy = newQ.height / oldQ.height
        let scaled = panels.map { panel -> DashboardPanel in
            let f = panel.frame
            let reframed = CGRect(
                x: (f.minX * sx).rounded(), y: (f.minY * sy).rounded(),
                width: (f.width * sx).rounded(), height: (f.height * sy).rounded()
            )
            // Carry `isCollapsed` across: dropping it (the default is `false`)
            // silently expanded every collapsed panel on any window resize.
            return DashboardPanel(
                id: panel.id, kind: panel.kind, frame: reframed,
                isCollapsed: panel.isCollapsed
            )
        }
        return DashboardLayout(panels: scaled).clamped(to: newQ)
    }

    // MARK: Persistence

    /// The session-graph dashboard's layout (past-turn lenses). v2: v1 layouts
    /// could be saved with overlapping panels by the pre-fix drag bug (every drag
    /// was silently a bottom-right resize); bumping the key discards those so the
    /// clean tiling re-seeds.
    internal static let dashboardKey = "thoughtDashboardLayout.v2"
    /// The live chat canvas's layout (conversation panel + live lenses). Kept
    /// separate so arranging one surface never disturbs the other. v2 for the
    /// same reason as `dashboardKey` — drop stale overlapping arrangements.
    ///
    /// Legacy: pre-split, Scroll and Turns shared this single key, so arranging
    /// one silently rearranged the other. It's now only read as a one-time
    /// migration seed for the two mode-specific keys below (see `chatScrollKey` /
    /// `chatTurnsKey`) — never written to.
    internal static let chatCanvasKey = "sessionChatCanvasLayout.v2"
    /// The live chat canvas's **Scroll** layout — the ever-growing transcript
    /// board where per-turn blocks peel out and layer into the scroll. Separate
    /// from Turns so rearranging one mode never disturbs the other.
    internal static let chatScrollKey = "sessionChatCanvasLayout.scroll.v1"
    /// The live chat canvas's **Turns** layout — the one-settled-turn-at-a-time
    /// board. Its own persisted arrangement, independent of Scroll.
    internal static let chatTurnsKey = "sessionChatCanvasLayout.turns.v1"
    /// The sessions dashboard canvas layout (list + timeline panels).
    internal static let sessionsDashboardKey = "sessionsDashboardLayout.v4"
    /// The cron activity canvas layout (summary + volume + jobs + timeline + breakdown).
    internal static let cronDashboardKey = "cronDashboardLayout.v1"
    /// The skills canvas layout (folders + list + detail + stats).
    internal static let skillsDashboardKey = "skillsDashboardLayout.v1"

    /// Load the saved layout for `key`, or `nil` if the user has never arranged
    /// one (the caller then seeds a sensible default). Corrupt JSON is logged and
    /// treated as absent rather than throwing — a broken layout should never
    /// block the surface; the caller just re-seeds the default.
    internal static func loadStored(key: String = dashboardKey) -> DashboardLayout? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        do {
            let layout = try JSONDecoder().decode(DashboardLayout.self, from: data)
            return layout.isEmpty ? nil : layout
        } catch {
            layoutLog.error("dashboard layout load failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// Load a chat-canvas mode's stored layout (`chatScrollKey` / `chatTurnsKey`),
    /// falling back once to the pre-split combined layout (`chatCanvasKey`) so a
    /// user who arranged the canvas before the Scroll/Turns split doesn't lose it
    /// — both modes seed from the old arrangement, then diverge as each is edited.
    /// Returns `nil` only when neither the mode key nor the legacy key has data
    /// (the caller then seeds the tiled default).
    internal static func loadStoredChatMode(_ modeKey: String) -> DashboardLayout? {
        loadStored(key: modeKey) ?? loadStored(key: chatCanvasKey)
    }

    /// Persist this layout under `key`. Logs and no-ops on an encode failure —
    /// losing a layout is preferable to a crash.
    internal func store(key: String = Self.dashboardKey) {
        do {
            let data = try JSONEncoder().encode(self)
            UserDefaults.standard.set(data, forKey: key)
        } catch {
            layoutLog.error("dashboard layout store failed: \(error.localizedDescription)")
        }
    }

    /// A first-run tiled arrangement, laid out for the given canvas size. Mirrors
    /// today's fixed panes (flamechart dominant, files + skills stacked to its
    /// right) so opening the dashboard the first time looks familiar, then the
    /// user rearranges from there.
    internal static func seededDefault(for bounds: CGSize) -> DashboardLayout {
        let w = max(bounds.width, DashboardPanel.minSize.width * 2 + 24)
        let h = max(bounds.height, DashboardPanel.minSize.height * 2 + 24)
        let gap: CGFloat = 8
        let rightColumnWidth = max(DashboardPanel.minSize.width, w * 0.28)
        let leftWidth = w - rightColumnWidth - gap * 3
        let rightX = leftWidth + gap * 2
        let halfH = (h - gap * 3) / 2
        return DashboardLayout(panels: [
            DashboardPanel(
                kind: .flamechart,
                frame: CGRect(x: gap, y: gap, width: leftWidth, height: h - gap * 2)
            ),
            DashboardPanel(
                kind: .files,
                frame: CGRect(x: rightX, y: gap, width: rightColumnWidth, height: halfH)
            ),
            DashboardPanel(
                kind: .skills,
                frame: CGRect(x: rightX, y: gap * 2 + halfH, width: rightColumnWidth, height: halfH)
            )
        ]).clamped(to: bounds)
    }

    /// First-run arrangement for the **sessions dashboard canvas**:
    ///
    /// ```
    /// ┌────────────────┬─────────────┬──────────────┐
    /// │  Search        │   Stats     │              │
    /// ├────────────────┼─────────────┤   Timeline   │
    /// │  Sessions list │  Breakdown  │              │
    /// └────────────────┴─────────────┴──────────────┘
    /// ```
    internal static func seededSessionsDashboard(for bounds: CGSize) -> DashboardLayout {
        let w = max(bounds.width, DashboardPanel.minSize.width * 3 + 32)
        let h = max(bounds.height, DashboardPanel.minSize.height * 2 + 24)
        let gap: CGFloat = 8
        // columns: left 38%, mid 27%, right 35%
        let rightW = max(DashboardPanel.minSize.width, w * 0.35)
        let midW   = max(DashboardPanel.minSize.width, w * 0.27)
        let leftW  = w - rightW - midW - gap * 4
        let midX   = gap + leftW + gap
        let rightX = midX + midW + gap
        let statsH: CGFloat   = 200
        let breakdownY = gap + statsH + gap
        let breakdownH = h - breakdownY - gap
        return DashboardLayout(panels: [
            DashboardPanel(kind: .sessionsList,
                frame: CGRect(x: gap, y: gap, width: leftW, height: h - gap * 2)),
            DashboardPanel(kind: .sessionsStats,
                frame: CGRect(x: midX, y: gap, width: midW, height: statsH)),
            DashboardPanel(kind: .sessionsSourceBreakdown,
                frame: CGRect(x: midX, y: breakdownY, width: midW, height: breakdownH)),
            DashboardPanel(kind: .sessionsTimeline,
                frame: CGRect(x: rightX, y: gap, width: rightW, height: h - gap * 2)),
        ]).clamped(to: bounds)
    }

    /// First-run arrangement for the live **chat canvas**: the conversation
    /// dominates the left, with the live flamechart and tools stacked in a right
    /// column. Mirrors how the chat reads today (transcript primary, activity
    /// alongside) so flipping into Canvas mode looks familiar, then the user
    /// rearranges — including dragging the conversation itself.
    /// The default canvas: ONE full-bleed conversation panel. This is the
    /// classic chat expressed as a canvas — the conversation alone, filling the
    /// space. The live lenses (flamechart, tools, thinking, skills, files) and
    /// artifacts are added by the user or peeled out; while the conversation is
    /// the only panel it runs in solo mode and shows the inline live strip, so a
    /// bare canvas reads exactly like today's transcript.
    /// First-run arrangement for the **cron activity canvas**:
    ///
    /// ```
    /// ┌── Summary ──────────────┬──────────────┐
    /// ├── Volume ───────────────┤     Jobs     │
    /// ├── Timeline ─────────────┤              │
    /// │            Breakdown    │              │
    /// └─────────────────────────┴──────────────┘
    /// ```
    /// Left column stacks the charts (summary strip, volume, timeline,
    /// breakdown); the jobs list rides full-height on the right.
    internal static func seededCronDashboard(for bounds: CGSize) -> DashboardLayout {
        let w = max(bounds.width, DashboardPanel.minSize.width * 2 + 24)
        let h = max(bounds.height, DashboardPanel.minSize.height * 3 + 32)
        let gap: CGFloat = 8
        let rightW = max(DashboardPanel.minSize.width, w * 0.34)
        let leftW = w - rightW - gap * 3
        let rightX = gap + leftW + gap
        let summaryH: CGFloat = 96
        let remaining = h - gap * 5 - summaryH
        let chartH = max(DashboardPanel.minSize.height, remaining / 3)
        let volumeY = gap + summaryH + gap
        let timelineY = volumeY + chartH + gap
        let breakdownY = timelineY + chartH + gap
        return DashboardLayout(panels: [
            DashboardPanel(kind: .cronSummary,
                frame: CGRect(x: gap, y: gap, width: leftW, height: summaryH)),
            DashboardPanel(kind: .cronVolume,
                frame: CGRect(x: gap, y: volumeY, width: leftW, height: chartH)),
            DashboardPanel(kind: .cronTimeline,
                frame: CGRect(x: gap, y: timelineY, width: leftW, height: chartH)),
            DashboardPanel(kind: .cronBreakdown,
                frame: CGRect(x: gap, y: breakdownY, width: leftW, height: chartH)),
            DashboardPanel(kind: .cronJobs,
                frame: CGRect(x: rightX, y: gap, width: rightW, height: h - gap * 2)),
        ]).clamped(to: bounds)
    }

    /// First-run arrangement for the **skills canvas**:
    ///
    /// ```
    /// ┌───────────┬─────────────────────┬────────────┐
    /// │  Folders  │       Stats         │            │
    /// │           ├─────────────────────┤   Detail   │
    /// │           │    Skills list      │            │
    /// └───────────┴─────────────────────┴────────────┘
    /// ```
    /// Folders on the left (navigation), the roll-down list in the middle (the
    /// classic Skills view), and the inspector on the right — the shape a file
    /// browser trains people to expect, so the canvas reads before it's rearranged.
    /// The editor and hub are addable but not seeded: both are large, and neither
    /// is useful until a skill is selected or a search is typed.
    internal static func seededSkillsDashboard(for bounds: CGSize) -> DashboardLayout {
        let w = max(bounds.width, DashboardPanel.minSize.width * 3 + 32)
        let h = max(bounds.height, DashboardPanel.minSize.height * 2 + 24)
        let gap: CGFloat = 8
        // columns: folders 24%, list 44%, detail 32%
        let foldersW = max(DashboardPanel.minSize.width, w * 0.24)
        let detailW  = max(DashboardPanel.minSize.width, w * 0.32)
        let listW    = w - foldersW - detailW - gap * 4
        let listX    = gap + foldersW + gap
        let detailX  = listX + listW + gap
        // minSize.height, not a smaller "nice" number: `clamped(to:)` grows any
        // shorter panel back up to the minimum, which would push the stats strip
        // down over the list it is supposed to sit above.
        let statsH = DashboardPanel.minSize.height
        let listY = gap + statsH + gap
        let listH = h - listY - gap
        return DashboardLayout(panels: [
            DashboardPanel(kind: .skillsFolders,
                frame: CGRect(x: gap, y: gap, width: foldersW, height: h - gap * 2)),
            DashboardPanel(kind: .skillsStats,
                frame: CGRect(x: listX, y: gap, width: listW, height: statsH)),
            DashboardPanel(kind: .skillsList,
                frame: CGRect(x: listX, y: listY, width: listW, height: listH)),
            DashboardPanel(kind: .skillsDetail,
                frame: CGRect(x: detailX, y: gap, width: detailW, height: h - gap * 2)),
        ]).clamped(to: bounds)
    }

    internal static func seededChatCanvas(for bounds: CGSize) -> DashboardLayout {
        let w = max(bounds.width, DashboardPanel.minSize.width)
        let h = max(bounds.height, DashboardPanel.minSize.height)
        let gap: CGFloat = 8
        return DashboardLayout(panels: [
            DashboardPanel(
                kind: .conversation,
                frame: CGRect(x: gap, y: gap, width: w - gap * 2, height: h - gap * 2)
            )
        ]).clamped(to: bounds)
    }
}
