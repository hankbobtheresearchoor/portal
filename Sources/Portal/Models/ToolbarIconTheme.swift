import CoreGraphics
import Foundation
import OSLog

private let toolbarIconLog = Logger(subsystem: "com.ethenotethan.Portal", category: "ToolbarIconTheme")

// The top-right chrome icons (Settings, Sessions, Cron, …) are their own
// appearance axis. They are icon-only and sit on the window background rather
// than in a form, so the button treatments in `ButtonTheme` — which assume a
// text label and a rectangular footprint — do not describe them. Everything
// here is geometry and color *roles*; the actual `Color` values come from the
// active palette in the view layer, so a treatment composes with every theme.

// MARK: - Treatment

/// The shape drawn behind a toolbar glyph, if any.
internal enum ToolbarIconBackdrop: Equatable, Sendable {
    case none
    case circle
    case roundedSquare(CGFloat)

    internal var isDrawn: Bool { self != .none }
}

/// Which color a glyph takes. Every treatment but `filled` draws the glyph in
/// the button's own tint; a filled disc *is* the tint, so its glyph has to read
/// against it instead.
internal enum ToolbarGlyphFill: Equatable, Sendable {
    case tint
    case onTint
}

/// One look for a toolbar icon. Also the collective theme: selecting a
/// treatment applies it to every button that has no override of its own.
internal enum ToolbarIconTreatment: String, CaseIterable, Codable, Sendable, Identifiable {
    case plain
    case soft
    case outlined
    case filled
    case glow

    internal var id: String { rawValue }

    internal var label: String {
        switch self {
        case .plain: return "Plain"
        case .soft: return "Soft"
        case .outlined: return "Outlined"
        case .filled: return "Filled"
        case .glow: return "Glow"
        }
    }

    internal var detail: String {
        switch self {
        case .plain: return "Bare glyphs, no backdrop"
        case .soft: return "Quiet rounded tiles"
        case .outlined: return "Ringed glyphs"
        case .filled: return "Solid discs"
        case .glow: return "Lit tiles with a halo"
        }
    }

    internal var backdrop: ToolbarIconBackdrop {
        switch self {
        case .plain: return .none
        case .soft, .glow: return .roundedSquare(7)
        case .outlined, .filled: return .circle
        }
    }

    /// Opacity of the backdrop fill.
    internal var fillOpacity: Double {
        switch self {
        case .plain, .outlined: return 0
        case .soft: return 1
        case .filled: return 1
        case .glow: return 0.22
        }
    }

    /// Whether the backdrop fill uses the button's tint rather than the palette
    /// surface. `soft` is deliberately colorless behind the glyph — that is what
    /// makes it the quiet one.
    internal var fillIsTinted: Bool {
        switch self {
        case .filled, .glow: return true
        case .plain, .soft, .outlined: return false
        }
    }

    internal var borderWidth: CGFloat {
        switch self {
        case .plain, .soft, .filled: return 0
        case .outlined: return 1
        case .glow: return 1.2
        }
    }

    internal var glyphFill: ToolbarGlyphFill {
        self == .filled ? .onTint : .tint
    }

    internal var glowRadius: CGFloat { self == .glow ? 7 : 0 }

    /// Space between the glyph and the edge of its backdrop. `plain` keeps a
    /// small hit-target inset without looking padded.
    internal var padding: CGFloat {
        backdrop.isDrawn ? 5 : 3
    }

    internal var pressedScale: CGFloat {
        self == .plain ? 0.9 : 0.94
    }

    /// The shipped look. An existing user's toolbar must not restyle itself.
    internal static let `default`: ToolbarIconTreatment = .plain

    internal init(storedValue: String?) {
        self = storedValue.flatMap(ToolbarIconTreatment.init(rawValue:)) ?? .default
    }
}

// MARK: - Tint role

/// A palette role rather than a `Color`, so a chosen tint keeps working when the
/// palette changes underneath it.
internal enum ToolbarIconTint: String, CaseIterable, Codable, Sendable, Identifiable {
    case theme
    case neutral
    case muted
    case success
    case warning
    case agent

    internal var id: String { rawValue }

    internal var label: String {
        switch self {
        case .theme: return "Theme accent"
        case .neutral: return "Text"
        case .muted: return "Muted"
        case .success: return "Green"
        case .warning: return "Amber"
        case .agent: return "Agent"
        }
    }

    /// The palette's text color, so the default is the toolbar as it looked
    /// before this setting existed — every treatment starts monochrome and color
    /// is something the user opts into, per button or across the row.
    internal static let `default`: ToolbarIconTint = .neutral

    internal init(storedValue: String?) {
        self = storedValue.flatMap(ToolbarIconTint.init(rawValue:)) ?? .default
    }
}

// MARK: - Slots

/// One addressable toolbar button. The raw value is the persisted key, so these
/// strings are storage and must not be renamed casually.
///
/// Not every slot is on screen at once — most are gated on what the connected
/// harness supports — but all of them are configurable, because a setting that
/// appears and disappears with the connection is worse than one that is
/// occasionally moot.
internal enum ToolbarIconSlot: String, CaseIterable, Codable, Sendable, Identifiable {
    case settings
    case sessions
    case cron
    case activity
    case skills
    case feed
    case learning
    case wiki
    case artifacts
    case workflows

    internal var id: String { rawValue }

