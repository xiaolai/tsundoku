// Platform-only helpers for the icon pipeline. No third-party code.
//
//   IconTools render <in.svg> <out.png> <size>
//       Rasterise an SVG at exactly <size> x <size> through WebKit.
//
//   IconTools inspect <in.png> [--min-opaque N] [--min-bbox-frac F] [--max-bbox-frac F]
//       Decode a PNG, measure its alpha bounds and mean ink colour, and exit
//       non-zero when a threshold is missed. Prints machine-readable key=value.
//
//   IconTools icns-info <in.icns>
//       Parse the .icns container directly and print every member with its
//       decoded PNG dimensions. Never uses `iconutil -c iconset`, which
//       corrupts the legacy small members on the way out (blue channel zeroed).
//
//   IconTools icns-write <out.icns> <16.png> <32.png> ... <1024.png>
//       Write the container with a PNG payload in every slot, bypassing
//       iconutil's RLE downconversion of the 16 and 32 slots.
//
//   IconTools icns-render <in.icns> <out.png> <size>
//       Decode the primary (largest) image at a requested size. ImageIO never
//       selects the small slots, so this checks the container decodes, not
//       what the 16/32 members contain — use icns-extract for those.
//
//   IconTools icns-extract <in.icns> <type> <out.png>
//       Write one member's payload out verbatim.
//
//   IconTools srgb <in.svg> --fill|--stroke
//       Print the first fill or stroke colour as srgb:R,G,B,A.
//
//   IconTools compare <a.png> <b.png> <max-mean-diff> [margin]
//       Mean absolute channel difference, alpha included.
//
// Why WebKit rather than sips/ImageIO: ImageIO's SVG reader silently drops
// feDropShadow, so the legacy tile loses the soft shadow the design declares.
// WebKit renders filters and keeps the alpha channel. The SVG is loaded as an
// <img> (not inline), which by specification cannot execute script, and
// JavaScript is disabled on the web view as well.

import Foundation
import AppKit
import ImageIO
import CoreGraphics
import WebKit
import UniformTypeIdentifiers

func die(_ message: String) -> Never {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    exit(1)
}

// MARK: - render

func render(svgPath: String, outPath: String, size: Int) {
    let inURL = URL(fileURLWithPath: svgPath)
    guard let data = try? Data(contentsOf: inURL) else { die("cannot read \(svgPath)") }
    let html = """
    <!doctype html><html><head><meta charset="utf-8"><style>
    html,body{margin:0;padding:0;background:transparent;overflow:hidden}
    img{display:block;width:\(size)px;height:\(size)px}
    </style></head><body><img src="data:image/svg+xml;base64,\(data.base64EncodedString())"></body></html>
    """

    let app = NSApplication.shared
    app.setActivationPolicy(.prohibited)

    let config = WKWebViewConfiguration()
    config.defaultWebpagePreferences.allowsContentJavaScript = false
    let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: size, height: size),
                            configuration: config)
    webView.setValue(false, forKey: "drawsBackground")
    webView.underPageBackgroundColor = .clear

    final class Nav: NSObject, WKNavigationDelegate {
        var finished = false
        var failure: String?
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finished = true }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            failure = error.localizedDescription; finished = true
        }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            failure = error.localizedDescription; finished = true
        }
    }
    let nav = Nav()
    webView.navigationDelegate = nav
    webView.loadHTMLString(html, baseURL: nil)

    let deadline = Date().addingTimeInterval(20)
    while !nav.finished && Date() < deadline {
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
    }
    if let failure = nav.failure { die("render failed for \(svgPath): \(failure)") }
    if !nav.finished { die("render timed out for \(svgPath)") }
    for _ in 0..<10 {
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
    }

    var snapshot: NSImage?
    var snapshotError: Error?
    let semaphore = DispatchSemaphore(value: 0)
    let snapshotConfig = WKSnapshotConfiguration()
    snapshotConfig.rect = NSRect(x: 0, y: 0, width: size, height: size)
    snapshotConfig.snapshotWidth = NSNumber(value: size)
    webView.takeSnapshot(with: snapshotConfig) { image, error in
        snapshot = image
        snapshotError = error
        semaphore.signal()
    }
    while semaphore.wait(timeout: .now() + 0.05) == .timedOut {
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
    }
    guard let image = snapshot else {
        die("snapshot failed for \(svgPath): \(snapshotError.map(String.init(describing:)) ?? "no image")")
    }
    // Normalise to exactly size x size, RGBA, sRGB. Drawing through an sRGB
    // CGContext keeps the colours byte-identical to the source; an AppKit
    // bitmap rep can silently convert through calibrated RGB.
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                              bytesPerRow: size * 4, space: cs,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        die("cannot allocate \(size)x\(size) context")
    }
    ctx.interpolationQuality = .high
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
    image.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
    NSGraphicsContext.restoreGraphicsState()
    guard let out = ctx.makeImage() else { die("cannot make image for \(outPath)") }
    guard out.width == size, out.height == size else { die("wrong output size for \(outPath)") }
    guard let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: outPath) as CFURL,
                                                     UTType.png.identifier as CFString, 1, nil) else {
        die("cannot create \(outPath)")
    }
    CGImageDestinationAddImage(dest, out, nil)
    guard CGImageDestinationFinalize(dest) else { die("cannot write \(outPath)") }
    print("rendered \(svgPath) -> \(outPath) \(size)x\(size)")
}

