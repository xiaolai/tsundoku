import AppKit
import Testing
@testable import TsundokuUI

struct LibraryAccessPresentationTests {
    @Test func placementAvoidsSettingsAndStaysOnScreen() {
        let screen = NSRect(x: 0, y: 0, width: 1920, height: 1050)
        let settings = NSRect(x: 100, y: 150, width: 1000, height: 850)
        let size = NSSize(width: 540, height: 570)
        let origin = PanelPlacement.origin(size: size, visible: screen,
            avoiding: [settings], preferred: NSPoint(x: 800, y: 200))
        let frame = NSRect(origin: origin, size: size)
        #expect(screen.contains(frame))
        #expect(!frame.intersects(settings))
    }

    @Test func temporaryAppLocationsRequireInstallation() {
        #expect(LibraryAppLocation.requiresInstallation(URL(fileURLWithPath: "/tmp/build/debug")))
        #expect(LibraryAppLocation.requiresInstallation(URL(fileURLWithPath: "/Volumes/Tsundoku/Tsundoku.app")))
        #expect(LibraryAppLocation.requiresInstallation(URL(fileURLWithPath: "/private/var/folders/x/AppTranslocation/y/d/Tsundoku.app")))
        #expect(!LibraryAppLocation.requiresInstallation(URL(fileURLWithPath: "/Applications/Tsundoku.app")))
        #expect(!LibraryAppLocation.requiresInstallation(URL(fileURLWithPath: "/Users/example/Applications/Tsundoku.app")))
    }

    @Test func unbundledRelaunchIsRejectedBeforeQuitting() {
        #expect(throws: (any Error).self) {
            try ApplicationRelaunch.schedule(appURL: URL(fileURLWithPath: "/tmp/build/debug"), processID: 123, arguments: [])
        }
    }

    @Test func relaunchArgumentsAreDataNotShellCode() {
        let path = URL(fileURLWithPath: "/Applications/A $(touch nope) ' app.app")
        let command = ApplicationRelaunch.command(appURL: path, processID: 123, arguments: ["--archive-path", "a;b"])
        #expect(!command[1].contains(path.path))
        #expect(Array(command.suffix(4)) == ["123", path.path, "--archive-path", "a;b"])
    }
}
