import SwiftUI

/// The app shell is a SwiftUI `App`: the status menu, the library window and
/// Settings are scenes, and AppDelegate only owns services. The companion
/// panel stays a native `NSPanel` because SwiftUI has no borderless
/// nonactivating scene; see `CompanionWindow`.
@main
struct TsundokuApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            StatusMenuView(delegate: delegate)
        } label: {
            MenuBarLabel(delegate: delegate)
        }
        .menuBarExtraStyle(.menu)

        Window("Library", id: LibraryScene.id) {
            LibrarySceneView(delegate: delegate)
        }
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)
        .defaultSize(width: 1280, height: 820)
        .windowResizability(.contentMinSize)
        .commands {
            TsundokuCommands(delegate: delegate)
        }

        Settings {
            SettingsSceneView(delegate: delegate)
        }
    }
}

enum LibraryScene {
    static let id = "library"
}
