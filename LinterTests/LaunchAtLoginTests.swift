import Testing
import AppKit
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

@Suite("isLoginItemLaunch — launch Apple event classification, pure")
struct LoginItemLaunchTests {

    /// Build a core-suite Apple event like the one that launches the app,
    /// optionally tagged with a `keyAEPropData` enum value.
    private static func event(id: AEEventID, propData: OSType? = nil) -> NSAppleEventDescriptor {
        let event = NSAppleEventDescriptor(
            eventClass: AEEventClass(kCoreEventClass),
            eventID: id,
            targetDescriptor: nil,
            returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID)
        )
        if let propData {
            event.setParam(
                NSAppleEventDescriptor(enumCode: propData),
                forKeyword: AEKeyword(keyAEPropData)
            )
        }
        return event
    }

    @Test func loginItemMarkerIsDetected() {
        #expect(isLoginItemLaunch(Self.event(id: kAEOpenApplication, propData: keyAELaunchedAsLogInItem)))
    }

    @Test func plainUserLaunchIsNotALoginLaunch() {
        // Finder / Launchpad / `open`: open-application with no marker.
        #expect(!isLoginItemLaunch(Self.event(id: kAEOpenApplication)))
    }

    @Test func missingEventIsNotALoginLaunch() {
        // No current Apple event must err toward showing the panel.
        #expect(!isLoginItemLaunch(nil))
    }

    @Test func otherPropDataIsNotALoginLaunch() {
        // e.g. launched as a service item — still a launch the user caused.
        #expect(!isLoginItemLaunch(Self.event(id: kAEOpenApplication, propData: keyAELaunchedAsServiceItem)))
    }

    @Test func markerOnADifferentEventIsIgnored() {
        #expect(!isLoginItemLaunch(Self.event(id: kAEReopenApplication, propData: keyAELaunchedAsLogInItem)))
    }
}