// MARK: - inspect

func loadRGBA(_ path: String) -> (w: Int, h: Int, px: [UInt8]) {
    guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
        die("cannot decode \(path)")
    }
    let w = cg.width, h = cg.height
    var data = [UInt8](repeating: 0, count: w * h * 4)
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    guard let ctx = CGContext(data: &data, width: w, height: h, bitsPerComponent: 8,
                              bytesPerRow: w * 4, space: cs,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        die("cannot create context for \(path)")
    }
    ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
    return (w, h, data)
}

func inspect(path: String, args: [String]) {
    let (w, h, data) = loadRGBA(path)
    var minOpaque = 0
    var minFrac = 0.0
    var maxFrac = 1.0
    var pixels: [(Int, Int)] = []
    var lighter: [(Int, Int, Int)] = []
    var darker: [(Int, Int, Int)] = []
    var differ: [(Int, Int, Int, Int, Int)] = []
    var i = 0

    func channels(_ x: Int, _ y: Int) -> (Int, Int, Int, Int) {
        guard x >= 0, x < w, y >= 0, y < h else { die("FAIL \(path): pixel \(x),\(y) outside \(w)x\(h)") }
        let o = (y * w + x) * 4
        return (Int(data[o]), Int(data[o + 1]), Int(data[o + 2]), Int(data[o + 3]))
    }
    func mean(_ x: Int, _ y: Int) -> Int {
        let c = channels(x, y)
        return (c.0 + c.1 + c.2) / 3
    }

    func ints(_ value: String, _ count: Int) -> [Int] {
        let parts = value.split(separator: ",").map(String.init)
        let numbers = parts.compactMap(Int.init)
        guard parts.count == count, numbers.count == count else {
            die("FAIL \(path): expected \(count) comma-separated integers, got \(value)")
        }
        return numbers
    }

    while i < args.count {
        switch args[i] {
        case "--min-opaque": minOpaque = Int(args[i + 1]) ?? 0; i += 2
        case "--min-bbox-frac": minFrac = Double(args[i + 1]) ?? 0; i += 2
        case "--max-bbox-frac": maxFrac = Double(args[i + 1]) ?? 1; i += 2
        case "--pixel":
            let p = ints(args[i + 1], 2); pixels.append((p[0], p[1])); i += 2
        case "--lighter":
            let p = ints(args[i + 1], 3); lighter.append((p[0], p[1], p[2])); i += 2
        case "--darker":
            let p = ints(args[i + 1], 3); darker.append((p[0], p[1], p[2])); i += 2
        case "--differ":
            let p = ints(args[i + 1], 5); differ.append((p[0], p[1], p[2], p[3], p[4])); i += 2
        default: die("FAIL \(path): unknown option \(args[i])")
        }
    }
    let threshold = 128
    var minX = w, minY = h, maxX = -1, maxY = -1
    var opaque = 0
    var sumR = 0.0, sumG = 0.0, sumB = 0.0
    for y in 0..<h {
        for x in 0..<w {
            let o = (y * w + x) * 4
            let a = Int(data[o + 3])
            if a > threshold {
                opaque += 1
                if x < minX { minX = x }; if x > maxX { maxX = x }
                if y < minY { minY = y }; if y > maxY { maxY = y }
                let af = Double(a) / 255.0
                sumR += Double(data[o]) / af
                sumG += Double(data[o + 1]) / af
                sumB += Double(data[o + 2]) / af
            }
        }
    }
    print("file=\(path)")
    print("width=\(w)")
    print("height=\(h)")
    print("opaque=\(opaque)")
    if opaque > 0 {
        let bw = maxX - minX + 1, bh = maxY - minY + 1
        print("bbox=\(minX),\(minY),\(maxX),\(maxY)")
        print("bbox_w=\(bw)")
        print("bbox_h=\(bh)")
        print(String(format: "bbox_frac_w=%.4f", Double(bw) / Double(w)))
        print(String(format: "bbox_frac_h=%.4f", Double(bh) / Double(h)))
        print(String(format: "mean_r=%.1f", sumR / Double(opaque)))
        print(String(format: "mean_g=%.1f", sumG / Double(opaque)))
        print(String(format: "mean_b=%.1f", sumB / Double(opaque)))
    }
    for (x, y) in pixels {
        let c = channels(x, y)
        print("pixel_\(x)_\(y)=\(c.0),\(c.1),\(c.2),\(c.3)")
    }
    for (x, y, n) in lighter where mean(x, y) < n {
        die("FAIL \(path): pixel \(x),\(y) mean \(mean(x, y)) is not >= \(n)")
    }
    for (x, y, n) in darker where mean(x, y) > n {
        die("FAIL \(path): pixel \(x),\(y) mean \(mean(x, y)) is not <= \(n)")
    }
    for (x1, y1, x2, y2, n) in differ where abs(mean(x1, y1) - mean(x2, y2)) < n {
        die("FAIL \(path): pixels \(x1),\(y1) and \(x2),\(y2) differ by \(abs(mean(x1, y1) - mean(x2, y2))) < \(n)")
    }
    guard opaque > 0 else { die("FAIL \(path): nothing opaque") }
    guard opaque >= minOpaque else { die("FAIL \(path): opaque=\(opaque) < \(minOpaque)") }
    let fw = Double(maxX - minX + 1) / Double(w)
    let fh = Double(maxY - minY + 1) / Double(h)
    guard fw >= minFrac, fh >= minFrac else {
        die(String(format: "FAIL %@: bbox fraction %.4fx%.4f < %.4f", path, fw, fh, minFrac))
    }
    guard fw <= maxFrac, fh <= maxFrac else {
        die(String(format: "FAIL %@: bbox fraction %.4fx%.4f > %.4f", path, fw, fh, maxFrac))
    }
}

