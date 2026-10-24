import AppKit
import CoreGraphics
import Foundation
import ImageIO
import KindleAX
import TsundokuCore
import UniformTypeIdentifiers

/// Structural Books measurement. Prints counts, roles, identifiers and
/// frames, never page text, and is used while the capture adapter is built.
enum BooksProbe {
    static func run(_ arguments: [String]) {
        if arguments.contains("--windows") {
            dumpWindows()
            return
        }
        if arguments.contains("--menus") {
            dumpMenus()
            return
        }
        do {
            print("trusted=\(BooksLive.isTrusted())")
            print("frontmost=\(BooksLive.isFrontmost())")
            let page = try BooksLive.currentPage()
            print("state=\(page.state) title=\(page.title)")
            print("textChars=\(page.text.count) frames=\(page.textFrames.count)")
            print(
                "window=\(format(page.windowFrame)) "
                    + "main=\(page.windowMain) focused=\(page.windowFocused)")
            print("crop=\(format(page.cropRect))")
            for (index, value) in page.webAreaFrames.enumerated() {
                print("web[\(index)]=\(format(value))")
            }
            for (index, value) in page.textFrames.prefix(12).enumerated() {
                print("text[\(index)]=\(format(value))")
            }
            let reader = try BooksLive.readerWindow()
            print("--- tree ---")
            dump(reader.node, depth: 0, maxDepth: 12)
            print("--- tree end ---")

            if arguments.contains("--font-menu") {
                try BooksLive.focusReader()
                let before = try BooksLive.currentPage()
                let increased = BooksLive.pressMenuItem(
                    "Increase Font Size")
                Thread.sleep(forTimeInterval: 2.0)
                let after = try BooksLive.currentPage()
                print(
                    "fontMenu increased=\(increased) "
                        + "chars=\(before.text.count)->\(after.text.count) "
                        + "frames=\(before.textFrames.count)->"
                        + "\(after.textFrames.count) "
                        + "sig=\(signature(before))->\(signature(after))")
                let decreased = BooksLive.pressMenuItem(
                    "Decrease Font Size")
                Thread.sleep(forTimeInterval: 2.0)
                let restored = try BooksLive.currentPage()
                print(
                    "fontMenu decreased=\(decreased) "
                        + "chars=\(restored.text.count) "
                        + "frames=\(restored.textFrames.count)")
            }
            if arguments.contains("--text-plus") {
                try textStep(forward: true)
            }
            if arguments.contains("--text-minus") {
                try textStep(forward: false)
            }
            if arguments.contains("--a4-setup") {
                do {
                    let pre = try BooksLive.currentPage()
                    print(
                        "pre state=\(pre.state) "
                            + "window=\(format(pre.windowFrame)) "
                            + "crop=\(format(pre.cropRect))")
                } catch {
                    print("preError=\(error)")
                }
                let setup = BooksPageSetup(
                    request: PageSetupRequest(pageSize: .a4),
                    writeWindow: { frame in
                        print("write target=\(format(frame))")
                        do {
                            let actual = try BooksLive.setWindowFrame(frame)
                            print("wrote=\(format(actual))")
                            return actual
                        } catch {
                            print("writeError=\(error)")
                            throw error
                        }
                    })
                do {
                    let outcome = try setup.begin()
                    print(
                        "begin restored=\(outcome.restored) "
                            + "final=\(format(outcome.finalWindow))")
                    sleep(1)
                    let restored = setup.restore()
                    print(
                        "restore restored=\(restored.restored) "
                            + "reason=\(restored.reason ?? "") "
                            + "final=\(format(restored.finalWindow))")
                } catch {
                    print("setupError=\(error)")
                    let restored = setup.restore()
                    print(
                        "afterError restored=\(restored.restored) "
                            + "reason=\(restored.reason ?? "")")
                }
            }
            if let value = stringValue("--resize", arguments) {
                let parts = value.split(separator: "x").compactMap {
                    Double($0)
                }
                guard parts.count == 2 else {
                    throw BooksLiveError.readFailed("--resize WIDTHxHEIGHT")
                }
                let reader = try BooksLive.readerWindow()
                guard let current = reader.frame else {
                    throw BooksLiveError.noWindow
                }
                let target = CGRect(
                    x: current.minX, y: current.minY,
                    width: parts[0], height: parts[1])
                let actual = try BooksLive.setWindowFrame(target)
                print(
                    "resize=\(Int(actual.width))x\(Int(actual.height)) "
                        + "target=\(Int(parts[0]))x\(Int(parts[1]))")
                let after = try BooksLive.currentPage()
                print(
                    "afterCrop=\(format(after.cropRect)) "
                        + "textChars=\(after.text.count) "
                        + "frames=\(after.textFrames.count)")
            }
            if arguments.contains("--focus") {
                let report = try BooksLive.focusReader()
                print(
                    "focus front=\(report.frontmost) main=\(report.windowMain) "
                        + "focused=\(report.windowFocused) "
                        + "raised=\(report.raised) "
                        + "title=\(report.focusedWindowTitle ?? "") "
                        + "role=\(report.focusedRole ?? "")")
                let after = try BooksLive.currentPage()
                print(
                    "after main=\(after.windowMain) "
                        + "focused=\(after.windowFocused)")
            }
            if let count = intValue("--turn", arguments) {
                try runTurns(count, forward: true)
            }
            if let count = intValue("--back", arguments) {
                try runTurns(count, forward: false)
            }
            if arguments.contains("--until-stable") {
                try runUntilStable()
            }
            if arguments.contains("--ocr") {
                try BooksLive.focusReader()
                let current = try BooksLive.currentPage()
                guard let crop = current.cropRect else {
                    throw BooksLiveError.noWindow
                }
                let image = try BooksLive.pageImage(crop)
                let started = Date()
                let text = try BooksLive.recognizeText(in: image)
                print(
                    "ocrChars=\(text.count) "
                        + "seconds=\(Date().timeIntervalSince(started))")
            }
            if arguments.contains("--save") {
                try BooksLive.focusReader()
                let current = try BooksLive.currentPage()
                guard let crop = current.cropRect else {
                    throw BooksLiveError.noWindow
                }
                let image = try BooksLive.pageImage(crop)
                let url = URL(fileURLWithPath: "/tmp/books-window.png")
                guard
                    let destination = CGImageDestinationCreateWithURL(
                        url as CFURL, UTType.png.identifier as CFString,
                        1, nil)
                else { throw BooksLiveError.readFailed("no PNG writer") }
                CGImageDestinationAddImage(destination, image, nil)
                guard CGImageDestinationFinalize(destination) else {
                    throw BooksLiveError.readFailed("could not write PNG")
                }
                print("saved=\(url.path) size=\(image.width)x\(image.height)")
            }
        } catch {
            print("error: \(error)")
            exit(1)
        }
    }

