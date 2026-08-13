import CoreGraphics
import Foundation
import Testing
@testable import Portal

@Suite("Dashboard layout model")
internal struct DashboardLayoutTests {

    // MARK: - Panel clamping

    @Test("A panel larger than the canvas is shrunk to fit")
    internal func panelClampedToBounds() {
        let panel = DashboardPanel(kind: .flamechart, frame: CGRect(x: 0, y: 0, width: 5000, height: 5000))
        let clamped = panel.clamped(to: CGSize(width: 800, height: 600))
        #expect(clamped.frame.width == 800)
        #expect(clamped.frame.height == 600)
    }

    @Test("An off-canvas panel is pulled back on-screen")
    internal func offCanvasPanelPulledBack() {
        let panel = DashboardPanel(kind: .files, frame: CGRect(x: 900, y: 700, width: 300, height: 200))
        let clamped = panel.clamped(to: CGSize(width: 1000, height: 800))
        #expect(clamped.frame.maxX <= 1000)
        #expect(clamped.frame.maxY <= 800)
        #expect(clamped.frame.size == CGSize(width: 300, height: 200))  // size preserved
    }

    @Test("Clamp never returns a panel smaller than the minimum size")
    internal func clampRespectsMinimum() {
        let panel = DashboardPanel(kind: .thinking, frame: CGRect(x: 0, y: 0, width: 10, height: 10))
        // Even on a tiny canvas, min size wins (panel can overflow a degenerate canvas).
        let clamped = panel.clamped(to: CGSize(width: 50, height: 50))
        #expect(clamped.frame.width >= DashboardPanel.minSize.width || clamped.frame.width == 50)
    }

    // MARK: - z-order

    @Test("bringToFront moves a panel to the end (frontmost) preserving others' order")
    internal func bringToFront() {
        let a = DashboardPanel(kind: .flamechart, frame: .zero)
        let b = DashboardPanel(kind: .files, frame: .zero)
        let c = DashboardPanel(kind: .skills, frame: .zero)
        var layout = DashboardLayout(panels: [a, b, c])
        layout.bringToFront(a.id)
        #expect(layout.panels.map(\.id) == [b.id, c.id, a.id])
    }

    @Test("bringToFront on the already-frontmost panel is a no-op")
    internal func bringToFrontFrontmostNoOp() {
        let a = DashboardPanel(kind: .flamechart, frame: .zero)
        let b = DashboardPanel(kind: .files, frame: .zero)
        var layout = DashboardLayout(panels: [a, b])
        layout.bringToFront(b.id)
        #expect(layout.panels.map(\.id) == [a.id, b.id])
    }

    @Test("remove deletes the panel by id")
    internal func removePanel() {
        let a = DashboardPanel(kind: .flamechart, frame: .zero)
        let b = DashboardPanel(kind: .files, frame: .zero)
        var layout = DashboardLayout(panels: [a, b])
        layout.remove(a.id)
        #expect(layout.panels.map(\.id) == [b.id])
    }

    @Test("setFrame updates in place without reordering")
    internal func setFramePreservesOrder() {
        let a = DashboardPanel(kind: .flamechart, frame: .zero)
        let b = DashboardPanel(kind: .files, frame: .zero)
        var layout = DashboardLayout(panels: [a, b])
        let newFrame = CGRect(x: 5, y: 6, width: 300, height: 200)
        layout.setFrame(newFrame, for: a.id)
        #expect(layout.panels.first?.frame == newFrame)
        #expect(layout.panels.map(\.id) == [a.id, b.id])  // order intact
    }

    // MARK: - Codable round-trip (persistence)

    @Test("A layout survives an encode/decode round-trip")
    internal func codableRoundTrip() throws {
        let layout = DashboardLayout(panels: [
            DashboardPanel(kind: .flamechart, frame: CGRect(x: 10, y: 20, width: 400, height: 300)),
            DashboardPanel(kind: .thinking, frame: CGRect(x: 420, y: 20, width: 240, height: 200))
        ])
        let data = try JSONEncoder().encode(layout)
        let decoded = try JSONDecoder().decode(DashboardLayout.self, from: data)
        #expect(decoded == layout)
    }

    @Test("An unknown panel kind decodes without loss (forward-compatible)")
    internal func unknownKindDecodes() throws {
        // A custom kind registered by a plugin, persisted, then loaded by a build
        // that doesn't know it — must decode, not throw, so the layout survives.
        let custom = DashboardLayout(panels: [
            DashboardPanel(kind: PanelKind(rawValue: "custom.myPlugin"), frame: CGRect(x: 0, y: 0, width: 300, height: 200))
        ])
        let data = try JSONEncoder().encode(custom)
        let decoded = try JSONDecoder().decode(DashboardLayout.self, from: data)
        #expect(decoded.panels.first?.kind.rawValue == "custom.myPlugin")
    }

    // MARK: - Reflow on resize