// MARK: - icns-render

// Decode the .icns through ImageIO at a requested size. Note that ImageIO
// always resamples the primary (largest) member: a container with a red 16px
// member and a blue 1024px member decodes blue at 16px. This therefore proves
// the container is valid, not that a particular small slot is used.
func icnsRender(inPath: String, outPath: String, size: Int) {
    guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: inPath) as CFURL, nil) else {
        die("cannot open \(inPath)")
    }
    let options: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceThumbnailMaxPixelSize: size,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceShouldCacheImmediately: true,
    ]
    guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary) else {
        die("cannot decode \(inPath) at \(size)px")
    }
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                              bytesPerRow: size * 4, space: cs,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        die("cannot allocate \(size)x\(size) context")
    }
    ctx.interpolationQuality = .none
    ctx.draw(cg, in: CGRect(x: 0, y: 0, width: size, height: size))
    guard let out = ctx.makeImage(),
          let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: outPath) as CFURL,
                                                     UTType.png.identifier as CFString, 1, nil) else {
        die("cannot write \(outPath)")
    }
    CGImageDestinationAddImage(dest, out, nil)
    guard CGImageDestinationFinalize(dest) else { die("cannot write \(outPath)") }
    print("decoded \(inPath) -> \(outPath) \(cg.width)x\(cg.height) into \(size)x\(size)")
}

