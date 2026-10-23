import XCTest

final class ScreenshotTests: XCTestCase {
    @MainActor func testCaptureMainScreensWithExampleData() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--screenshot-testing", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Your money,\na little clearer."].waitForExistence(timeout: 20))
        capture("01-Dashboard-example-data")
        for (index, title) in ["Accounts", "Transactions", "Budget", "Cash flow"].enumerated() {
            let button = app.tabBars.buttons[title]
            XCTAssertTrue(button.waitForExistence(timeout: 10)); button.tap()
            XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout: 10))
            capture(String(format: "%02d-%@-example-data", index + 2, title.replacingOccurrences(of: " ", with: "-")))
        }
        for (index, title) in ["Receipts", "HSA receipts", "Shipments"].enumerated() {
            // Relaunching gives each screen a fresh, isolated in-memory fixture store.
            app.terminate(); app.launch()
            let more = app.buttons["More screens"]
            XCTAssertTrue(more.waitForExistence(timeout: 15)); more.tap()
            let destination = app.staticTexts[title].firstMatch
            XCTAssertTrue(destination.waitForExistence(timeout: 10)); destination.tap()
            XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout: 10))
            capture(String(format: "%02d-%@-example-data", index + 6, title.replacingOccurrences(of: " ", with: "-")))
            if title == "Receipts" {
                let receipt = app.staticTexts["Example Outfitters"].firstMatch
                XCTAssertTrue(receipt.waitForExistence(timeout: 10)); receipt.tap()
                XCTAssertTrue(app.navigationBars["Receipt"].waitForExistence(timeout: 10))
                capture("09-Receipt-details-example-data")
            } else if title == "Shipments" {
                let shipment = app.staticTexts["Example Outfitters"].firstMatch
                XCTAssertTrue(shipment.waitForExistence(timeout: 10)); shipment.tap()
                XCTAssertTrue(app.navigationBars["Shipment"].waitForExistence(timeout: 10))
                capture("10-Shipment-timeline-example-data")
            }
        }
    }
    @MainActor private func capture(_ name: String) {
        XCTContext.runActivity(named: name) { activity in
            let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            attachment.name = name; attachment.lifetime = .keepAlways
            activity.add(attachment)
        }
    }
}
