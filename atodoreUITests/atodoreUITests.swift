//
//  atodoreUITests.swift
//  atodoreUITests
//
//  Created by Tomonori_Ueda on 2026/08/16.
//

import XCTest

final class atodoreUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testMainTabsAreAvailableAfterOnboarding() throws {
        let app = launchApp(hasCompletedOnboarding: true)

        XCTAssertTrue(app.tabBars.buttons["ホーム"].waitForExistence(timeout: 4))
        XCTAssertTrue(app.tabBars.buttons["買い物"].exists)
        XCTAssertTrue(app.tabBars.buttons["ストック"].exists)
        XCTAssertTrue(app.tabBars.buttons["設定"].exists)
    }

    @MainActor
    func testSettingsCanOpenTemplateLibrary() throws {
        let app = launchApp(hasCompletedOnboarding: true)

        app.tabBars.buttons["設定"].tap()

        XCTAssertTrue(app.buttons["テンプレートから追加"].waitForExistence(timeout: 4))
        app.buttons["テンプレートから追加"].tap()

        XCTAssertTrue(app.navigationBars["テンプレート"].waitForExistence(timeout: 4))
        XCTAssertTrue(app.staticTexts["テンプレートを選ぶ"].exists)
        XCTAssertTrue(app.staticTexts["生活用品"].exists)
    }

    @MainActor
    func testOnboardingShowsInitialSetupAndTemplates() throws {
        let app = launchApp(hasCompletedOnboarding: false)

        XCTAssertTrue(app.staticTexts["必要な時だけ、知らせます"].waitForExistence(timeout: 4))
        XCTAssertTrue(app.staticTexts["初期設定"].exists)
        XCTAssertTrue(app.staticTexts["テンプレートを選ぶ"].exists)
        XCTAssertTrue(app.buttons.containing(NSPredicate(format: "label CONTAINS %@", "選んだテンプレートを登録")).firstMatch.exists)
    }

    @MainActor
    func testLaunchPerformance() throws {
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            _ = launchApp(hasCompletedOnboarding: true)
        }
    }

    @MainActor
    private func launchApp(hasCompletedOnboarding: Bool) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += [
            "-hasCompletedOnboarding",
            hasCompletedOnboarding ? "YES" : "NO"
        ]
        app.launch()
        return app
    }
}