// MARK: - srgb

// Read the first fill or stroke colour out of an SVG and print it in the
// manifest's srgb:R,G,B,A form. The design package's SVGs are then the single
// source for both geometry and colour; the icon.json values cannot drift from
// the artwork they describe.
func srgb(path: String, attribute: String) {
    guard let text = try? String(contentsOf: URL(fileURLWithPath: path), encoding: .utf8) else {
        die("cannot read \(path)")
    }
    let pattern = "\(attribute)=\"#([0-9A-Fa-f]{6})\""
    guard let regex = try? NSRegularExpression(pattern: pattern),
          let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
          let range = Range(match.range(at: 1), in: text) else {
        die("FAIL \(path): no \(attribute)=\"#rrggbb\" found")
    }
    let hex = String(text[range])
    guard let value = Int(hex, radix: 16) else { die("FAIL \(path): bad colour \(hex)") }
    let r = Double((value >> 16) & 0xff) / 255.0
    let g = Double((value >> 8) & 0xff) / 255.0
    let b = Double(value & 0xff) / 255.0
    print(String(format: "srgb:%.5f,%.5f,%.5f,1.00000", r, g, b))
}

// MARK: - icns-extract

// Write one member's payload out verbatim. This is the only way to check the
// 16 and 32 slots: CGImageSourceCreateThumbnailAtIndex ignores them and
// resamples the largest image (verified with a container whose 16 member is
// red and 1024 member blue — a 16px request returned blue).
func icnsExtract(inPath: String, type: String, outPath: String) {
    guard let bytes = try? Data(contentsOf: URL(fileURLWithPath: inPath)).map({ $0 }) else {
        die("cannot read \(inPath)")
    }
    guard bytes.count >= 8, String(bytes: bytes[0..<4], encoding: .ascii) == "icns" else {
        die("FAIL \(inPath): not an icns container")
    }
    var offset = 8
    while offset + 8 <= bytes.count {
        let memberType = String(bytes: bytes[offset..<offset + 4], encoding: .ascii) ?? "????"
        let length = be32(bytes, offset + 4)
        guard length >= 8, offset + length <= bytes.count else {
            die("FAIL \(inPath): member \(memberType) has bad length \(length)")
        }
        if memberType == type {
            let payload = Data(bytes[(offset + 8)..<(offset + length)])
            guard payload.count > 24, payload[payload.startIndex] == 0x89,
                  payload[payload.startIndex + 1] == 0x50 else {
                die("FAIL \(inPath): member \(type) is not PNG")
            }
            do { try payload.write(to: URL(fileURLWithPath: outPath)) }
            catch { die("cannot write \(outPath): \(error)") }
            print("extracted \(type) from \(inPath) -> \(outPath) \(payload.count) bytes")
            return
        }
        offset += length
    }
    die("FAIL \(inPath): no \(type) member")
}

// MARK: - compare

// Compare two same-sized PNGs by mean absolute channel difference, alpha
// included. Used to prove a decoded .icns slot still carries the source art.
func compare(pathA: String, pathB: String, maxMean: Double, margin: Int) {
    let (w, h, a) = loadRGBA(pathA)
    let (w2, h2, b) = loadRGBA(pathB)
    guard w == w2, h == h2 else { die("FAIL \(pathA) is \(w)x\(h), \(pathB) is \(w2)x\(h2)") }
    var sum = 0.0
    var count = 0
    for y in margin..<(h - margin) {
        for x in margin..<(w - margin) {
            let o = (y * w + x) * 4
            for channel in 0..<4 {
                sum += Double(abs(Int(a[o + channel]) - Int(b[o + channel])))
            }
            count += 4
        }
    }
    let mean = count > 0 ? sum / Double(count) : .infinity
    print(String(format: "compare %@ vs %@ mean_abs=%.3f (limit %.3f)",
                 (pathA as NSString).lastPathComponent,
                 (pathB as NSString).lastPathComponent, mean, maxMean))
    guard mean <= maxMean else {
        die(String(format: "FAIL %@ and %@ differ by %.3f > %.3f", pathA, pathB, mean, maxMean))
    }
}

