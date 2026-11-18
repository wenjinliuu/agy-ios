import XCTest

final class AgyUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testDemoConversationFlow() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--demo-data"]
        app.launch()

        let firstRow = app.descendants(matching: .any)["conversation-row-demo-1111-2222-3333-444444444444"].firstMatch
        XCTAssertTrue(firstRow.waitForExistence(timeout: 8))
        firstRow.tap()

        let inputElement = app.descendants(matching: .any)["chat-prompt-input"].firstMatch
        XCTAssertTrue(inputElement.waitForExistence(timeout: 5))

        let thinkingToggle = app.descendants(matching: .any)["thinking-disclosure-1"].firstMatch
        if thinkingToggle.waitForExistence(timeout: 3) {
            thinkingToggle.tap()
        }

        inputElement.tap()
        inputElement.typeText("测试发送")

        let sendButton = app.buttons["chat-send-button"]
        XCTAssertTrue(sendButton.waitForExistence(timeout: 3))
        XCTAssertTrue(sendButton.isEnabled)
    }

    @MainActor
    func testAccessibilityAudit() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--demo-data"]
        app.launch()

        let settingsButton = app.buttons["open-settings-button"]
        XCTAssertTrue(settingsButton.waitForExistence(timeout: 8))
        try app.performAccessibilityAudit()
    }
}
