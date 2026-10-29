import XCTest

/// Start the development relay on localhost:18080 before running (see docs/ios.md).
final class PairingMessagesTests: XCTestCase {
    private let root = "http://127.0.0.1:18080"
    private let key = "ak_ios_ui_test"

    private func request(_ path: String, method: String = "GET", body: [String: Any]? = nil) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: root + path)!)
        request.httpMethod = method
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse, (200...299).contains(response.statusCode) else {
            throw NSError(domain: "RelayUITest", code: 1, userInfo: [NSLocalizedDescriptionKey: String(data: data, encoding: .utf8) ?? "Relay failed"])
        }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    @MainActor
    func testManualPairingMessagesAndRelaunch() async throws {
        continueAfterFailure = false
        do { _ = try await request("/healthz") }
        catch { throw XCTSkip("Start the UI-test relay on localhost:18080 (docs/ios.md).") }
        let token = try await request("/v1/pairing-tokens", method: "POST")
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting-reset-pairing"]
        addUIInterruptionMonitor(withDescription: "Permissions") { alert in
            for title in ["Allow", "Allow While Using App", "OK", "Permitir", "Aceptar"] {
                if alert.buttons[title].exists { alert.buttons[title].tap(); return true }
            }
            return false
        }
        app.launch()
        if app.buttons["Pair manually"].waitForExistence(timeout: 5) {
            app.buttons["Pair manually"].tap()
            let relay = app.textFields["Relay URL · https://…"]
            relay.tap(); relay.typeText(root)
            let secret = app.secureTextFields["Pairing token · pt_…"]
            secret.tap(); secret.typeText(token["pairing_token"] as! String)
            app.buttons["Connect relay"].tap()
            // Handle notification and microphone permission prompts during pairing.
            for _ in 0..<3 { app.tap() }
        }
        XCTAssertTrue(app.tabBars.buttons["Messages"].waitForExistence(timeout: 15))
        let messagesTab = app.tabBars.buttons["Messages"]
        if messagesTab.isHittable { messagesTab.tap() }
        else { app.tabBars.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap() }
        let marker = "iPhone test \(UUID().uuidString.prefix(8))"
        _ = try await request("/v1/messages", method: "POST", body: ["text": marker])
        XCTAssertTrue(app.staticTexts[marker].waitForExistence(timeout: 15))
        let input = app.descendants(matching: .any)["message-input"]
        input.tap(); input.typeText("Received on iPhone")
        app.buttons["Send message"].tap()
        XCTAssertTrue(app.staticTexts["Received on iPhone"].firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.buttons["messages-back"].isHittable)
        app.buttons["messages-back"].tap()
        XCTAssertTrue(app.buttons["Call agent"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["call-mrvedsil"].waitForExistence(timeout: 5))
        if app.tabBars.buttons["Messages"].isHittable { app.tabBars.buttons["Messages"].tap() }
        else { app.tabBars.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap() }
        let draft = app.descendants(matching: .any)["message-input"]
        draft.tap(); draft.typeText("Unsent draft")
        XCTAssertTrue(app.buttons["dismiss-message-keyboard"].waitForExistence(timeout: 5))
        app.buttons["dismiss-message-keyboard"].tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
        app.descendants(matching: .any)["message-input"].tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        app.buttons["messages-back"].tap()
        XCTAssertTrue(app.buttons["Call agent"].waitForExistence(timeout: 5))
        if app.tabBars.buttons["Messages"].isHittable { app.tabBars.buttons["Messages"].tap() }
        else { app.tabBars.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap() }
        XCTAssertEqual(app.descendants(matching: .any)["message-input"].value as? String, "Unsent draft")
        app.tabBars.buttons["Settings"].tap()
        XCTAssertTrue(app.buttons["choose-caller-contact"].waitForExistence(timeout: 5))
        app.buttons["choose-caller-contact"].tap()
        XCTAssertTrue(app.buttons["Cancel"].firstMatch.waitForExistence(timeout: 10))
        app.buttons["Cancel"].firstMatch.tap()
        XCTAssertTrue(app.buttons["choose-caller-contact"].waitForExistence(timeout: 5))
        let page = try await request("/v1/messages?limit=500")
        let messages = page["messages"] as! [[String: Any]]
        XCTAssertTrue(messages.contains { $0["from"] as? String == "user" && $0["text"] as? String == "Received on iPhone" })
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Messages round trip"; attachment.lifetime = .keepAlways; add(attachment)
        app.terminate(); app.launchArguments = []; app.launch()
        XCTAssertTrue(app.tabBars.buttons["Messages"].waitForExistence(timeout: 10))
        if app.tabBars.buttons["Messages"].isHittable { app.tabBars.buttons["Messages"].tap() }
        else { app.tabBars.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap() }
        XCTAssertTrue(app.staticTexts[marker].waitForExistence(timeout: 10))
    }
}
