import XCTest

final class SmokeTests: XCTestCase {
    @MainActor func testManualAccountAndMainTabs() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Your money,\na little clearer."].waitForExistence(timeout: 10))
        app.buttons["Add your first account"].tap()
        app.buttons["Add a manual account"].tap()
        app.textFields["Name"].tap(); app.textFields["Name"].typeText("Test Checking")
        app.textFields["Current balance"].tap(); app.textFields["Current balance"].typeText("1000")
        app.buttons["Save"].tap()
        app.tabBars.buttons["Accounts"].tap()
        XCTAssertTrue(app.staticTexts["Test Checking"].waitForExistence(timeout: 5))
        app.tabBars.buttons["Budget"].tap()
        XCTAssertTrue(app.buttons["Edit this month’s plan"].waitForExistence(timeout: 5))
        app.tabBars.buttons["Cash flow"].tap()
        XCTAssertTrue(app.staticTexts["MONEY IN, MONEY OUT"].waitForExistence(timeout: 5))
        app.tabBars.buttons["Transactions"].tap()
        XCTAssertTrue(app.buttons["Add transaction"].waitForExistence(timeout: 5))
        app.buttons["More screens"].tap()
        XCTAssertTrue(app.staticTexts["Receipts"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["HSA receipts"].exists)
        XCTAssertTrue(app.staticTexts["Shipments"].exists)
    }
}
