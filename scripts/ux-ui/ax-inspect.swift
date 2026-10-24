// Run only on the dedicated test Mac. Inspects the explicitly supplied process; never finds a reader app.
import AppKit
import ApplicationServices
import Foundation

let args = CommandLine.arguments
 guard args.count >= 2, let pid = Int32(args[1]) else { fatalError("usage: ax-inspect PID [press LABEL | set LABEL VALUE | resize WIDTH HEIGHT | key CODE [cmd]]") }
let app = AXUIElementCreateApplication(pid)
func attr(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var result: CFTypeRef?
    return AXUIElementCopyAttributeValue(element, name as CFString, &result) == .success ? result : nil
}
func children(_ element: AXUIElement) -> [AXUIElement] { attr(element, kAXChildrenAttribute) as? [AXUIElement] ?? [] }
func string(_ element: AXUIElement, _ name: String) -> String { attr(element, name).map { String(describing: $0) } ?? "" }
func requireSuccess(_ code: AXError, _ action: String) {
    guard code == .success else {
        print("FAILED", action, code.rawValue)
        exit(3)
    }
}
// Snapshot reads are strict: a failed window/child read must not look like a
// legitimately empty tree, or a negative assertion passes for the wrong reason.
func strictWindows() -> [AXUIElement] {
    var value: CFTypeRef?
    let code = AXUIElementCopyAttributeValue(
        app, kAXWindowsAttribute as CFString, &value)
    guard code == .success else {
        print("AX WINDOWS READ FAILED", code.rawValue)
        exit(4)
    }
    return value as? [AXUIElement] ?? []
}
func strictChildren(_ element: AXUIElement) -> [AXUIElement] {
    var value: CFTypeRef?
    let code = AXUIElementCopyAttributeValue(
        element, kAXChildrenAttribute as CFString, &value)
    switch code {
    case .success: return value as? [AXUIElement] ?? []
    case .noValue, .attributeUnsupported: return []
    default:
        print("AX CHILDREN READ FAILED", code.rawValue)
        exit(4)
    }
}
/// A window used by an absence assertion must have a readable, non-empty
/// title; otherwise the assertion could mistake missing identity for absence.
func windowTitle(_ window: AXUIElement) -> String {
    var value: CFTypeRef?
    let code = AXUIElementCopyAttributeValue(
        window, kAXTitleAttribute as CFString, &value)
    guard code == .success, let text = value as? String, !text.isEmpty else {
        print("AX WINDOW TITLE READ FAILED", code.rawValue)
        exit(4)
    }
    return text
}
func strictString(
    _ element: AXUIElement, _ name: String, required: Bool = true
) -> String {
    var value: CFTypeRef?
    let code = AXUIElementCopyAttributeValue(element, name as CFString, &value)
    switch code {
    case .success: return value.map { String(describing: $0) } ?? ""
    case .noValue, .attributeUnsupported, .illegalArgument: return ""
    default:
        // AXDescription is genuinely optional and fails on some controls even
        // when the element is present; titles, roles and values are not.
        guard required else { return "" }
        print("AX READ FAILED", name, code.rawValue)
        exit(4)
    }
}
func containsLabel(_ element: AXUIElement, _ label: String, depth: Int = 0) -> Bool {
    guard depth < 10 else { return false }
    if [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute].contains(where: { string(element, $0) == label }) { return true }
    return children(element).contains { containsLabel($0, label, depth: depth + 1) }
}
var visited = Set<CFHashCode>()
func visit(_ element: AXUIElement, depth: Int = 0, action: (AXUIElement, Int) -> Void) {
    guard depth < 28, visited.insert(CFHash(element)).inserted else { return }
    action(element, depth)
    for child in children(element) { visit(child, depth: depth + 1, action: action) }
}
if args.count > 2 {
    let command = args[2]
    if command != "windows" { NSRunningApplication(processIdentifier: pid)?.activate(options: []) }
    if command != "windows" {
        // Raise the focused window, not the first window in the list. After
        // opening Settings from the library, the library is still first but
        // Settings is focused; raising the library would make the tab press
        // fail. The raise is best-effort.
        let focused = attr(app, kAXFocusedWindowAttribute)
            .map { unsafeBitCast($0, to: AXUIElement.self) }
        let fallback = (attr(app, kAXWindowsAttribute) as? [AXUIElement])?
            .first { !string($0, kAXTitleAttribute).hasSuffix("Inspector") }
        if let window = focused ?? fallback {
            _ = AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        }
    }
    Thread.sleep(forTimeInterval: 0.2)
    if command == "windows" {
        for window in strictWindows() {
            // Every enumerated window must produce a line. A failed title or
            // geometry read fails the command instead of omitting a window
            // that an absence assertion would then consider gone.
            let title = windowTitle(window)
            var point = CGPoint.zero
            var size = CGSize.zero
            guard let p = attr(window, kAXPositionAttribute),
                let z = attr(window, kAXSizeAttribute)
            else {
                print("AX WINDOW GEOMETRY READ FAILED", title)
                exit(4)
            }
            AXValueGetValue(unsafeBitCast(p, to: AXValue.self), .cgPoint, &point)
            AXValueGetValue(unsafeBitCast(z, to: AXValue.self), .cgSize, &size)
            print("WINDOW", title, "FRAME", point.x, point.y, size.width, size.height)
        }
    } else if command == "closeWindow", args.count > 3 {
        guard let window = (attr(app, kAXWindowsAttribute) as? [AXUIElement])?.first(where: { string($0, kAXTitleAttribute) == args[3] }),
            let button = attr(window, kAXCloseButtonAttribute)
        else { print("TARGET NOT FOUND:", args[3]); exit(2) }
        let code = AXUIElementPerformAction(unsafeBitCast(button, to: AXUIElement.self), kAXPressAction as CFString)
        print("CLOSE", code.rawValue)
        requireSuccess(code, "close window")
    } else if command == "windowIDs" || command == "allWindowIDs" {
        for window in CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? [] {
            if window[kCGWindowOwnerPID as String] as? Int32 == pid,
               (window[kCGWindowLayer as String] as? Int == 0
                || (command == "allWindowIDs" && window[kCGWindowLayer as String] as? Int == 3)) {
                print("WINDOW_ID", window[kCGWindowNumber as String] ?? "")
            }
        }
    } else if command == "resize", args.count > 4, let width = Double(args[3]), let height = Double(args[4]),
       let window = (attr(app, kAXWindowsAttribute) as? [AXUIElement])?.first(where: {
           !string($0, kAXTitleAttribute).hasSuffix("Inspector")
       }) {
        var size = CGSize(width: width, height: height)
        let value = AXValueCreate(.cgSize, &size)!
        let code = AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, value)
        print("resize", code.rawValue)
        requireSuccess(code, "resize window")
    } else if command == "type", args.count > 3 {
        let units = Array(args[3].utf16)
        let event = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true)!
        units.withUnsafeBufferPointer { buffer in
            event.keyboardSetUnicodeString(stringLength: units.count, unicodeString: buffer.baseAddress)
        }
        event.postToPid(pid)
    } else if command == "key", args.count > 3, let code = UInt16(args[3]) {
        let down = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true)!
        let up = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: false)!
        if args.count > 4 && args[4] == "cmd" { down.flags = .maskCommand; up.flags = .maskCommand }
        if args.count > 4 && args[4] == "shift" { down.flags = .maskShift; up.flags = .maskShift }
        down.postToPid(pid); up.postToPid(pid)
    } else if command == "menubar" {
        guard let bar = attr(app, kAXMenuBarAttribute) else {
            print("MENU BAR NOT FOUND"); exit(2)
        }
        // Only this app's menus. The Apple menu carries Recent Items and the
        // Services submenu lists other applications; neither belongs in gate
        // evidence.
        func dumpMenu(_ element: AXUIElement, depth: Int) {
            let role = string(element, kAXRoleAttribute)
            let title = string(element, kAXTitleAttribute)
            let shortcut = string(element, kAXMenuItemCmdCharAttribute)
            let enabled = string(element, kAXEnabledAttribute)
            print(String(repeating: " ", count: depth) + role + " | " + title
                + " | enabled " + enabled + " | key " + shortcut)
            if title == "Services" { return }
            for child in children(element) { dumpMenu(child, depth: depth + 1) }
        }
        for item in children(unsafeBitCast(bar, to: AXUIElement.self)) {
            if string(item, kAXTitleAttribute) == "Apple" { continue }
            dumpMenu(item, depth: 0)
        }
    } else if command == "pressStatusMenu", args.count > 4 {
        // A MenuBarExtra builds its menu lazily; open the status item first,
        // then press the item without re-activating the app (which would close
        // the menu).
        var statusItem: AXUIElement?
        let checkStatus: (AXUIElement) -> Void = { element in
            guard statusItem == nil,
                string(element, kAXRoleAttribute) == kAXMenuBarItemRole,
                [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute]
                    .contains(where: { string(element, $0) == args[3] })
            else { return }
            statusItem = element
        }
        // Status extras live in their own menu bar. The application menu bar
        // also contains an item titled with the app name, which is not the
        // status item and has no Library item.
        if let extras = attr(app, kAXExtrasMenuBarAttribute) {
            visit(unsafeBitCast(extras, to: AXUIElement.self)) { element, _ in
                checkStatus(element)
            }
        }
        guard let statusItem else { print("STATUS ITEM NOT FOUND:", args[3]); exit(2) }
        var target: AXUIElement?
        let checkTarget: (AXUIElement) -> Void = { element in
            guard target == nil,
                [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute]
                    .contains(where: { string(element, $0) == args[4] }),
                string(element, kAXRoleAttribute) != kAXStaticTextRole
            else { return }
            target = element
        }
        // MenuBarExtra exposes its menu in the AX tree even while closed, and
        // AXPress on the status item itself returns cannotComplete on this
        // app. Poll for the item and press it directly, without reactivating
        // the app or toggling the menu.
        let deadline = Date().addingTimeInterval(3)
        repeat {
            visited.removeAll()
            visit(statusItem) { element, _ in checkTarget(element) }
            if target != nil { break }
            Thread.sleep(forTimeInterval: 0.1)
        } while Date() < deadline
        guard let target else { print("TARGET NOT FOUND:", args[4]); exit(2) }
        let pressCode = AXUIElementPerformAction(target, kAXPressAction as CFString)
        print("press", pressCode.rawValue)
        requireSuccess(pressCode, "press status menu item")
    } else if args.count > 3 {
        var found: AXUIElement?
        visit(app) { element, _ in
            let role = string(element, kAXRoleAttribute)
            let labels = [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute].map { string(element, $0) }
            if command == "select" {
                if found == nil, role == kAXRowRole, containsLabel(element, args[3]) { found = element }
            } else if found == nil, labels.contains(args[3]),
               (command == "set" ? role == kAXTextFieldRole
                : role != kAXStaticTextRole && role != kAXWindowRole
                  && role != kAXApplicationRole) { found = element }
        }
        if let found {
            // Bring the element's own window forward. After opening Settings
            // from the library, the library is still the first/focused
            // window; pressing a tab in the background cannot complete.
            if let windowValue = attr(found, kAXWindowAttribute) {
                let window = unsafeBitCast(windowValue, to: AXUIElement.self)
                _ = AXUIElementPerformAction(window, kAXRaiseAction as CFString)
                _ = AXUIElementSetAttributeValue(window, kAXFocusedAttribute as CFString, kCFBooleanTrue)
            }
            print("TARGET", string(found, kAXRoleAttribute), string(found, kAXTitleAttribute), "enabled", string(found, kAXEnabledAttribute))
            if command == "frame" {
                if let p = attr(found, kAXPositionAttribute), let z = attr(found, kAXSizeAttribute) {
                    var point = CGPoint.zero
                    var size = CGSize.zero
                    AXValueGetValue(unsafeBitCast(p, to: AXValue.self), .cgPoint, &point)
                    AXValueGetValue(unsafeBitCast(z, to: AXValue.self), .cgSize, &size)
                    print("FRAME", point.x, point.y, size.width, size.height)
                }
                if let window = (attr(app, kAXWindowsAttribute) as? [AXUIElement])?.first,
                   let p = attr(window, kAXPositionAttribute), let z = attr(window, kAXSizeAttribute) {
                    var point = CGPoint.zero
                    var size = CGSize.zero
                    AXValueGetValue(unsafeBitCast(p, to: AXValue.self), .cgPoint, &point)
                    AXValueGetValue(unsafeBitCast(z, to: AXValue.self), .cgSize, &size)
                    print("WINDOW_FRAME", point.x, point.y, size.width, size.height)
                }
            } else if command == "help" {
                print("HELP", string(found, kAXHelpAttribute))
            } else if command == "select" {
                let code = AXUIElementSetAttributeValue(found, kAXSelectedAttribute as CFString, kCFBooleanTrue)
                print("select", code.rawValue)
                requireSuccess(code, "select")
            } else if command == "focus" {
                let code = AXUIElementSetAttributeValue(found, kAXFocusedAttribute as CFString, kCFBooleanTrue)
                print("focus", code.rawValue)
                requireSuccess(code, "focus")
            } else if command == "set", args.count > 4 {
                let code = AXUIElementSetAttributeValue(found, kAXValueAttribute as CFString, args[4] as CFString)
                print("set", code.rawValue)
                requireSuccess(code, "set value")
            } else {
                let code = AXUIElementPerformAction(found, kAXPressAction as CFString)
                print("press", code.rawValue)
                requireSuccess(code, "press")
            }
        } else { print("TARGET NOT FOUND:", args[3]); exit(2) }
    }
    Thread.sleep(forTimeInterval: 0.5)
    visited.removeAll()
}
if let focused = attr(app, kAXFocusedUIElementAttribute) {
    let element = unsafeBitCast(focused, to: AXUIElement.self)
    print("FOCUSED", string(element, kAXRoleAttribute), string(element, kAXDescriptionAttribute))
}
func snapshot(_ element: AXUIElement, depth: Int) {
    guard depth < 28 else { return }
    let role = strictString(element, kAXRoleAttribute)
    let title = strictString(element, kAXTitleAttribute)
    let description = strictString(
        element, kAXDescriptionAttribute, required: false)
    let value = strictString(element, kAXValueAttribute)
    if !title.isEmpty || !description.isEmpty || !value.isEmpty {
        print(String(repeating: " ", count: depth) + role + " | " + title + " | " + description + " | " + value.prefix(220))
    }
    for child in strictChildren(element) { snapshot(child, depth: depth + 1) }
}
if args.count <= 2 {
    // A bare invocation is the snapshot the gates assert on: incomplete reads
    // must fail rather than look like absent content.
    for window in strictWindows() { snapshot(window, depth: 0) }
} else {
    // Action commands get a tolerant trailing tree; their action result is
    // already checked and transient read failures during a press are benign.
    for window in attr(app, kAXWindowsAttribute) as? [AXUIElement] ?? [] {
        visit(window) { element, depth in
            let role = string(element, kAXRoleAttribute)
            let title = string(element, kAXTitleAttribute)
            let description = string(element, kAXDescriptionAttribute)
            let value = string(element, kAXValueAttribute)
            if !title.isEmpty || !description.isEmpty || !value.isEmpty {
                print(String(repeating: " ", count: depth) + role + " | " + title + " | " + description + " | " + value.prefix(220))
            }
        }
    }
}
