import CoreGraphics
import Foundation
import ImageIO

public struct SeamCandidate: Sendable, Equatable {
    public let leftPage: Int
    public let rightPage: Int
    public let tail: String
    public let head: String

    public init(leftPage: Int, rightPage: Int, tail: String, head: String) {
        self.leftPage = leftPage
        self.rightPage = rightPage
        self.tail = tail
        self.head = head
    }
}

public struct CaptureVerification: Sendable {
    public let structural: Bool
    public let requestedRange: Bool
    public let wholeBook: Bool
    public let faults: [String]
    public let seamCandidates: [SeamCandidate]

    public init(
        structural: Bool, requestedRange: Bool, wholeBook: Bool,
        faults: [String], seamCandidates: [SeamCandidate]
    ) {
        self.structural = structural
        self.requestedRange = requestedRange
        self.wholeBook = wholeBook
        self.faults = faults
        self.seamCandidates = seamCandidates
    }
}

public enum VerifierError: Error, CustomStringConvertible, Sendable {
    case unreadableManifest(String)
    case malformedManifest(String)

    public var description: String {
        switch self {
        case .unreadableManifest(let path):
            "Could not read the capture manifest at \(path)."
        case .malformedManifest(let reason):
            "The capture manifest is malformed: \(reason)"
        }
    }
}

/// Checks only what the files prove. A text seam is a candidate for a human to
/// review, not proof that a page is missing; index continuity cannot see a
/// missing prefix or a truncated suffix.
public enum CaptureVerifier {
    public static func verify(directory: URL) throws -> CaptureVerification {
        let manifestURL = directory.appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: manifestURL) else {
            throw VerifierError.unreadableManifest(manifestURL.path)
        }
        guard
            let manifest = try JSONSerialization.jsonObject(with: data)
                as? [String: Any]
        else {
            throw VerifierError.malformedManifest("not a JSON object")
        }
        guard let pages = manifest["pages"] as? [[String: Any]] else {
            throw VerifierError.malformedManifest("no pages array")
        }

        var faults: [String] = []
        if pages.isEmpty {
            faults.append("the manifest lists no pages")
        }
        let claimedCount = manifest["pageCount"] as? Int
        if let claimedCount, claimedCount != pages.count {
            faults.append(
                "manifest says \(claimedCount) pages but lists \(pages.count)")
        }
        var previousIndex = 0
        var texts: [(index: Int, text: String)] = []
        // Page text lives in text.jsonl; the manifest carries only metadata so
        // a running manifest does not grow quadratically.
        let recordedTexts = loadTexts(directory: directory)
        for (position, page) in pages.enumerated() {
            let index = page["page"] as? Int ?? position + 1
            if index != previousIndex + 1 {
                faults.append(
                    "page index \(index) follows \(previousIndex); "
                        + "the sequence is not contiguous")
            }
            previousIndex = index
            let file = page["file"] as? String ?? inferFile(index: index)
            let url = directory.appendingPathComponent("pages")
                .appendingPathComponent(file)
            guard FileManager.default.fileExists(atPath: url.path) else {
                faults.append("page \(index) is missing: \(file)")
                continue
            }
            guard
                let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                CGImageSourceGetCount(source) > 0,
                let decoded = CGImageSourceCreateImageAtIndex(
                    source, 0,
                    [kCGImageSourceShouldCacheImmediately: true]
                        as CFDictionary),
                decoded.width > 0, decoded.height > 0
            else {
                faults.append("page \(index) is not a readable image: \(file)")
                continue
            }
            let text =
                (page["text"] as? String) ?? recordedTexts[index] ?? ""
            if !text.isEmpty {
                texts.append((index, text))
            }
        }

        guard let pdfName = manifest["pdf"] as? String else {
            faults.append("the manifest does not name a published PDF")
            return CaptureVerification(
                structural: false, requestedRange: false, wholeBook: false,
                faults: faults, seamCandidates: seams(texts))
        }
        let pdfURL = directory.appendingPathComponent(pdfName)
        let coverPage = manifest["coverPage"] as? Bool ?? false
        // Pages the index appended after the book's own; they are part of the
        // document and must be expected, not treated as a count error.
        let indexPages = manifest["indexPages"] as? Int ?? 0
        let expectedPDFPages =
            pages.count + (coverPage ? 1 : 0) + indexPages
        guard
            FileManager.default.fileExists(atPath: pdfURL.path),
            let document = CGPDFDocument(pdfURL as CFURL),
            document.numberOfPages == expectedPDFPages
        else {
            faults.append(
                "the published PDF is missing or has the wrong page count "
                    + "(expected \(expectedPDFPages))")
            return CaptureVerification(
                structural: false, requestedRange: false, wholeBook: false,
                faults: faults, seamCandidates: seams(texts))
        }

        let termination = manifest["termination"] as? String ?? ""
        let startPage = manifest["startPage"] as? Int
        let structural = faults.isEmpty
        let requestedRange =
            structural
            && (termination == "endOfBook" || termination == "pageLimit")
        let wholeBook =
            structural && termination == "endOfBook" && startPage == 1
        return CaptureVerification(
            structural: structural, requestedRange: requestedRange,
            wholeBook: wholeBook, faults: faults,
            seamCandidates: seams(texts))
    }

    private static func loadTexts(directory: URL) -> [Int: String] {
        let url = directory.appendingPathComponent("text.jsonl")
        guard let content = try? String(contentsOf: url, encoding: .utf8)
        else { return [:] }
        var texts: [Int: String] = [:]
        for line in content.split(separator: "\n") {
            guard
                let object = try? JSONSerialization.jsonObject(
                    with: Data(line.utf8)) as? [String: Any],
                let index = object["page"] as? Int,
                let text = object["text"] as? String, !text.isEmpty
            else { continue }
            texts[index] = text
        }
        return texts
    }

    private static func inferFile(index: Int) -> String {
        String(format: "page-%04d.png", index)
    }

    private static func seams(
        _ texts: [(index: Int, text: String)]
    ) -> [SeamCandidate] {
        guard texts.count > 1 else { return [] }
        var candidates: [SeamCandidate] = []
        for (left, right) in zip(texts, texts.dropFirst()) {
            let tail = String(left.text.suffix(40))
            let head = String(right.text.prefix(40))
            guard let last = tail.last, let first = head.first else {
                continue
            }
            let openEnded =
                last.isLetter || last.isNumber
                || ",;:—–-".contains(last)
            let continuation =
                first.isLowercase || "’'”),;:".contains(first)
            if openEnded && continuation {
                candidates.append(
                    SeamCandidate(
                        leftPage: left.index, rightPage: right.index,
                        tail: tail, head: head))
            }
        }
        return candidates
    }
}
