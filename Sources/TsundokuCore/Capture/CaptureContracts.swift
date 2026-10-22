import CoreGraphics
import Foundation

/// A cancellation source the engine and session can both observe without
/// sharing the UI's concrete flag.
public protocol CancellationChecking: Sendable {
    var isSet: Bool { get }
}

public struct ClosureCancellation: CancellationChecking, Sendable {
    private let closure: @Sendable () -> Bool

    public init(_ closure: @escaping @Sendable () -> Bool) {
        self.closure = closure
    }

    public var isSet: Bool { closure() }
}

public enum IdentityConfidence: Sendable, Equatable {
    case exact(String)
    case titleOnly(String)
    case unknown
}

public struct ObservedIdentity: Sendable, Equatable {
    public let title: String
    public let confidence: IdentityConfidence

    public init(title: String, confidence: IdentityConfidence) {
        self.title = title
        self.confidence = confidence
    }

    public var displayTitle: String {
        title.isEmpty ? "Unknown book" : title
    }
}

public struct CaptureSubject: Sendable {
    public let book: Book?
    public let kind: ReaderKind

    public init(book: Book?, kind: ReaderKind) {
        self.book = book
        self.kind = kind
    }
}

public struct CaptureCapabilities: Sendable {
    public let paginatedNavigation: Bool
    public let endOfBookDetection: Bool
    public let textLayer: Bool
    public let ocrFallback: Bool

    public init(
        paginatedNavigation: Bool, endOfBookDetection: Bool,
        textLayer: Bool, ocrFallback: Bool
    ) {
        self.paginatedNavigation = paginatedNavigation
        self.endOfBookDetection = endOfBookDetection
        self.textLayer = textLayer
        self.ocrFallback = ocrFallback
    }
}

public enum CaptureLayout: Sendable, Equatable {
    case reflowable
    case fixed
    case scrolling
}

public enum CaptureNavigation: Sendable, Equatable {
    case automatic
    case none
}

public enum CaptureEndDetection: Sendable, Equatable {
    case positive
    case none
}

public struct CaptureMode: Sendable, Equatable {
    public let layout: CaptureLayout
    public let navigation: CaptureNavigation
    public let endDetection: CaptureEndDetection

    public init(
        layout: CaptureLayout, navigation: CaptureNavigation,
        endDetection: CaptureEndDetection
    ) {
        self.layout = layout
        self.navigation = navigation
        self.endDetection = endDetection
    }
}

public struct PageLocation: Sendable, Equatable {
    public let pageNumber: Int?
    public let pageCount: Int?

    public init(pageNumber: Int?, pageCount: Int?) {
        self.pageNumber = pageNumber
        self.pageCount = pageCount
    }
}

/// A cheap fingerprint of a visible page. Equal marks are ambiguous, not proof
/// that no turn happened: two distinct blank pages can be identical.
public struct PageMark: Sendable, Equatable {
    public let imageHash: UInt64
    public let text: String

    public init(imageHash: UInt64, text: String) {
        self.imageHash = imageHash
        self.text = text
    }
}

public struct PageSnapshot: Sendable {
    public let identity: ObservedIdentity
    public let image: CGImage
    public let text: String?
    public let textSource: ReaderTextSource?
    public let pageNumber: Int?
    public let pageCount: Int?
    public let location: PageLocation?
    public let isEndOfBook: Bool
    public let cropRect: CGRect
    public let pixelSize: CGSize
    public let mark: PageMark
    public let calibration: PageFrameCalibration?
    /// The AX frame of the page's text element, when the reader exposes one.
    /// The engine records it as the layout signature; a reflow that moves the
    /// text column invalidates the run.
    public let textFrame: CGRect?

    public init(
        identity: ObservedIdentity, image: CGImage, text: String?,
        textSource: ReaderTextSource?, pageNumber: Int?,
        pageCount: Int?, location: PageLocation?, isEndOfBook: Bool,
        cropRect: CGRect, pixelSize: CGSize, mark: PageMark,
        calibration: PageFrameCalibration? = nil, textFrame: CGRect? = nil
    ) {
        self.identity = identity
        self.image = image
        self.text = text
        self.textSource = textSource
        self.pageNumber = pageNumber
        self.pageCount = pageCount
        self.location = location
        self.isEndOfBook = isEndOfBook
        self.cropRect = cropRect
        self.pixelSize = pixelSize
        self.mark = mark
        self.calibration = calibration
        self.textFrame = textFrame
    }
}

