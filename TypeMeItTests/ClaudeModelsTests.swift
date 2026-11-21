import Foundation
import Testing
@testable import TypeMeIt

struct ClaudeModelsTests {
    private func model(value: String, displayName: String, resolvedModel: String?) -> ClaudeModels.Model {
        ClaudeModels.Model(value: value, displayName: displayName, description: "", supportsAutoMode: true, resolvedModel: resolvedModel)
    }

    @Test func labelsNameTheFamilyAndVersion() {
        #expect(model(value: "opus[1m]", displayName: "Opus (1M context)", resolvedModel: "claude-opus-5-5[1m]").label == "opus 5.5")
        #expect(model(value: "claude-fable-5-2[1m]", displayName: "Fable", resolvedModel: "claude-fable-5-2[1m]").label == "fable 5.2")
        #expect(model(value: "sonnet", displayName: "Sonnet", resolvedModel: "claude-sonnet-5").label == "sonnet 5")
    }

    @Test func aSnapshotDateIsLeftOut() {
        #expect(model(value: "haiku", displayName: "Haiku", resolvedModel: "claude-haiku-4-5-20251001").label == "haiku 4.5")
    }

    @Test func theDefaultIsJustDefault() {
        #expect(model(value: "default", displayName: "Default (recommended)", resolvedModel: "claude-opus-5-5[1m]").label == "default")
    }

    @Test func withoutAResolvedIdTheCLINameIsUsed() {
        #expect(model(value: "opus", displayName: "Opus", resolvedModel: nil).label == "opus")
    }

    @Test func theInitializeResponseCarriesTheResolvedId() throws {
        let line = #"{"type":"control_response","response":{"response":{"models":[{"value":"fable[1m]","resolvedModel":"claude-fable-5-1","displayName":"Fable","description":"Fable 5.1","supportsAutoMode":true}]}}}"#
        let models = try #require(ClaudeModels.models(in: Data(line.utf8)))
        #expect(models.map(\.label) == ["fable 5.1"])
    }
}
