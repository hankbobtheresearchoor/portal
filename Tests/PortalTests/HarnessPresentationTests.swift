import Testing
import Foundation
@testable import Portal

@Suite("Harness Presentation")
internal struct HarnessPresentationTests {

    @Test("hermes presentation is persona-driven — no fixed harness identity")
    internal func hermesHasNoHarnessPersona() {
        #expect(BackendCapabilities.hermes.harnessPersona == nil)
    }

    @Test("centaur presents as Centaur, never as a Hermes persona")
    internal func centaurHasFixedIdentity() {
        let persona = BackendCapabilities.centaur.harnessPersona
        #expect(persona == .centaurPersona)
        #expect(persona?.name == "Centaur")
        #expect(persona?.id == "centaur")
    }

    @Test("centaur harness identity matches its BackendKind icon")
    internal func centaurIconsAgree() {
        // The New Session menu (BackendKind) and the chat chrome (Persona)
        // must show the same glyph or the session looks like it changed
        // platforms between create and first message.
        #expect(Persona.centaurPersona.symbolName == BackendKind.centaur.iconName)
    }

    @Test("gateway service surface is hermes-only")
    internal func gatewayServicesGating() {
        #expect(BackendCapabilities.hermes.supportsGatewayServices)
        #expect(!BackendCapabilities.centaur.supportsGatewayServices)
    }

    @Test("response styles require ephemeral prompt support")
    internal func responseStyleGating() {
        #expect(BackendCapabilities.hermes.supportsResponseStyles)
        // Centaur's setEphemeralPrompt is a silent no-op — offering the
        // style menu there would be a lie.
        #expect(!BackendCapabilities.centaur.supportsResponseStyles)
    }

    @Test("centaur client advertises the centaur capability set")
    @MainActor
    internal func centaurClientCapabilities() {
        let client = CentaurClient(
            baseURL: URL(string: "https://centaur.example.com")!,
            apiKey: "k"
        )
        #expect(client.capabilities.harnessPersona == .centaurPersona)
        #expect(!client.capabilities.supportsGatewayServices)
    }

    @Test("slash suggestions stay dark on skill-less backends")
    @MainActor
    internal func slashSuggestionsGated() {
        let vm = ChatViewModel()
        let client = CentaurClient(
            baseURL: URL(string: "https://centaur.example.com")!,
            apiKey: "k"
        )
        vm.setGatewayClient(client)
        vm.inputText = "/"
        vm.updateSlashSuggestions()
        #expect(vm.slashMode == false)
        #expect(vm.slashSuggestions.isEmpty)
    }
}
