import Testing
import Foundation
@testable import Portal

@Suite("Skill Model")
struct SkillInfoTests {
    @Test("fromCommandEntry creates skill from slash-command dict")
    func fromCommandEntry() {
        let dict: [String: AnyCodable] = [
            "name": AnyCodable("Code Review"),
            "description": AnyCodable("Review code for issues"),
            "skill_md_path": AnyCodable("/home/.hermes/skills/code-review/SKILL.md"),
            "skill_dir": AnyCodable("/home/.hermes/skills/code-review"),
        ]
        let skill = SkillInfo.fromCommandEntry(key: "/code-review", dict: dict)
        #expect(skill.name == "Code Review")
        #expect(skill.id == skill.name)
        #expect(skill.id == "Code Review")
        #expect(skill.slashCommand == "/code-review")
        #expect(skill.description == "Review code for issues")
        #expect(skill.source == "local")
        #expect(skill.skillMdPath == "/home/.hermes/skills/code-review/SKILL.md")
    }

    @Test("fromInspectDict parses inspect response with all fields")
    func fromInspectDict() {
        let dict: [String: AnyCodable] = [
            "name": AnyCodable("skill-creator"),
            "description": AnyCodable("Create new skills from experience"),
            "source": AnyCodable("official"),
            "identifier": AnyCodable("openai/skills/skill-creator"),
            "tags": .array([AnyCodable("coding"), AnyCodable("meta")]),
            "skill_md_preview": AnyCodable("# Skill Creator\nCreates skills..."),
        ]
        let skill = SkillInfo.fromInspectDict(dict)
        #expect(skill?.name == "skill-creator")
        #expect(skill?.source == "official")
        #expect(skill?.identifier == "openai/skills/skill-creator")
        #expect(skill?.tags == ["coding", "meta"])
        #expect(skill?.skillMdPreview == "# Skill Creator\nCreates skills...")
    }

    @Test("fromInspectDict returns nil when name is empty")
    func fromInspectDictEmptyName() {
        let dict: [String: AnyCodable] = [
            "name": AnyCodable(""),
            "description": AnyCodable("no name"),
        ]
        #expect(SkillInfo.fromInspectDict(dict) == nil)
    }

    @Test("fromInspectDict handles missing optional fields")
    func fromInspectDictMinimal() {
        let dict: [String: AnyCodable] = [
            "name": AnyCodable("minimal-skill"),
        ]
        let skill = SkillInfo.fromInspectDict(dict)
        #expect(skill?.name == "minimal-skill")
        #expect(skill?.description.isEmpty == true)
        #expect(skill?.source == "local")
        #expect(skill?.tags.isEmpty == true)
        #expect(skill?.skillMdPreview == nil)
    }

    @Test("slashCommand is derived from name for inspect results")
    func slashCommandFromInspect() {
        let dict: [String: AnyCodable] = [
            "name": AnyCodable("Code Review"),
        ]
        let skill = SkillInfo.fromInspectDict(dict)
        #expect(skill?.slashCommand == "/code-review")
    }

    @Test("SkillInfo equality compares all fields")
    func equality() {
        let base = SkillInfo(name: "A", description: "desc", category: "general",
                             source: "local", identifier: nil, tags: [],
                             skillMdPath: nil, skillDir: nil,
                             skillMdPreview: nil, slashCommand: "/a")
        let same = SkillInfo(name: "A", description: "desc", category: "general",
                             source: "local", identifier: nil, tags: [],
                             skillMdPath: nil, skillDir: nil,
                             skillMdPreview: nil, slashCommand: "/a")
        let diff = SkillInfo(name: "C", description: "desc", category: "general",
                             source: "local", identifier: nil, tags: [],
                             skillMdPath: nil, skillDir: nil,
                             skillMdPreview: nil, slashCommand: "/c")
        #expect(base == same)
        #expect(base != diff)
    }
}

@Suite("Skill Search Result")
struct SkillSearchResultTests {
    @Test("parses search result with name and description")
    func parseSearchResult() {
        let dict: [String: AnyCodable] = [
            "name": AnyCodable("web-search"),
            "description": AnyCodable("Search the web for information"),
        ]
        let result = SkillSearchResult.from(dict)
        #expect(result?.name == "web-search")
        #expect(result?.description == "Search the web for information")
    }

    @Test("returns nil when name is empty")
    func parseEmptyName() {
        let dict: [String: AnyCodable] = [
            "name": AnyCodable(""),
        ]
        #expect(SkillSearchResult.from(dict) == nil)
    }

    @Test("id equals name")
    func idEqualsName() {
        let dict: [String: AnyCodable] = [
            "name": AnyCodable("test-skill"),
            "description": AnyCodable("desc"),
        ]
        let result = SkillSearchResult.from(dict)
        #expect(result?.id == "test-skill")
    }
}

@Suite("Skills View Model")
@MainActor
struct SkillsViewModelTests {

    init() {
        NotificationService.isTestEnvironment = true
    }

    @Test("initial state is empty")
    func initialState() {
        let vm = SkillsViewModel()
        #expect(vm.skills.isEmpty)
        #expect(vm.categories.isEmpty)
        #expect(vm.isLoading == false)
        #expect(vm.searchResults.isEmpty)
        #expect(vm.isSearching == false)
        #expect(vm.totalSkills == 0)
        #expect(vm.categoryCount == 0)
    }

    @Test("installStatus tracks state")
    func installStatus() {
        let vm = SkillsViewModel()
        #expect(vm.installStatus["my-skill"] == nil)
        vm.installStatus["my-skill"] = "installing"
        #expect(vm.installStatus["my-skill"] == "installing")
        vm.installStatus["my-skill"] = "installed"
        #expect(vm.installStatus["my-skill"] == "installed")
    }
}
