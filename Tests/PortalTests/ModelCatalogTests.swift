import Testing
import Foundation
@testable import Portal

@Suite("Model Catalog")
internal struct ModelCatalogTests {

    /// Decode helper: JSON string → AnyCodable dictionary, the same shape a
    /// JSON-RPC result reaches ModelCatalog.from as.
    private func result(_ json: String) throws -> [String: AnyCodable] {
        try JSONDecoder().decode([String: AnyCodable].self, from: Data(json.utf8))
    }

    @Test("Decodes the model.options payload shape")
    internal func decodesPayload() throws {
        let payload = try result("""
        {
          "providers": [
            {"slug": "nous", "name": "Nous", "is_current": true,
             "models": ["nousresearch/hermes-4-405b", "nousresearch/hermes-4-70b"],
             "total_models": 2, "authenticated": true},
            {"slug": "openrouter", "name": "OpenRouter", "is_current": false,
             "models": ["minimax/minimax-m2.5"], "total_models": 1, "authenticated": true},
            {"slug": "xai", "name": "xAI", "is_current": false,
             "models": [], "total_models": 0, "authenticated": false,
             "warning": "set XAI_API_KEY"}
          ],
          "model": "nousresearch/hermes-4-405b",
          "provider": "nous"
        }
        """)
        let catalog = ModelCatalog.from(payload)
        #expect(catalog != nil)
        #expect(catalog?.providers.count == 3)
        #expect(catalog?.currentModel == "nousresearch/hermes-4-405b")
        #expect(catalog?.currentProvider == "nous")
        // Unauthenticated/empty providers are excluded from the pickable set.
        #expect(catalog?.selectableProviders.map(\.slug) == ["nous", "openrouter"])
        #expect(catalog?.allModelIDs.contains("minimax/minimax-m2.5") == true)
    }

    @Test("Rows without the picker_hints authenticated flag count as authenticated")
    internal func missingAuthFlagDefaultsTrue() throws {
        let payload = try result("""
        {"providers": [{"slug": "nous", "name": "Nous",
          "models": ["nousresearch/hermes-4-70b"]}], "model": "", "provider": ""}
        """)
        let catalog = ModelCatalog.from(payload)
        #expect(catalog?.selectableProviders.count == 1)
    }

    @Test("Empty or malformed payloads return nil (static catalog fallback)")
    internal func malformedReturnsNil() throws {
        #expect(ModelCatalog.from(try result("{\"model\": \"x\"}")) == nil)
        #expect(ModelCatalog.from(try result("{\"providers\": []}")) == nil)
        // A row without a slug is dropped; all dropped → nil.
        #expect(ModelCatalog.from(try result("{\"providers\": [{\"name\": \"NoSlug\"}]}")) == nil)
    }

    @Test("Switch outcome decodes confirmation gates and warnings")
    internal func switchOutcome() throws {
        let gated = ModelSwitchOutcome.from(try result("""
        {"key": "model", "value": "openai/o3-pro", "warning": "",
         "confirm_required": true, "confirm_message": "o3-pro is $120/Mtok. Continue?"}
        """))
        #expect(gated.confirmRequired)
        #expect(gated.confirmMessage.contains("$120"))

        let accepted = ModelSwitchOutcome.from(try result("""
        {"key": "model", "value": "deepseek/deepseek-v4-pro", "warning": "pricing unknown",
         "confirm_required": false, "confirm_message": ""}
        """))
        #expect(!accepted.confirmRequired)
        #expect(accepted.value == "deepseek/deepseek-v4-pro")
        #expect(accepted.warning == "pricing unknown")

        // Absent result (old gateway shape) degrades to a plain acceptance.
        let bare = ModelSwitchOutcome.from(nil)
        #expect(!bare.confirmRequired)
    }

    @Test("Provider id matches its slug")
    internal func providerIDIsSlug() {
        let provider = ModelCatalog.Provider(
            slug: "my-provider", name: "My Provider",
            models: ["model-a", "model-b"],
            authenticated: true, isCurrent: false
        )
        #expect(provider.id == "my-provider")
    }

    @Test("ModelSwitchConfirmation id matches its model string")
    internal func confirmationIDIsModel() {
        let confirmation = ModelSwitchConfirmation(
            model: "nousresearch/hermes-4-70b",
            message: "This model costs $5/Mtok. Continue?",
            provider: "nous"
        )
        #expect(confirmation.id == "nousresearch/hermes-4-70b")
    }

    @Test("displayName delegates to AgentModel")
    internal func displayNameDelegates() {
        let name = ModelCatalog.displayName(for: "nousresearch/hermes-4-405b")
        #expect(name == "Hermes 4 405B")
    }
}
