import Testing
import Foundation
import CoreGraphics
@testable import Portal

/// The toolbar treatment is a third appearance axis, and unlike the palette and
/// the button treatment it has a per-button override layer on top of it. These
/// tests pin the parts that would be invisible until they were wrong for
/// everyone at once: a treatment that draws nothing, an override that silently
/// wins or silently loses, and a stored blob that refuses to load.
@Suite("Toolbar icon themes")
internal struct ToolbarIconThemeTests {

    // MARK: - Every treatment is visible

    @Test("every treatment draws a glyph that can be seen")
    internal func everyTreatmentIsVisible() {
        // A backdrop is optional — a bare glyph is a legitimate look. What is
        // not legitimate is a *drawn* backdrop with no fill and no border, which
        // is an empty rectangle that eats clicks.
        for treatment in ToolbarIconTreatment.allCases where treatment.backdrop.isDrawn {
            let hasFill = treatment.fillOpacity > 0
            let hasEdge = treatment.borderWidth > 0
            #expect(hasFill || hasEdge, "\(treatment.rawValue) draws an empty backdrop")
        }
    }

    @Test("a filled backdrop does not swallow its own glyph")
    internal func filledGlyphReadsAgainstItsBackdrop() {
        // The one treatment whose backdrop is opaque and tinted. Drawing the
        // glyph in that same tint would make the button a blank disc.
        #expect(ToolbarIconTreatment.filled.fillOpacity == 1)
        #expect(ToolbarIconTreatment.filled.fillIsTinted)
        #expect(ToolbarIconTreatment.filled.glyphFill == .onTint)

        for treatment in ToolbarIconTreatment.allCases where treatment != .filled {
            #expect(treatment.glyphFill == .tint, "\(treatment.rawValue) hides its glyph")
        }
    }

    @Test("a tinted opaque fill is the only case needing an inverted glyph")
    internal func onlyOpaqueTintedFillsInvert() {
        for treatment in ToolbarIconTreatment.allCases where treatment.glyphFill == .onTint {
            // The invariant behind the previous test, stated from the other
            // side: if a future treatment becomes opaque and tinted, it has to
            // invert too, and this fails until it does.
            #expect(treatment.fillIsTinted)
            #expect(treatment.fillOpacity == 1)
        }
    }

    @Test("every treatment gives press feedback")
    internal func everyTreatmentRespondsToPress() {
        for treatment in ToolbarIconTreatment.allCases {
            // A custom style replaces SwiftUI's own press highlight, so without
            // a substitute the icon looks inert when clicked.
            #expect(treatment.pressedScale < 1)
            #expect(treatment.pressedScale > 0.85)
        }
    }

    @Test("fill opacities stay in range")
    internal func fillOpacitiesAreValid() {
        for treatment in ToolbarIconTreatment.allCases {
            #expect(treatment.fillOpacity >= 0)
            #expect(treatment.fillOpacity <= 1)
        }
    }

