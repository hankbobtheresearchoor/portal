import CoreGraphics
import Testing
@testable import Portal

@Suite("Chat Layout Math")
internal struct ChatLayoutMathTests {

    // MARK: - Input-field height

    @Test("Sub-point height deltas are absorbed, real line changes adopted")
    internal func inputHeightTolerance() {
        // First measurement is always adopted.
        #expect(ChatLayoutMath.shouldAdoptInputHeight(current: nil, proposed: 30))
        // Relayout noise of the same text: absorbed.
        #expect(!ChatLayoutMath.shouldAdoptInputHeight(current: 30, proposed: 30.4))
        #expect(!ChatLayoutMath.shouldAdoptInputHeight(current: 30.4, proposed: 30))
        // A real line change (~18pt): adopted.
        #expect(ChatLayoutMath.shouldAdoptInputHeight(current: 30, proposed: 48))
        #expect(ChatLayoutMath.shouldAdoptInputHeight(current: 48, proposed: 30))
    }

    @Test("Clamped input height is stable for identical inputs")
    internal func clampedInputHeightStability() {
        let lineHeight: CGFloat = 18.1
        let a = ChatLayoutMath.clampedInputHeight(reported: 54.3, lineHeight: lineHeight, maxLines: 8)
        let b = ChatLayoutMath.clampedInputHeight(reported: 54.3, lineHeight: lineHeight, maxLines: 8)
        #expect(a == b)
        #expect(a.truncatingRemainder(dividingBy: 1) == 0)
    }

    @Test("Clamped input height respects the one-line floor and maxLines cap")
    internal func clampedInputHeightBounds() {
        let lineHeight: CGFloat = 18
        // No measurement yet → one line + padding.
        #expect(ChatLayoutMath.clampedInputHeight(reported: nil, lineHeight: lineHeight, maxLines: 8) == 30)
        // Below the floor → clamped up.
        #expect(ChatLayoutMath.clampedInputHeight(reported: 5, lineHeight: lineHeight, maxLines: 8) == 30)
        // Above the cap → clamped to maxLines.
        #expect(ChatLayoutMath.clampedInputHeight(reported: 999, lineHeight: lineHeight, maxLines: 8) == 156)
    }

    @Test("Width fallback only updates on a meaningful change")
    internal func widthChangeGate() {
        #expect(ChatLayoutMath.widthMeaningfullyChanged(current: nil, proposed: 300))
        #expect(!ChatLayoutMath.widthMeaningfullyChanged(current: 300, proposed: 300.3))
        #expect(!ChatLayoutMath.widthMeaningfullyChanged(current: 300.3, proposed: 300))
        #expect(ChatLayoutMath.widthMeaningfullyChanged(current: 300, proposed: 301))
        #expect(ChatLayoutMath.widthMeaningfullyChanged(current: 300, proposed: 250))
    }
}
