import Testing
import AppKit
@testable import Write_Lint

@Suite("panelOrigin — Spotlight-style centering math, pure")
struct PanelOriginTests {

    @Test func centeredHorizontallyOnGivenScreen() {
        let screen = NSRect(x: 0, y: 0, width: 1920, height: 1080)
        let panel = NSSize(width: 660, height: 200)
        let origin = panelOrigin(for: screen, panelSize: panel)
        // Horizontal: midX of screen minus half-width of panel. Compare with a
        // tiny epsilon — `CGRect.midX` is computed as `origin.x + width * 0.5`
        // which differs from `width / 2` at the last ULP for some widths.
        let expected = screen.midX - panel.width / 2
        #expect(abs(origin.x - expected) < 1e-9)
    }

    @Test func placedSlightlyAboveCenterVertically() {
        // Spotlight sits a bit above center — the formula bumps origin up by
        // 20% of panel height past true center.
        let screen = NSRect(x: 0, y: 0, width: 1920, height: 1080)
        let panel = NSSize(width: 660, height: 200)
        let origin = panelOrigin(for: screen, panelSize: panel)
        let trueCenterY = screen.midY - panel.height / 2
        #expect(origin.y > trueCenterY, "panel should sit above true vertical center")
    }

    @Test func respectsScreenOrigin() {
        // Multi-monitor: a screen with non-zero origin (secondary display)
        // should still get a panel placed relative to its own frame.
        let screen = NSRect(x: 1920, y: 0, width: 1440, height: 900)
        let panel = NSSize(width: 660, height: 200)
        let origin = panelOrigin(for: screen, panelSize: panel)
        #expect(origin.x == screen.midX - panel.width / 2)
    }

    @Test func zeroSizedPanelDoesNotCrash() {
        let screen = NSRect(x: 0, y: 0, width: 1920, height: 1080)
        let origin = panelOrigin(for: screen, panelSize: .zero)
        #expect(origin.x == screen.midX)
        #expect(origin.y == screen.midY)
    }
}
