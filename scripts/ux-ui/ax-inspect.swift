// Run only on macmini-000. Inspects the explicitly supplied process; never finds a reader app.
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
    NSRunningApplication(processIdentifier: pid)?.activate(options: [])
    if let window = (attr(app, kAXWindowsAttribute) as? [AXUIElement])?.first(where: {
           !string($0, kAXTitleAttribute).hasSuffix("Inspector")
       }) {
        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
    }
    Thread.sleep(forTimeInterval: 0.2)
    let command = args[2]
    if command == "windowIDs" {
        for window in CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? [] {
            if window[kCGWindowOwnerPID as String] as? Int32 == pid,
               window[kCGWindowLayer as String] as? Int == 0 {
                print("WINDOW_ID", window[kCGWindowNumber as String] ?? "")
            }
        }
    } else if command == "resize", args.count > 4, let width = Double(args[3]), let height = Double(args[4]),
       let window = (attr(app, kAXWindowsAttribute) as? [AXUIElement])?.first(where: {
           !string($0, kAXTitleAttribute).hasSuffix("Inspector")
       }) {
        var size = CGSize(width: width, height: height)
        let value = AXValueCreate(.cgSize, &size)!
        print("resize", AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, value).rawValue)
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
    } else if args.count > 3 {
        var found: AXUIElement?
        visit(app) { element, _ in
            let role = string(element, kAXRoleAttribute)
            let labels = [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute].map { string(element, $0) }
            if command == "select" {
                if found == nil, role == kAXRowRole, containsLabel(element, args[3]) { found = element }
            } else if found == nil, labels.contains(args[3]),
               (command == "set" ? role == kAXTextFieldRole : role != kAXStaticTextRole) { found = element }
        }
        if let found {
            print("TARGET", string(found, kAXRoleAttribute), string(found, kAXTitleAttribute), "enabled", string(found, kAXEnabledAttribute))
            if command == "help" {
                print("HELP", string(found, kAXHelpAttribute))
            } else if command == "select" {
                print("select", AXUIElementSetAttributeValue(found, kAXSelectedAttribute as CFString, kCFBooleanTrue).rawValue)
            } else if command == "focus" {
                print("focus", AXUIElementSetAttributeValue(found, kAXFocusedAttribute as CFString, kCFBooleanTrue).rawValue)
            } else if command == "set", args.count > 4 {
                print("set", AXUIElementSetAttributeValue(found, kAXValueAttribute as CFString, args[4] as CFString).rawValue)
            } else { print("press", AXUIElementPerformAction(found, kAXPressAction as CFString).rawValue) }
        } else { print("TARGET NOT FOUND:", args[3]); exit(2) }
    }
    Thread.sleep(forTimeInterval: 0.5)
    visited.removeAll()
}
if let focused = attr(app, kAXFocusedUIElementAttribute) {
    let element = unsafeBitCast(focused, to: AXUIElement.self)
    print("FOCUSED", string(element, kAXRoleAttribute), string(element, kAXDescriptionAttribute))
}
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
