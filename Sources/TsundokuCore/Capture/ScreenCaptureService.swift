import CoreGraphics
import Foundation
import ScreenCaptureKit

public enum ScreenCaptureError: Error, CustomStringConvertible, Sendable {
    case invalidRect
    case noDisplay
    case timedOut
    case cancelled
    case failed(String)

    public var description: String {
        switch self {
        case .invalidRect:
            "The capture rectangle has no area."
        case .noDisplay:
            "No display fully contains the capture rectangle."
        case .timedOut:
            "The screenshot did not finish before its deadline."
        case .cancelled:
            "The screenshot was cancelled."
        case .failed(let message):
            "The screenshot failed: \(message)"
        }
    }
}

public protocol PageScreenCapturing: AnyObject {
    func image(
        rect: CGRect, isCancelled: @Sendable () -> Bool
    ) throws -> CGImage
}

/// Display-filter capture with a deadline and cancellation. A window that
/// straddles two displays is refused rather than captured from the first one.
public final class DisplayScreenCapture: PageScreenCapturing {
    private let timeout: TimeInterval

    public init(timeout: TimeInterval = 6) {
        self.timeout = timeout
    }

    public func image(
        rect: CGRect, isCancelled: @Sendable () -> Bool
    ) throws -> CGImage {
        guard rect.width > 0, rect.height > 0 else {
            throw ScreenCaptureError.invalidRect
        }
        let semaphore = DispatchSemaphore(value: 0)
        let box = ResultBox()
        let task = Task.detached {
            do {
                let content = try await SCShareableContent
                    .excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard
                    let display = content.displays.first(where: {
                        $0.frame.contains(rect)
                    })
                else {
                    throw ScreenCaptureError.noDisplay
                }
                let filter = SCContentFilter(
                    display: display, excludingApplications: [],
                    exceptingWindows: [])
                let configuration = SCStreamConfiguration()
                configuration.sourceRect = CGRect(
                    x: rect.minX - display.frame.minX,
                    y: rect.minY - display.frame.minY,
                    width: rect.width, height: rect.height)
                configuration.width = Int(rect.width)
                configuration.height = Int(rect.height)
                configuration.captureResolution = .best
                configuration.scalesToFit = false
                configuration.showsCursor = false
                let image = try await SCScreenshotManager.captureImage(
                    contentFilter: filter, configuration: configuration)
                box.set(.success(image))
            } catch {
                box.set(.failure(error))
            }
            semaphore.signal()
        }

        // A monotonic deadline: a wall-clock adjustment during a stalled
        // screenshot must not extend it.
        let deadline = DispatchTime.now()
            + .milliseconds(Int((timeout * 1000).rounded()))
        while semaphore.wait(timeout: .now() + 0.1) == .timedOut {
            if isCancelled() {
                task.cancel()
                throw ScreenCaptureError.cancelled
            }
            if DispatchTime.now() >= deadline {
                task.cancel()
                throw ScreenCaptureError.timedOut
            }
        }
        guard let result = box.value else {
            throw ScreenCaptureError.failed("the capture did not finish")
        }
        return try result.get()
    }
}

private final class ResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Result<CGImage, Error>?

    func set(_ result: Result<CGImage, Error>) {
        lock.lock()
        stored = result
        lock.unlock()
    }

    var value: Result<CGImage, Error>? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}