    private static func dumpMenus() {
        guard
            let app = NSRunningApplication.runningApplications(
                withBundleIdentifier: BooksLive.bundleID).first
        else {
            print("books=not-running")
            return
        }
        let application = AXUIElementCreateApplication(
            app.processIdentifier)
        var menuBar: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(
                application, kAXMenuBarAttribute as CFString,
                &menuBar) == .success,
            let menuBar,
            CFGetTypeID(menuBar) == AXUIElementGetTypeID()
        else {
            print("menubar=none")
            return
        }
        let bar = unsafeDowncast(menuBar, to: AXUIElement.self)
        var rawChildren: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(
                bar, kAXChildrenAttribute as CFString,
                &rawChildren) == .success,
            let items = rawChildren as? [AXUIElement]
        else {
            print("menubar=empty")
            return
        }
        for item in items {
            let title = attribute(item, kAXTitleAttribute) ?? ""
            guard !title.isEmpty else { continue }
            print("menu=\(title)")
            guard
                let sub = children(item).first,
                title == "Format" || title == "View"
            else { continue }
            for entry in children(sub).prefix(40) {
                let name = attribute(entry, kAXTitleAttribute) ?? ""
                if !name.isEmpty {
                    let enabled = boolAttribute(entry, kAXEnabledAttribute)
                    let command = attribute(
                        entry, kAXMenuItemCmdCharAttribute) ?? ""
                    print(
                        "  item=\(name) enabled=\(enabled) "
                            + "cmd=\(command)")
                }
            }
        }
    }

    private static func boolAttribute(
        _ element: AXUIElement, _ name: String
    ) -> Bool {
        var value: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(
                element, name as CFString, &value) == .success,
            let number = value as? NSNumber
        else { return false }
        return number.boolValue
    }

    private static func attribute(
        _ element: AXUIElement, _ name: String
    ) -> String? {
        var value: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(
                element, name as CFString, &value) == .success
        else { return nil }
        return value as? String
    }

    private static func children(_ element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(
                element, kAXChildrenAttribute as CFString, &value) == .success
        else { return [] }
        return value as? [AXUIElement] ?? []
    }

    private static func textStep(forward: Bool) throws {
        try BooksLive.focusReader()
        let before = try BooksLive.currentPage()
        let key: CGKeyCode = forward ? 24 : 27
        for shift in [false, true] {
            guard
                let down = CGEvent(
                    keyboardEventSource: nil, virtualKey: key, keyDown: true),
                let up = CGEvent(
                    keyboardEventSource: nil, virtualKey: key, keyDown: false)
            else { continue }
            down.flags = shift
                ? [.maskCommand, .maskShift] : [.maskCommand]
            up.flags = down.flags
            down.postToPid(BooksLive.pid())
            up.postToPid(BooksLive.pid())
            Thread.sleep(forTimeInterval: 0.4)
            let after = try BooksLive.currentPage()
            if after.text != before.text
                || after.textFrames.count != before.textFrames.count
            {
                print(
                    "step=\(forward ? "plus" : "minus") shift=\(shift) "
                        + "changed=true chars=\(after.text.count) "
                        + "frames=\(after.textFrames.count)")
                return
            }
        }
        print("step=\(forward ? "plus" : "minus") changed=false")
    }

