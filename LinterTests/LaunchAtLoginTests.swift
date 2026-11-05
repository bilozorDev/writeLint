import Testing
import ServiceManagement
@testable import Write_Lint

@Suite("loginItemState — SMAppService.Status mapping, pure")
struct LaunchAtLoginTests {

    @Test func enabledMapsToOnNotPending() {
        #expect(loginItemState(for: .enabled)
            == LoginItemState(isEnabled: true, requiresApproval: false))
    }

    @Test func requiresApprovalMapsToOffPending() {
        #expect(loginItemState(for: .requiresApproval)
            == LoginItemState(isEnabled: false, requiresApproval: true))
    }

    @Test func notRegisteredMapsToOff() {
        #expect(loginItemState(for: .notRegistered)
            == LoginItemState(isEnabled: false, requiresApproval: false))
    }

    @Test func notFoundMapsToOff() {
        // Caller (`refresh()`) logs this case; the mapping itself is just off.
        #expect(loginItemState(for: .notFound)
            == LoginItemState(isEnabled: false, requiresApproval: false))
    }
}
