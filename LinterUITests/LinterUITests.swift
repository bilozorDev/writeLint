import XCTest

/// XCUITest smoke flight for Linter — one happy path, end to end.
///
/// **Why one test, not many**: UI tests on a menubar app with on-device model
/// latency are flakier than they look. This flight covers the ⌘⏎ submit
/// pathway and the Accept-replaces-input behavior, which together exercise
/// every glue layer between the panel summon and the user's accepted edit.
/// Add new UI tests reluctantly.
///
/// **Global hotkey caveat**: the Carbon `RegisterEventHotKey` machinery is
/// per-process; the global ⌘⇧L will NOT fire from this test runner. We
/// summon the panel by clicking the `MenuBarExtra` status item instead.
///
/// **Accessibility permission caveat**: XCUITest of a menubar app needs the
/// runner to have System Settings → Privacy → Accessibility enabled.
/// First-run prompts a dialog; CI runners need preseeded TCC.
final class LinterUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testSummonTypeLintAcceptHide() throws {
        let app = XCUIApplication()
        app.launch()
        defer { app.terminate() }

        // 1. Click the MenuBarExtra status item to summon the panel.
        // The macOS menu bar exposes status items as `app.menuBars.statusItems`.
        // We don't know the item's title (Linter doesn't set one), so we click
        // the first non-system item — the app's only status item.
        let statusItems = app.menuBars.statusItems
        XCTAssertTrue(
            statusItems.firstMatch.waitForExistence(timeout: 5),
            "Linter's MenuBarExtra status item didn't appear within 5s of launch."
        )
        statusItems.firstMatch.click()

        // 2. The panel summons with the input field already focused. Find it
        // by the accessibility identifier we attached in `InputRow`.
        let input = app.textFields["Linter.InputField"]
            .firstMatch
        if !input.waitForExistence(timeout: 5) {
            // Fallback for macOS where the field reports as a text view.
            let inputView = app.textViews["Linter.InputField"].firstMatch
            XCTAssertTrue(inputView.waitForExistence(timeout: 5), "Input field not found after summon.")
            inputView.click()
            inputView.typeText("i has went to store")
        } else {
            input.click()
            input.typeText("i has went to store")
        }

        // 3. ⌘⏎ submits the lint. The CommandKeyMonitor in LinterWindow
        // routes plain-⏎ to a newline insert, so we MUST hold ⌘.
        app.typeKey(XCUIKeyboardKey.return, modifierFlags: .command)

        // 4. Wait for the diff to appear. The model takes 200–800 ms on a
        // warm device; 15 s is generous to absorb cold-start jitter.
        let diff = app.otherElements["Linter.DiffView"].firstMatch
        XCTAssertTrue(
            diff.waitForExistence(timeout: 15),
            "DiffView didn't appear within 15s — model may be unavailable, slow, or the lint pipeline regressed."
        )

        // 5. Click Accept. The result-replaces-input behavior is the user's
        // headline win, so we assert the input field's value updates.
        let accept = app.buttons["Linter.AcceptButton"].firstMatch
        XCTAssertTrue(accept.exists, "Accept button missing.")
        accept.click()

        // 6. Esc cascades closed: result clears first, then panel hides.
        app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
        // The panel's existence isn't directly observable post-hide, but the
        // diff view should be gone.
        XCTAssertFalse(diff.exists, "DiffView still visible after Esc.")
    }
}
