#if os(macOS)
import Foundation
import Testing
@testable import Portal

/// The gate deciding whether an immersive fullscreen presentation dispatches
/// backend intents. Wrong in one direction it injects a bridge with nothing to
/// resolve; wrong in the other it silently kills a live world's bindings —
/// which is the exact bug this context was introduced to fix.
@Suite("Artifact Fullscreen Intent Context")
internal struct ArtifactFullscreenIntentContextTests {

    private var intentActions: [ArtifactAction] {
        ArtifactAction.parse([
            ["type": "intent", "id": "talk-to-npc", "label": "Talk", "intent": "world.npc.talk"]
        ])
    }

    @Test("a live html artifact with a declared intent gets a context")
    internal func makesContextForLiveHTMLWorld() throws {
        let context = try #require(ArtifactFullscreenIntentContext.make(
            kind: "html",
            supportsArtifactActions: true,
            artifactID: "world-1",
            actions: intentActions
        ))
        #expect(context.artifactID == "world-1")
        #expect(context.actions.count == 1)
    }

    /// A model3d spec has no authoring surface to place a binding on — the
    /// host generates its HTML from a fixed template.
    @Test("model3d never gets a context, even with declared intents")
    internal func excludesModel3D() {
        #expect(ArtifactFullscreenIntentContext.make(
            kind: "model3d",
            supportsArtifactActions: true,
            artifactID: "spin",
            actions: intentActions
        ) == nil)
    }

    @Test("a gateway without artifact.action.invoke gets no context")
    internal func requiresCapability() {
        #expect(ArtifactFullscreenIntentContext.make(
            kind: "html",
            supportsArtifactActions: false,
            artifactID: "world-1",
            actions: intentActions
        ) == nil)
    }

    @Test("no declared intents means no bridge — local actions don't count")
    internal func requiresAtLeastOneIntent() {
        let localOnly = ArtifactAction.parse([
            ["type": "toggle", "field": "selected"],
            ["type": "delete"]
        ])
        #expect(ArtifactFullscreenIntentContext.make(
            kind: "html",
            supportsArtifactActions: true,
            artifactID: "world-1",
            actions: localOnly
        ) == nil)
        #expect(ArtifactFullscreenIntentContext.make(
            kind: "html",
            supportsArtifactActions: true,
            artifactID: "world-1",
            actions: []
        ) == nil)
    }

    /// One intent among local actions is enough — worlds commonly mix both.
    @Test("a mixed manifest with one intent still qualifies")
    internal func mixedManifestQualifies() {
        let mixed = ArtifactAction.parse([
            ["type": "toggle", "field": "selected"],
            ["type": "intent", "id": "open-door", "label": "Open", "intent": "world.door.open"]
        ])
        #expect(ArtifactFullscreenIntentContext.make(
            kind: "html",
            supportsArtifactActions: true,
            artifactID: "world-1",
            actions: mixed
        ) != nil)
    }
}
#endif
