import CoreGraphics

public enum ImageFingerprint {
    /// An average hash: 8×8 grayscale, one bit per pixel above the mean.
    /// It is cheap and stable enough to tell one visible page from another;
    /// it is not proof that a page turned, because two blank pages can match.
    public static func averageHash(_ image: CGImage) -> UInt64 {
        let side = 8
        var pixels = [UInt8](repeating: 0, count: side * side)
        pixels.withUnsafeMutableBytes { buffer in
            guard
                let context = CGContext(
                    data: buffer.baseAddress, width: side, height: side,
                    bitsPerComponent: 8, bytesPerRow: side,
                    space: CGColorSpaceCreateDeviceGray(),
                    bitmapInfo: CGImageAlphaInfo.none.rawValue)
            else { return }
            context.interpolationQuality = .low
            context.draw(
                image,
                in: CGRect(x: 0, y: 0, width: side, height: side))
        }
        let total = pixels.reduce(0) { $0 + Int($1) }
        let mean = total / pixels.count
        var hash: UInt64 = 0
        for pixel in pixels {
            hash = (hash << 1) | (Int(pixel) > mean ? 1 : 0)
        }
        return hash
    }
}