    private static func dumpWindows() {
        do {
            guard
                let app = NSRunningApplication.runningApplications(
                    withBundleIdentifier: BooksLive.bundleID).first
            else {
                print("books=not-running")
                return
            }
            let application = AXUIElementCreateApplication(
                app.processIdentifier)
            let source = LiveAXSource()
            let recorder = AXRecorder(source: source)
            let windows = try source.windows(application)
            for (index, window) in windows.enumerated() {
                let node = try recorder.capture(window)
                print(
                    "window[\(index)] title=\(node.title ?? "") "
                        + "role=\(node.role) frame=\(format(node.frame)) "
                        + "web=\(BooksPageText.webAreaCount(in: node)) "
                        + "children=\(node.children.count)")
                dump(node, depth: 0, maxDepth: 4)
            }
        } catch {
            print("error: \(error)")
        }
    }

    private static func runTurns(_ count: Int, forward: Bool) throws {
        try BooksLive.focusReader()
        var previous = try BooksLive.currentPage()
        for index in 1...max(1, count) {
            if forward {
                try BooksLive.turnForward()
            } else {
                try BooksLive.turnBackward()
            }
            Thread.sleep(forTimeInterval: 0.65)
            let page = try BooksLive.currentPage()
            guard let crop = page.cropRect else {
                throw BooksLiveError.noWindow
            }
            let image = try BooksLive.pageImage(crop)
            let leased = BooksLive.hasReaderLease(try BooksLive.readerWindow())
            print(
                "turn[\(index)] sameText=\(page.text == previous.text) "
                    + "chars=\(page.text.count) "
                    + "textHash=\(hashText(page.text)) "
                    + "imageHash=\(ImageFingerprint.averageHash(image)) "
                    + "lease=\(leased)")
            previous = page
        }
    }

    private static func signature(_ page: BooksLivePage) -> String {
        page.textFrames.prefix(3).map {
            "\(Int($0.width))x\(Int($0.height))"
        }.joined(separator: ",")
    }

    private static func runUntilStable() throws {
        try BooksLive.focusReader()
        var previous: (text: String, image: UInt64)?
        var stable = 0
        for index in 1...400 {
            try BooksLive.turnForward()
            Thread.sleep(forTimeInterval: 0.65)
            let page = try BooksLive.currentPage()
            guard let crop = page.cropRect else {
                throw BooksLiveError.noWindow
            }
            let image = try BooksLive.pageImage(crop)
            let hash = ImageFingerprint.averageHash(image)
            let leased = BooksLive.hasReaderLease(try BooksLive.readerWindow())
            let same =
                previous?.text == page.text && previous?.image == hash
            print(
                "stable[\(index)] same=\(same) chars=\(page.text.count) "
                    + "textHash=\(hashText(page.text)) imageHash=\(hash) "
                    + "lease=\(leased)")
            if same {
                stable += 1
                if stable >= 2 || !leased { break }
            } else {
                stable = 0
            }
            previous = (page.text, hash)
        }
    }

    private static func dump(_ node: AXNode, depth: Int, maxDepth: Int) {
        guard depth <= maxDepth else { return }
        let role = node.role
        let identifier = node.identifier ?? ""
        let hasValue = node.value != nil
        var line =
            String(repeating: "  ", count: depth)
            + "\(role)"
            + (identifier.isEmpty ? "" : " id=\(identifier)")
            + " frame=\(format(node.frame))"
            + " children=\(node.children.count)"
            + " actions=\(node.actions.count)"
        if let number = node.value?.asNumber, role == "AXSlider" {
            line += " value=\(number)"
        } else if hasValue, role == "AXSlider" {
            line += " value=text"
        } else if ["AXStaticText", "AXHeading", "AXTextArea"]
            .contains(role)
        {
            line += " valueChars=\(node.value?.asText?.count ?? 0)"
        }
        print(line)
        for child in node.children {
            dump(child, depth: depth + 1, maxDepth: maxDepth)
        }
    }

    private static func format(_ value: CGRect?) -> String {
        guard let value else { return "none" }
        return "\(Int(value.minX)),\(Int(value.minY)) "
            + "\(Int(value.width))x\(Int(value.height))"
    }

    private static func format(_ value: AXNode.Frame?) -> String {
        guard let value else { return "none" }
        return "\(Int(value.x)),\(Int(value.y)) "
            + "\(Int(value.width))x\(Int(value.height))"
    }

    private static func hashText(_ text: String) -> UInt64 {
        var value: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            value ^= UInt64(byte)
            value = value &* 0x0000_0100_0000_01B3
        }
        return value
    }

    private static func stringValue(
        _ flag: String, _ arguments: [String]
    ) -> String? {
        guard let index = arguments.firstIndex(of: flag),
            arguments.indices.contains(index + 1)
        else { return nil }
        return arguments[index + 1]
    }

    private static func intValue(_ flag: String, _ arguments: [String]) -> Int? {
        guard let index = arguments.firstIndex(of: flag),
            arguments.indices.contains(index + 1)
        else { return nil }
        return Int(arguments[index + 1])
    }
}