    internal var label: String {
        switch self {
        case .settings: return "Settings"
        case .sessions: return "Sessions"
        case .cron: return "Cron"
        case .activity: return "Activity"
        case .skills: return "Skills"
        case .feed: return "Feed"
        case .learning: return "Learning"
        case .wiki: return "Wiki"
        case .artifacts: return "Artifacts"
        case .workflows: return "Workflows"
        }
    }

    /// The glyph the toolbar shows for this slot. `activity` swaps in a badged
    /// bell when the inbox is unread; this is the resting form, and the one the
    /// settings preview draws.
    internal var systemImage: String {
        switch self {
        case .settings: return "gearshape"
        case .sessions: return "square.grid.2x2"
        case .cron: return "clock.badge.checkmark"
        case .activity: return "bell"
        case .skills: return "sparkles"
        case .feed: return "newspaper"
        case .learning: return "books.vertical.fill"
        case .wiki: return "network"
        case .artifacts: return "internaldrive"
        case .workflows: return "point.3.connected.trianglepath.dotted"
        }
    }

    /// Hover tooltip. Names the DESTINATION in plain words — what opens when
    /// you click — not the icon: a first-time user shouldn't have to click a
    /// clock-with-checkmark to learn it means scheduled tasks. Applied by the
    /// `toolbarIcon` modifier so no call site can forget it.
    internal var helpText: String {
        switch self {
        case .settings: return "Settings"
        case .sessions: return "Live sessions"
        case .cron: return "Scheduled tasks"
        case .activity: return "Activity inbox"
        case .skills: return "Skills library"
        case .feed: return "News feed"
        case .learning: return "Learning — courses, quizzes, and flashcards"
        case .wiki: return "Wiki knowledge graph"
        case .artifacts: return "Living artifacts"
        case .workflows: return "Workflow runs"
        }
    }
}

// MARK: - Resolution

/// What one button actually draws, after the collective theme and any override
/// for that button have been folded together.
internal struct ToolbarIconAppearance: Equatable, Sendable {
    internal let treatment: ToolbarIconTreatment
    internal let tint: ToolbarIconTint
    /// True when this button deviates from the collective theme — the settings
    /// pane marks those so an override is never invisible.
    internal let isOverridden: Bool
}

/// Per-button deviations from the collective treatment.
///
/// Stored as raw strings rather than as decoded enums so one unreadable entry —
/// a value written by a newer build, say — costs only that button instead of
/// discarding every override the user has set.
internal struct ToolbarIconOverrides: Codable, Equatable, Sendable {
    private var treatments: [String: String]
    private var tints: [String: String]

    internal init() {
        treatments = [:]
        tints = [:]
    }

    // MARK: Reading

    internal func treatment(for slot: ToolbarIconSlot) -> ToolbarIconTreatment? {
        treatments[slot.rawValue].flatMap(ToolbarIconTreatment.init(rawValue:))
    }

    internal func tint(for slot: ToolbarIconSlot) -> ToolbarIconTint? {
        tints[slot.rawValue].flatMap(ToolbarIconTint.init(rawValue:))
    }

    internal func hasOverride(for slot: ToolbarIconSlot) -> Bool {
        treatment(for: slot) != nil || tint(for: slot) != nil
    }

    internal var isEmpty: Bool {
        ToolbarIconSlot.allCases.allSatisfy { !hasOverride(for: $0) }
    }

    /// Folds the collective theme and this slot's override into one answer.
    internal func resolve(
        _ slot: ToolbarIconSlot,
        treatment collectiveTreatment: ToolbarIconTreatment,
        tint collectiveTint: ToolbarIconTint
    ) -> ToolbarIconAppearance {
        ToolbarIconAppearance(
            treatment: treatment(for: slot) ?? collectiveTreatment,
            tint: tint(for: slot) ?? collectiveTint,
            isOverridden: hasOverride(for: slot)
        )
    }

    // MARK: Writing

    /// `nil` clears the override, returning the slot to the collective theme.
    internal mutating func setTreatment(_ treatment: ToolbarIconTreatment?, for slot: ToolbarIconSlot) {
        treatments[slot.rawValue] = treatment?.rawValue
    }

    internal mutating func setTint(_ tint: ToolbarIconTint?, for slot: ToolbarIconSlot) {
        tints[slot.rawValue] = tint?.rawValue
    }

    internal mutating func reset(_ slot: ToolbarIconSlot) {
        treatments[slot.rawValue] = nil
        tints[slot.rawValue] = nil
    }

    internal mutating func resetAll() {
        treatments = [:]
        tints = [:]
    }

    // MARK: Storage

    /// Decoding never throws: a corrupt blob means "no overrides", which is a
    /// usable toolbar, where a thrown error at launch is not. The error is
    /// logged rather than dropped, because silently reverting to the theme is
    /// exactly the symptom a user would report as "my settings keep resetting".
    internal static func decode(from data: Data?) -> ToolbarIconOverrides {
        guard let data else { return ToolbarIconOverrides() }
        do {
            return try JSONDecoder().decode(ToolbarIconOverrides.self, from: data)
        } catch {
            toolbarIconLog.error("override decode failed, falling back to the theme: \(error.localizedDescription)")
            return ToolbarIconOverrides()
        }
    }

    /// `nil` on failure, which the caller writes straight to `UserDefaults` —
    /// storing nothing leaves the last good blob in place rather than replacing
    /// it with something unreadable.
    internal func encoded() -> Data? {
        do {
            return try JSONEncoder().encode(self)
        } catch {
            toolbarIconLog.error("override encode failed, keeping the stored blob: \(error.localizedDescription)")
            return nil
        }
    }
}
