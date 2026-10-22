import AppKit
import Foundation
import ServiceManagement
import TsundokuCore

enum LoginItem {
    static var status: SMAppService.Status {
        SMAppService.mainApp.status
    }

    static var statusText: String {
        switch status {
        case .enabled: "Enabled"
        case .requiresApproval: "Requires approval"
        case .notRegistered: "Not registered"
        case .notFound: "Not registered"
        @unknown default: "Unknown"
        }
    }

    static var isEnabled: Bool {
        status == .enabled
    }

    /// Registration is idempotent: asking for the state it already has is a
    /// no-op, which is what a settings toggle needs.
    @discardableResult
    static func setEnabled(
        _ enabled: Bool, openApproval: Bool = false
    ) -> String {
        guard Bundle.main.bundleIdentifier != nil else {
            return "Login items need an app bundle."
        }
        let service = SMAppService.mainApp
        do {
            if enabled {
                if service.status != .enabled, service.status != .requiresApproval {
                    try service.register()
                }
            } else if service.status == .enabled || service.status == .requiresApproval {
                try service.unregister()
            }
        } catch {
            TsundokuDiagnostics.shared.event(
                "login_item_failed",
                [
                    "enabled": enabled,
                    "status": statusText,
                    "error": "\(error)",
                ])
            return "Failed: \(error.localizedDescription)"
        }
        TsundokuDiagnostics.shared.event(
            "login_item_status",
            [
                "enabled": enabled,
                "status": statusText,
                "bundle_path": Bundle.main.bundlePath,
                "bundle_id": Bundle.main.bundleIdentifier ?? "",
            ])
        if openApproval, enabled, service.status == .requiresApproval {
            openSettings()
        }
        return statusText
    }

    static func openSettings() {
        let candidates = [
            "x-apple.systempreferences:com.apple.LoginItems-Settings.extension",
            "x-apple.systempreferences:com.apple.preferences.users?LoginItems",
        ]
        for candidate in candidates {
            guard let url = URL(string: candidate) else { continue }
            if NSWorkspace.shared.open(url) { return }
        }
    }
}