public struct TurnRecord: Sendable, Equatable {
    public let attempted: Bool
    public let posted: Bool
    public let observed: Bool
    public let terminal: Bool
    public let unresolved: Bool

    public init(
        attempted: Bool, posted: Bool, observed: Bool, terminal: Bool,
        unresolved: Bool
    ) {
        self.attempted = attempted
        self.posted = posted
        self.observed = observed
        self.terminal = terminal
        self.unresolved = unresolved
    }
}

public enum PageTransition: Sendable {
    case turned(PageSnapshot, TurnRecord)
    case endOfBook(TurnRecord)
    case noTurn(TurnRecord, reason: String)
}

public struct RestoreReport: Sendable {
    public let opening: PageLocation?
    public let final: PageLocation?
    public let attempted: Int
    public let posted: Int
    public let observed: Int
    public let terminal: Int
    public let unresolved: Int
    public let exact: Bool
    public let reason: String?

    public init(
        opening: PageLocation?, final: PageLocation?, attempted: Int,
        posted: Int, observed: Int, terminal: Int, unresolved: Int,
        exact: Bool, reason: String?
    ) {
        self.opening = opening
        self.final = final
        self.attempted = attempted
        self.posted = posted
        self.observed = observed
        self.terminal = terminal
        self.unresolved = unresolved
        self.exact = exact
        self.reason = reason
    }
}

public enum Termination: Sendable, Equatable {
    case endOfBook
    case pageLimit
    case cancelled
    case safetyCap
    case failed(String)
}

public enum ReaderCaptureError: Error, CustomStringConvertible, Sendable {
    case notTrusted(ReaderKind)
    case notRunning(ReaderKind)
    case noWindow(ReaderKind)
    case notReading(ReaderKind, state: String)
    case wrongBook(expected: String, observed: String)
    case identityChanged(expected: String, observed: String)
    case pageDidNotTurn(ReaderKind, reason: String)
    case captureFailed(ReaderKind, reason: String)
    case unsupported(ReaderKind, reason: String)
    case screenLocked
    case cancelled
    case cancelledWithWarning(String)

    public var description: String {
        switch self {
        case .notTrusted(let kind):
            "\(kind.displayName): Accessibility permission is not granted."
        case .notRunning(let kind):
            "\(kind.displayName) is not running."
        case .noWindow(let kind):
            "\(kind.displayName) has no reader window."
        case .notReading(let kind, let state):
            "\(kind.displayName) is showing \(state), not a reading page."
        case .wrongBook(let expected, let observed):
            "The selected book is \(expected), but the reader shows \(observed)."
        case .identityChanged(let expected, let observed):
            "The reader changed from \(expected) to \(observed) during capture."
        case .pageDidNotTurn(let kind, let reason):
            "\(kind.displayName): \(reason)"
        case .captureFailed(let kind, let reason):
            "\(kind.displayName) capture failed: \(reason)"
        case .unsupported(let kind, let reason):
            "\(kind.displayName): \(reason)"
        case .screenLocked:
            "The screen is locked; capture cannot continue."
        case .cancelled:
            "Cancelled."
        case .cancelledWithWarning(let warning):
            "Cancelled. \(warning)"
        }
    }
}

public protocol ReaderCaptureAdapter: Sendable {
    var kind: ReaderKind { get }
    func capabilities(for subject: CaptureSubject) -> CaptureCapabilities
    func makeSession(
        for subject: CaptureSubject,
        cancellation: any CancellationChecking
    ) throws -> any ReaderCaptureSession
}

/// Stateful and non-Sendable. Create, drive and restore it inside one capture
/// executor; do not return it from a `Task.detached`.
public protocol ReaderCaptureSession: AnyObject {
    var identity: ObservedIdentity { get }
    var mode: CaptureMode { get }
    func snapshot() throws -> PageSnapshot
    func advance(after mark: PageMark) throws -> PageTransition
    func restore() -> RestoreReport
    var pageSetupOutcome: PageSetupOutcome? { get }
}

public extension ReaderCaptureSession {
    var pageSetupOutcome: PageSetupOutcome? { nil }
}