// MARK: - icns-write

// Write the container directly, with a PNG payload in every slot.
//
// iconutil converts the 16 and 32 slots to the legacy RLE types (ic04/ic05),
// which store 24-bit RGB plus a one-bit mask. That throws away the alpha
// anti-aliasing on the tile's corners and shadow: measured against the source
// renders, the native 16 slot moved by 17.6/255 mean and the 32 slot by
// 11.4/255, with visibly square corners. PNG members are valid for every size
// (icp4/icp5/icp6 on macOS 10.7+), so this keeps the artwork intact.
func icnsWrite(outPath: String, pngPaths: [String]) {
    // Slot types in the same order iconutil uses: @1x and @2x for each size.
    let types = ["icp4", "ic11", "icp5", "ic12", "ic07", "ic13", "ic08", "ic14", "ic09", "ic10"]
    let sizes = [16, 32, 32, 64, 128, 256, 256, 512, 512, 1024]
    guard pngPaths.count == types.count else {
        die("icns-write needs \(types.count) PNGs, got \(pngPaths.count)")
    }
    var elements = Data()
    for (index, path) in pngPaths.enumerated() {
        guard let payload = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            die("cannot read \(path)")
        }
        guard payload.count > 24, payload[payload.startIndex] == 0x89,
              payload[payload.startIndex + 1] == 0x50 else {
            die("\(path) is not a PNG")
        }
        let be = { (v: Int) -> [UInt8] in
            [UInt8((v >> 24) & 0xff), UInt8((v >> 16) & 0xff), UInt8((v >> 8) & 0xff), UInt8(v & 0xff)]
        }
        let width = Int(payload[payload.startIndex + 16]) << 24 |
                    Int(payload[payload.startIndex + 17]) << 16 |
                    Int(payload[payload.startIndex + 18]) << 8 |
                    Int(payload[payload.startIndex + 19])
        guard width == sizes[index] else {
            die("\(path) is \(width)px, expected \(sizes[index])px")
        }
        elements.append(contentsOf: Array(types[index].utf8))
        elements.append(contentsOf: be(payload.count + 8))
        elements.append(payload)
    }
    var out = Data("icns".utf8)
    let total = elements.count + 8
    out.append(contentsOf: [UInt8((total >> 24) & 0xff), UInt8((total >> 16) & 0xff),
                            UInt8((total >> 8) & 0xff), UInt8(total & 0xff)])
    out.append(elements)
    do { try out.write(to: URL(fileURLWithPath: outPath)) }
    catch { die("cannot write \(outPath): \(error)") }
    print("wrote \(outPath) \(out.count) bytes, \(types.count) PNG members")
}

// MARK: - icns-info

func be32(_ bytes: [UInt8], _ offset: Int) -> Int {
    (Int(bytes[offset]) << 24) | (Int(bytes[offset + 1]) << 16) |
    (Int(bytes[offset + 2]) << 8) | Int(bytes[offset + 3])
}

