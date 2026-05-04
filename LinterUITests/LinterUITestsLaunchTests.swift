//
//  LinterUITestsLaunchTests.swift
//  LinterUITests
//
//  Created by Alex Bilozor on 5/1/26.
//

import XCTest

final class LinterUITestsLaunchTests: XCTestCase {

    override class var runsForEachTargetApplicationUIConfiguration: Bool {
        true
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testLaunch() throws {
        // Same structural problem as `LinterUITests.testSummonTypeLintAcceptHide`:
        // `XCUIApplication.launch()` tries to terminate the existing instance
        // first, but `.accessory` menu-bar apps don't respond to XCTest's
        // `_NSTerminate` handshake, so launch() hangs ~60 s and the test fails.
        // Keep the screenshot scaffolding compiling so a future contributor
        // can revisit if Apple improves XCUITest support for menu-bar apps.
        try XCTSkipIf(true, "XCUITest's launch() hangs on .accessory menu-bar apps; see LinterUITests.swift for the full reasoning.")

        let app = XCUIApplication()
        app.launch()

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Launch Screen"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
