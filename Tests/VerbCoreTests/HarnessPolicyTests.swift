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
    func testAFailedCLISaysWhyFromWhatItPrinted() {
        let codex = """
        {"type":"thread.started","thread_id":"0199"}
        {"type":"turn.started"}
        {"type":"error","message":"You've hit your usage limit. Try again at 11:05."}
        {"type":"turn.failed","error":{"message":"You've hit your usage limit. Try again at 11:05."}}
        """
        XCTAssertEqual(HarnessPolicy.failureReason(output: codex), "You've hit your usage limit. Try again at 11:05.")
        XCTAssertEqual(HarnessPolicy.failureReason(output: #"{"type":"result","subtype":"error_during_execution","is_error":true,"result":"Model not available"}"#), "Model not available")
        XCTAssertEqual(HarnessPolicy.failureReason(output: "Loading…\nerror: unknown model gpt-x\n"), "error: unknown model gpt-x")
        XCTAssertNil(HarnessPolicy.failureReason(output: ""))
        XCTAssertNil(HarnessPolicy.failureReason(output: #"{"type":"turn.started"}"#), "an event that names no error says nothing")
        let account = """
        {
          "loggedIn": false,
          "authMethod": "none"
        }
        """
        XCTAssertEqual(HarnessPolicy.failureReason(output: account), HarnessPolicy.notSignedIn, "an account check over several lines, with no one signed in")
    }
}