func icnsInfo(path: String) {
    guard let bytes = try? Data(contentsOf: URL(fileURLWithPath: path)).map({ $0 }) else {
        die("cannot read \(path)")
    }
    guard bytes.count >= 8, String(bytes: bytes[0..<4], encoding: .ascii) == "icns" else {
        die("FAIL \(path): not an icns container")
    }
    let total = be32(bytes, 4)
    guard total == bytes.count else { die("FAIL \(path): header length \(total) != file \(bytes.count)") }

    // iconutil stores 16 and 32 as the legacy RLE types (ic04/ic05), not PNG.
    // Their dimensions are fixed by the type; everything else is PNG here.
    let typeSize: [String: Int] = [
        "icp4": 16, "ic04": 16, "icp5": 32, "ic05": 32, "icp6": 64, "ic06": 64,
        "ic07": 128, "ic08": 256, "ic09": 512, "ic10": 1024,
        "ic11": 32, "ic12": 64, "ic13": 256, "ic14": 512,
        "icsb": 18, "icsB": 36,
    ]

    var offset = 8
    var iconMembers = 0
    var pngMembers = 0
    var sizes = Set<Int>()
    while offset + 8 <= bytes.count {
        let type = String(bytes: bytes[offset..<offset + 4], encoding: .ascii) ?? "????"
        let length = be32(bytes, offset + 4)
        guard length >= 8, offset + length <= bytes.count else {
            die("FAIL \(path): member \(type) has bad length \(length)")
        }
        let payload = offset + 8
        var dims = ""
        var kind = "raw"
        if length >= 24, bytes[payload] == 0x89, bytes[payload + 1] == 0x50,
           bytes[payload + 2] == 0x4E, bytes[payload + 3] == 0x47 {
            let pw = be32(bytes, payload + 16)
            let ph = be32(bytes, payload + 20)
            dims = " \(pw)x\(ph)"
            sizes.insert(pw)
            pngMembers += 1
            kind = "png"
        } else if let fixed = typeSize[type] {
            dims = " \(fixed)x\(fixed)"
            sizes.insert(fixed)
            kind = type.hasPrefix("ic0") ? "rle" : "png?"
        }
        let counted = type != "info" && type != "TOC "
        if counted { iconMembers += 1 }
        print("member \(type) \(length)\(dims) \(kind)")
        offset += length
    }
    guard offset == bytes.count else { die("FAIL \(path): trailing bytes after last member") }
    print("count=\(iconMembers)")
    print("png_members=\(pngMembers)")
    print("sizes=" + sizes.sorted().map(String.init).joined(separator: ","))
    // A valid iconset always yields a 10-member ladder. This pipeline writes
    // PNG into every slot, including 16 and 32, so demand ten PNG payloads.
    guard iconMembers >= 10 else { die("FAIL \(path): only \(iconMembers) icon members, expected at least 10") }
    guard pngMembers >= 10 else {
        die("FAIL \(path): only \(pngMembers) PNG members; every slot must be PNG (no RLE downconversion)")
    }
    for required in [16, 32, 64, 128, 256, 512, 1024] where !sizes.contains(required) {
        die("FAIL \(path): missing a \(required)px member")
    }
}

// MARK: - main

let args = CommandLine.arguments
guard args.count >= 2 else { die("usage: IconTools render|inspect|icns-info ...") }
switch args[1] {
case "render":
    guard args.count == 5, let size = Int(args[4]) else { die("usage: IconTools render <in.svg> <out.png> <size>") }
    render(svgPath: args[2], outPath: args[3], size: size)
case "inspect":
    guard args.count >= 3 else { die("usage: IconTools inspect <in.png> [thresholds]") }
    inspect(path: args[2], args: Array(args.dropFirst(3)))
case "icns-info":
    guard args.count == 3 else { die("usage: IconTools icns-info <in.icns>") }
    icnsInfo(path: args[2])
case "icns-render":
    guard args.count == 5, let size = Int(args[4]) else {
        die("usage: IconTools icns-render <in.icns> <out.png> <size>")
    }
    icnsRender(inPath: args[2], outPath: args[3], size: size)
case "icns-write":
    guard args.count >= 4 else {
        die("usage: IconTools icns-write <out.icns> <16.png> <32.png> ... <1024.png>")
    }
    icnsWrite(outPath: args[2], pngPaths: Array(args.dropFirst(3)))
case "srgb":
    guard args.count == 4, args[3] == "--fill" || args[3] == "--stroke" else {
        die("usage: IconTools srgb <in.svg> --fill|--stroke")
    }
    srgb(path: args[2], attribute: String(args[3].dropFirst(2)))
case "icns-extract":
    guard args.count == 5 else {
        die("usage: IconTools icns-extract <in.icns> <type> <out.png>")
    }
    icnsExtract(inPath: args[2], type: args[3], outPath: args[4])
case "compare":
    guard args.count >= 5 else {
        die("usage: IconTools compare <a.png> <b.png> <max-mean-diff> [margin]")
    }
    compare(pathA: args[2], pathB: args[3],
            maxMean: Double(args[4]) ?? 1.0,
            margin: args.count > 5 ? (Int(args[5]) ?? 0) : 0)
default:
    die("unknown subcommand \(args[1])")
}
