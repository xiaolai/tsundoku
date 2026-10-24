import Foundation

/// Waits for an ordinary quit before asking LaunchServices for a fresh process.
/// If quitting is cancelled, the helper times out without opening another copy.
public enum ApplicationRelaunch {
    static func command(appURL: URL, processID: Int32, arguments: [String]) -> [String] {
        ["-c", """
        pid="$1"; app="$2"; shift 2
        attempts=0
        while /bin/kill -0 "$pid" 2>/dev/null; do
            attempts=$((attempts + 1))
            [ "$attempts" -lt 120 ] || exit 1
            /bin/sleep 0.5
        done
        exec /usr/bin/open -n "$app" --args "$@"
        """, "tsundoku-relaunch", String(processID), appURL.path] + arguments
    }

    public static func schedule(appURL: URL, processID: Int32, arguments: [String]) throws {
        guard appURL.pathExtension.lowercased() == "app",
            FileManager.default.fileExists(atPath: appURL.appendingPathComponent("Contents/Info.plist").path) else {
            throw CocoaError(.fileReadUnsupportedScheme,
                userInfo: [NSLocalizedDescriptionKey: "Run the installed Tsundoku app from Applications before reopening"])
        }
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/sh")
        helper.arguments = command(appURL: appURL, processID: processID, arguments: arguments)
        helper.standardInput = FileHandle.nullDevice
        helper.standardOutput = FileHandle.nullDevice
        helper.standardError = FileHandle.nullDevice
        try helper.run()
    }
}