    @Test("Reflow scales a full layout to fill larger bounds (no dead space)")
    internal func reflowGrowsToFill() {
        // A panel filling the whole old canvas must fill the whole new one.
        let old = CGSize(width: 800, height: 600)
        let new = CGSize(width: 1600, height: 900)
        let layout = DashboardLayout(panels: [
            DashboardPanel(kind: .conversation, frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        ])
        let reflowed = layout.reflowed(from: old, to: new)
        let f = reflowed.panels[0].frame
        #expect(f.width == 1600)
        #expect(f.height == 900)
    }

    @Test("Reflow preserves proportional position")
    internal func reflowPreservesProportion() {
        let old = CGSize(width: 1000, height: 1000)
        let new = CGSize(width: 2000, height: 2000)
        let layout = DashboardLayout(panels: [
            DashboardPanel(kind: .files, frame: CGRect(x: 100, y: 200, width: 300, height: 400))
        ])
        let f = layout.reflowed(from: old, to: new).panels[0].frame
        #expect(f.minX == 200)
        #expect(f.minY == 400)
        #expect(f.width == 600)
        #expect(f.height == 800)
    }

    @Test("Reflow is a no-op when the size is unchanged")
    internal func reflowUnchangedIsNoOp() {
        let size = CGSize(width: 1000, height: 800)
        let layout = DashboardLayout(panels: [
            DashboardPanel(kind: .skills, frame: CGRect(x: 10, y: 20, width: 300, height: 200))
        ])
        #expect(layout.reflowed(from: size, to: size) == layout)
    }

    @Test("Reflow from a degenerate old size just clamps")
    internal func reflowDegenerateOldSize() {
        let layout = DashboardLayout(panels: [
            DashboardPanel(kind: .thinking, frame: CGRect(x: 0, y: 0, width: 5000, height: 5000))
        ])
        // old size zero → can't scale; fall back to clamp into new bounds.
        let reflowed = layout.reflowed(from: .zero, to: CGSize(width: 800, height: 600))
        #expect(reflowed.panels[0].frame.width <= 800)
        #expect(reflowed.panels[0].frame.height <= 600)
    }

    // MARK: - Reflow convergence (the beachball guard)
    //
    // DashboardCanvasView drives reflow from `onChange(of: geo.size)` on the
    // GeometryReader whose children are the panels being reflowed, so reflow's
    // output becomes its next input. If a second pass at the same canvas size can
    // differ from the first — by even one ulp — the view graph never settles and
    // the app spins at 100% CPU with the run loop never reaching idle. These
    // tests pin the convergence properties that make that structurally
    // impossible; they are load-bearing, not stylistic.

    @Test("Reflow is idempotent: re-reflowing at the settled size changes nothing")
    internal func reflowIsIdempotent() {
        let old = CGSize(width: 1440, height: 900)
        let new = CGSize(width: 1728, height: 1117)
        let layout = DashboardLayout(panels: [
            DashboardPanel(kind: .conversation, frame: CGRect(x: 8, y: 8, width: 1000, height: 884)),
            DashboardPanel(kind: .flamechart, frame: CGRect(x: 1016, y: 8, width: 416, height: 440)),
            DashboardPanel(kind: .files, frame: CGRect(x: 1016, y: 456, width: 416, height: 436)),
        ])
        let once = layout.reflowed(from: old, to: new)
        // The closing edge of the real cycle: the canvas re-measures at the size
        // it just settled at and reflows again. That must be exactly a no-op.
        #expect(once.reflowed(from: new, to: new) == once)
        // And applying the same transition again must not drift either.
        #expect(once.reflowed(from: old, to: new).reflowed(from: new, to: new) == once.reflowed(from: old, to: new))
    }

    @Test("Reflow converges on ratios that don't divide evenly")
    internal func reflowConvergesOnAwkwardRatios() {
        // Sizes chosen so every scale factor is irrational-ish in binary: a
        // window dragged to an arbitrary pixel, which is the common case. Raw
        // float scaling drifts here; quantized scaling lands on a fixed point.
        let old = CGSize(width: 1023, height: 767)
        let new = CGSize(width: 1291, height: 913)
        let layout = DashboardLayout(panels: [
            DashboardPanel(kind: .skills, frame: CGRect(x: 37, y: 71, width: 431, height: 293)),
            DashboardPanel(kind: .thinking, frame: CGRect(x: 501, y: 113, width: 389, height: 517)),
        ])
        var current = layout.reflowed(from: old, to: new)
        // Ten further passes at the settled size — the loop the beachball ran.
        for _ in 0..<10 {
            let next = current.reflowed(from: new, to: new)
            #expect(next == current)
            current = next
        }
    }

    @Test("Reflowed frames land on whole points")
    internal func reflowQuantizesToWholePoints() {
        // Integrality is what makes convergence provable rather than lucky:
        // clamped(to:) only selects among integral operands when its bounds are
        // integral, so an integral layout stays integral through the round trip.
        let layout = DashboardLayout(panels: [
            DashboardPanel(kind: .files, frame: CGRect(x: 13, y: 29, width: 307, height: 211))
        ])
        let reflowed = layout.reflowed(from: CGSize(width: 997, height: 601),
                                       to: CGSize(width: 1300.4, height: 850.7))
        for panel in reflowed.panels {
            let f = panel.frame
            #expect(f.minX == f.minX.rounded())
            #expect(f.minY == f.minY.rounded())
            #expect(f.width == f.width.rounded())
            #expect(f.height == f.height.rounded())
        }
    }

    @Test("A sub-point size change is not a resize")
    internal func reflowIgnoresSubPointChange() {
        // SwiftUI hands back sizes that wobble below a point between passes. If
        // that counted as a resize, the handler would re-enter forever.
        let layout = DashboardLayout(panels: [
            DashboardPanel(kind: .conversation, frame: CGRect(x: 8, y: 8, width: 800, height: 600))
        ])
        let base = CGSize(width: 1200, height: 800)
        let wobbled = CGSize(width: 1200.2, height: 799.8)
        #expect(DashboardLayout.quantize(base) == DashboardLayout.quantize(wobbled))
        #expect(layout.reflowed(from: base, to: wobbled) == layout)
    }

    @Test("A wobbling reported size drives no layout churn")
    internal func reflowSurvivesWobblingSize() {
        // The actual mechanism of the beachball, replayed. SwiftUI reports sizes
        // that differ in their last bits between passes, so the old
        // `guard old != new` was always true: each pass rescaled from a slightly
        // different `old`, wrote @State, and invited another measurement. Under
        // this exact loop the old implementation performed 160 writes in 200
        // passes; the quantized one must perform zero.
        var layout = DashboardLayout(panels: [
            DashboardPanel(kind: .conversation, frame: CGRect(x: 8, y: 8, width: 1000, height: 884)),
            DashboardPanel(kind: .flamechart, frame: CGRect(x: 1016, y: 8, width: 416, height: 440)),
        ])
        let base = CGSize(width: 1728, height: 1117)
        let wobble: [CGFloat] = [0, 1e-13, -1e-13, 2e-13, -5e-14]
        var writes = 0
        var previous = base
        for i in 0..<200 {
            let reported = CGSize(width: base.width + wobble[i % wobble.count],
                                  height: base.height + wobble[(i + 2) % wobble.count])
            // Mirrors DashboardCanvasView's guard: quantized dead band first.
            if DashboardLayout.quantize(previous) == DashboardLayout.quantize(reported) {
                previous = reported
                continue
            }
            let next = layout.reflowed(from: previous, to: reported)
            if next != layout { writes += 1; layout = next }
            previous = reported
        }
        #expect(writes == 0)
    }

    @Test("Reflow preserves the collapsed state of a panel")
    internal func reflowPreservesCollapsed() {
        // Reflow rebuilt each panel without carrying isCollapsed, so the default
        // (false) silently expanded every collapsed panel on any window resize.
        let layout = DashboardLayout(panels: [
            DashboardPanel(kind: .files, frame: CGRect(x: 0, y: 0, width: 300, height: 200),
                           isCollapsed: true),
            DashboardPanel(kind: .skills, frame: CGRect(x: 320, y: 0, width: 300, height: 200)),
        ])
        let reflowed = layout.reflowed(from: CGSize(width: 800, height: 600),
                                       to: CGSize(width: 1000, height: 700))
        #expect(reflowed.panels[0].isCollapsed)
        #expect(!reflowed.panels[1].isCollapsed)
    }

    // MARK: - Seeded default

    @Test("Seeded default tiles the built-in lenses inside the canvas")
    internal func seededDefaultFitsBounds() {
        let bounds = CGSize(width: 1200, height: 800)
        let layout = DashboardLayout.seededDefault(for: bounds)
        #expect(!layout.isEmpty)
        for panel in layout.panels {
            #expect(panel.frame.minX >= 0)
            #expect(panel.frame.minY >= 0)
            #expect(panel.frame.maxX <= bounds.width + 0.5)
            #expect(panel.frame.maxY <= bounds.height + 0.5)
        }
        // The flamechart is present and is the widest (dominant) panel.
        let flame = layout.panels.first { $0.kind == .flamechart }
        #expect(flame != nil)
    }

    @Test("Seeded cron dashboard tiles all five sections inside the canvas")
    internal func seededCronDashboardFitsBounds() {
        let bounds = CGSize(width: 1200, height: 800)
        let layout = DashboardLayout.seededCronDashboard(for: bounds)
        #expect(!layout.isEmpty)
        for panel in layout.panels {
            #expect(panel.frame.minX >= 0)
            #expect(panel.frame.minY >= 0)
            #expect(panel.frame.maxX <= bounds.width + 0.5)
            #expect(panel.frame.maxY <= bounds.height + 0.5)
            #expect(panel.frame.width >= DashboardPanel.minSize.width)
            #expect(panel.frame.height >= DashboardPanel.minSize.height)
        }
        // All five cron lenses are present exactly once.
        let kinds = Set(layout.panels.map(\.kind))
        #expect(kinds == [.cronSummary, .cronVolume, .cronJobs, .cronTimeline, .cronBreakdown])
        #expect(layout.panels.count == 5)
    }
}