    @Test("a drawn backdrop gets more padding than a bare glyph")
    internal func backdropsArePadded() {
        for treatment in ToolbarIconTreatment.allCases {
            #expect(treatment.padding > 0)
            if treatment.backdrop.isDrawn {
                #expect(treatment.padding > ToolbarIconTreatment.plain.padding,
                        "\(treatment.rawValue) crowds its glyph against its own edge")
            }
        }
    }

    @Test("only glow draws a halo")
    internal func onlyGlowGlows() {
        #expect(ToolbarIconTreatment.glow.glowRadius > 0)
        for treatment in ToolbarIconTreatment.allCases where treatment != .glow {
            #expect(treatment.glowRadius == 0)
        }
    }

    // MARK: - plain is the hand-off

    @Test("plain draws nothing of its own, so SwiftUI's look is untouched")
    internal func plainIsTheHandOff() {
        // `.toolbarIcon(_:)` branches on plain-and-neutral to reach
        // `.borderless`, which keeps the system's hover and press behavior.
        // Geometry here would be dead values a later refactor could start
        // honoring by accident.
        #expect(ToolbarIconTreatment.plain.backdrop == .none)
        #expect(ToolbarIconTreatment.plain.fillOpacity == 0)
        #expect(ToolbarIconTreatment.plain.borderWidth == 0)
        #expect(ToolbarIconTreatment.plain.glowRadius == 0)
    }

    @Test("the shipped defaults are the toolbar as it was")
    internal func defaultsAreTheStatusQuo() {
        // Every icon in the chrome changes at once here. Defaulting to anything
        // else restyles the toolbar for users who never asked.
        #expect(ToolbarIconTreatment(storedValue: nil) == .plain)
        #expect(ToolbarIconTint(storedValue: nil) == .neutral)
        #expect(ToolbarIconTreatment.default == .plain)
        #expect(ToolbarIconTint.default == .neutral)
    }

    // MARK: - Distinctness

    @Test("the treatments are visually distinct from one another")
    internal func treatmentsAreDistinct() {
        // Two identical treatments are two cards in the grid that do the same
        // thing, which reads as a broken setting.
        let signatures = ToolbarIconTreatment.allCases.map { treatment in
            [
                "\(treatment.backdrop)",
                "\(treatment.fillOpacity)",
                "\(treatment.fillIsTinted)",
                "\(treatment.borderWidth)",
                "\(treatment.glowRadius)",
                "\(treatment.glyphFill)",
            ].joined(separator: "|")
        }
        #expect(Set(signatures).count == signatures.count)
    }

    @Test("every treatment and tint has a distinct label")
    internal func labelsAreDistinct() {
        let treatmentLabels = ToolbarIconTreatment.allCases.map(\.label)
        #expect(Set(treatmentLabels).count == treatmentLabels.count)
        for treatment in ToolbarIconTreatment.allCases {
            #expect(!treatment.label.isEmpty)
            #expect(!treatment.detail.isEmpty)
        }

        let tintLabels = ToolbarIconTint.allCases.map(\.label)
        #expect(Set(tintLabels).count == tintLabels.count)
        for tint in ToolbarIconTint.allCases {
            #expect(!tint.label.isEmpty)
        }
    }

    // MARK: - Slots

    @Test("every slot has a distinct key, label, and glyph")
    internal func slotsAreDistinct() {
        let slots = ToolbarIconSlot.allCases
        // `id` backs `ForEach` in the settings list and `rawValue` is the
        // persisted key; a collision in either drops or aliases a row.
        #expect(Set(slots.map(\.id)).count == slots.count)
        #expect(Set(slots.map(\.rawValue)).count == slots.count)
        #expect(Set(slots.map(\.label)).count == slots.count)
        // Two slots sharing a glyph makes the settings list ambiguous — the row
        // shows the icon, and the icon is how the user finds the button they
        // mean.
        #expect(Set(slots.map(\.systemImage)).count == slots.count)
        for slot in slots {
            #expect(slot.id == slot.rawValue)
            #expect(!slot.label.isEmpty)
            #expect(!slot.systemImage.isEmpty)
        }
    }

    @Test("every toolbar button in ContentView has a slot")
    internal func everyToolbarButtonIsAddressable() {
        // A button with no slot is one the settings pane cannot reach, and the
        // symptom is a single icon that stays plain while the row around it
        // restyles. Ten is the count in `macOverlayIcons`.
        #expect(ToolbarIconSlot.allCases.count == 10)
    }

    // MARK: - Overrides

    @Test("no overrides means every slot follows the collective theme")
    internal func emptyOverridesFollowTheTheme() {
        let overrides = ToolbarIconOverrides()
        #expect(overrides.isEmpty)
        for slot in ToolbarIconSlot.allCases {
            let resolved = overrides.resolve(slot, treatment: .glow, tint: .warning)
            #expect(resolved.treatment == .glow)
            #expect(resolved.tint == .warning)
            #expect(!resolved.isOverridden)
        }
    }

    @Test("an override wins over the collective theme, for that slot only")
    internal func anOverrideIsScopedToItsSlot() {
        var overrides = ToolbarIconOverrides()
        overrides.setTreatment(.filled, for: .cron)

        let cron = overrides.resolve(.cron, treatment: .plain, tint: .neutral)
        #expect(cron.treatment == .filled)
        #expect(cron.isOverridden)

        // The failure this guards: a dictionary keyed by something coarser than
        // the slot, so setting Cron restyles the whole row.
        let sessions = overrides.resolve(.sessions, treatment: .plain, tint: .neutral)
        #expect(sessions.treatment == .plain)
        #expect(!sessions.isOverridden)
    }

    @Test("a treatment override and a tint override are independent")
    internal func treatmentAndTintOverrideSeparately() {
        var overrides = ToolbarIconOverrides()
        // Overriding only the color must leave the shape following the theme —
        // otherwise picking "amber for Cron" also freezes Cron's shape, and
        // clicking through the treatment grid appears to skip it.
        overrides.setTint(.warning, for: .cron)
        let resolved = overrides.resolve(.cron, treatment: .outlined, tint: .neutral)
        #expect(resolved.treatment == .outlined)
        #expect(resolved.tint == .warning)
        #expect(resolved.isOverridden)
    }

    @Test("clearing one field leaves the other override in place")
    internal func clearingOneFieldKeepsTheOther() {
        var overrides = ToolbarIconOverrides()
        overrides.setTreatment(.filled, for: .wiki)
        overrides.setTint(.success, for: .wiki)

        overrides.setTreatment(nil, for: .wiki)
        #expect(overrides.treatment(for: .wiki) == nil)
        #expect(overrides.tint(for: .wiki) == .success)
        // Still overridden, so the row keeps saying so.
        #expect(overrides.hasOverride(for: .wiki))
        #expect(!overrides.isEmpty)
    }

    @Test("resetting a slot returns it to the theme")
    internal func resetClearsBothFields() {
        var overrides = ToolbarIconOverrides()
        overrides.setTreatment(.glow, for: .skills)
        overrides.setTint(.agent, for: .skills)
        overrides.reset(.skills)

        #expect(!overrides.hasOverride(for: .skills))
        #expect(overrides.isEmpty)
        let resolved = overrides.resolve(.skills, treatment: .soft, tint: .neutral)
        #expect(resolved.treatment == .soft)
        #expect(!resolved.isOverridden)
    }

    @Test("resetting everything clears every slot")
    internal func resetAllClearsEverySlot() {
        var overrides = ToolbarIconOverrides()
        for slot in ToolbarIconSlot.allCases {
            overrides.setTreatment(.filled, for: slot)
            overrides.setTint(.warning, for: slot)
        }
        #expect(!overrides.isEmpty)

        overrides.resetAll()
        #expect(overrides.isEmpty)
        for slot in ToolbarIconSlot.allCases {
            #expect(!overrides.hasOverride(for: slot))
        }
    }

    @Test("isEmpty is what drives the Reset all button")
    internal func isEmptyTracksAnySingleOverride() {
        var overrides = ToolbarIconOverrides()
        #expect(overrides.isEmpty)
        // One tint on one slot has to be enough: otherwise the button that
        // undoes it is hidden, and the override is unreachable.
        overrides.setTint(.muted, for: .artifacts)
        #expect(!overrides.isEmpty)
    }

    // MARK: - Storage

    @Test("overrides survive a round trip through their stored blob")
    internal func overridesRoundTrip() throws {
        var overrides = ToolbarIconOverrides()
        overrides.setTreatment(.outlined, for: .cron)
        overrides.setTint(.warning, for: .cron)
        overrides.setTint(.success, for: .wiki)

        let data = try #require(overrides.encoded())
        let restored = ToolbarIconOverrides.decode(from: data)
        #expect(restored == overrides)
        #expect(restored.treatment(for: .cron) == .outlined)
        #expect(restored.tint(for: .cron) == .warning)
        #expect(restored.treatment(for: .wiki) == nil)
        #expect(restored.tint(for: .wiki) == .success)
    }

    @Test("a missing or corrupt blob decodes to no overrides, not a crash")
    internal func corruptStorageIsSurvivable() {
        // Reached on first launch (nil) and after a hand-edited defaults plist
        // or a half-written value. Throwing here would be at app launch, before
        // any view exists.
        #expect(ToolbarIconOverrides.decode(from: nil).isEmpty)
        #expect(ToolbarIconOverrides.decode(from: Data()).isEmpty)
        #expect(ToolbarIconOverrides.decode(from: Data("not json".utf8)).isEmpty)
    }

    @Test("one unreadable entry costs only its own button")
    internal func anUnknownValueDoesNotDiscardTheRest() {
        // Written by a newer build that has a treatment this one does not know.
        // Storing decoded enums would fail the whole blob and silently reset
        // every override the user set.
        let json = """
        {"treatments":{"cron":"brutalist","wiki":"filled"},"tints":{"cron":"warning"}}
        """
        let overrides = ToolbarIconOverrides.decode(from: Data(json.utf8))
        // Cron's shape is unreadable here and falls back to the theme, but its
        // color — which this build does understand — survives.
        #expect(overrides.treatment(for: .cron) == nil)
        #expect(overrides.tint(for: .cron) == .warning)
        // And the slot that had nothing to do with it is untouched.
        #expect(overrides.treatment(for: .wiki) == .filled)
        #expect(!overrides.isEmpty)
    }

    @Test("every treatment and tint round-trips through its raw value")
    internal func rawValuesRoundTrip() {
        for treatment in ToolbarIconTreatment.allCases {
            #expect(ToolbarIconTreatment(storedValue: treatment.rawValue) == treatment)
            #expect(treatment.id == treatment.rawValue)
        }
        for tint in ToolbarIconTint.allCases {
            #expect(ToolbarIconTint(storedValue: tint.rawValue) == tint)
            #expect(tint.id == tint.rawValue)
        }
        for slot in ToolbarIconSlot.allCases {
            #expect(ToolbarIconSlot(rawValue: slot.rawValue) == slot)
        }
    }

    @Test("an unknown stored value falls back to the shipped default")
    internal func unknownValuesDowngrade() {
        #expect(ToolbarIconTreatment(storedValue: "brutalist") == .plain)
        #expect(ToolbarIconTreatment(storedValue: "") == .plain)
        #expect(ToolbarIconTint(storedValue: "chartreuse") == .neutral)
        #expect(ToolbarIconTint(storedValue: "") == .neutral)
    }

    // MARK: - Backdrop geometry

    @Test("a rounded backdrop's radius is positive and not a circle")
    internal func roundedBackdropGeometry() {
        guard case .roundedSquare(let radius) = ToolbarIconTreatment.soft.backdrop else {
            Issue.record("soft should use a rounded square")
            return
        }
        #expect(radius > 0)
        // Half of the 26pt footprint would be a circle; `outlined` and `filled`
        // are the circles, and a third one collapses the distinction.
        #expect(radius < 13)
    }

    @Test("backdrop shapes are distinguishable")
    internal func backdropsAreDistinguishable() {
        #expect(ToolbarIconBackdrop.none.isDrawn == false)
        #expect(ToolbarIconBackdrop.circle.isDrawn)
        #expect(ToolbarIconBackdrop.roundedSquare(7).isDrawn)
        #expect(ToolbarIconBackdrop.circle != ToolbarIconBackdrop.roundedSquare(7))
        #expect(ToolbarIconBackdrop.roundedSquare(7) != ToolbarIconBackdrop.roundedSquare(9))
    }

    /// Tester feedback (issue #257): icon-only buttons were guessing games.
    /// The tooltip is applied centrally by the `toolbarIcon` modifier from
    /// `helpText`, so the guarantee to keep is that every slot HAS one and it
    /// says something beyond restating the icon.
    @Test("every toolbar slot carries a non-empty hover tooltip")
    internal func everySlotHasHelpText() {
        for slot in ToolbarIconSlot.allCases {
            #expect(!slot.helpText.trimmingCharacters(in: .whitespaces).isEmpty,
                    "\(slot.rawValue) has no tooltip")
        }
    }

    @Test("cron's tooltip names scheduled tasks, not the clock glyph")
    internal func cronTooltipNamesTheDestination() {
        // The complaint verbatim: "I don't like having to guess that 🕘✅
        // means scheduled tasks". The tooltip must answer that guess.
        #expect(ToolbarIconSlot.cron.helpText.localizedCaseInsensitiveContains("scheduled"))
    }
}
