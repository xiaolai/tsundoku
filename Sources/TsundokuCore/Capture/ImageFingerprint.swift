import CoreGraphics

public enum ImageFingerprint {
    /// An average hash: 8×8 grayscale, one bit per pixel above the mean.
    /// It is cheap and stable enough to tell one visible page from another;
    /// it is not proof that a page turned, because two blank pages can match.
    /// A higher-resolution fingerprint for page verification. The 8×8 average
    /// hash can miss a small header/footer difference; this downsamples to
    /// 32×32 and folds the pixel values, so a page that differs only in a
    /// cropped margin still changes the mark.
    public static func detailHash(_ image: CGImage) -> UInt64 {
        let side = 32
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
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for pixel in pixels {
            hash ^= UInt64(pixel)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return hash
    }

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
