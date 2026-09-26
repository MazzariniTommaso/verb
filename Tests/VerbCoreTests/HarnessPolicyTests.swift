import XCTest
@testable import VerbCore

final class HarnessPolicyTests: XCTestCase {
    func testSettingsWithoutSubscriptionChoicesKeepTheRestAndRememberAModelPerProvider() throws {
        var saved = Settings(); saved.language = .it; saved.cleanupProvider = .endpoint; saved.allowRemoteProcessing = false
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(saved)) as! [String: Any]
        json.removeValue(forKey: "harness")
        var settings = try JSONDecoder().decode(Settings.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(settings.language, .it); XCTAssertEqual(settings.cleanupProvider, .endpoint); XCTAssertFalse(settings.allowRemoteProcessing)
        settings.harnessOptions.provider = .claude; settings.harnessOptions.model = "haiku"
        settings.harnessOptions.provider = .codex; settings.harnessOptions.model = "account-model"
        settings = try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(settings))
        settings.harnessOptions.provider = .claude; XCTAssertEqual(settings.harnessOptions.model, "haiku")
        settings.harnessOptions.provider = .codex; XCTAssertEqual(settings.harnessOptions.model, "account-model")
    }
    func testSubscriptionModeRejectsAPIAndLoggedOutAccounts() throws {
        XCTAssertThrowsError(try HarnessPolicy.subscriptionAccount(.claude, ["loggedIn": true, "authMethod": "api_key", "apiProvider": "firstParty", "subscriptionType": "pro"]))
        XCTAssertThrowsError(try HarnessPolicy.subscriptionAccount(.claude, ["loggedIn": false]))
        XCTAssertThrowsError(try HarnessPolicy.subscriptionAccount(.codex, ["type": "apiKey"]))
        XCTAssertThrowsError(try HarnessPolicy.subscriptionAccount(.copilot, ["isAuthenticated": false]))
        XCTAssertEqual(try HarnessPolicy.subscriptionAccount(.codex, ["type": "chatgpt"]), "ChatGPT subscription")
        for value in ["", "--model", "two words", "model\ncommand"] { XCTAssertThrowsError(try HarnessPolicy.validateModel(value)) }
        try HarnessPolicy.validateModel("claude-opus-5[1m]")
    }
}
