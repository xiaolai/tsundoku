import Foundation

public enum AnnotationKindScope: String, CaseIterable, Identifiable, Sendable {
    case all = "All Kinds"
    case notes = "Notes"
    case highlights = "Highlights"
    case bookmarks = "Bookmarks"
    public var id: String { rawValue }
    public func matches(_ annotation: Annotation) -> Bool {
        switch self {
        case .all: true
        case .notes: annotation.kind == .note || annotation.personalNote != nil
        case .highlights:
            annotation.kind == .highlight
                || annotation.kind == .popularHighlight
        case .bookmarks: annotation.kind == .bookmark
        }
    }
}

public enum AnnotationSort: String, CaseIterable, Identifiable, Sendable {
    case newest = "Newest First"
    case oldest = "Oldest First"
    case book = "Book Title"
    case location = "Book Location"
    public var id: String { rawValue }
}

/// One contract for browsing and exact-result exports. No source I/O.
public struct AnnotationQuery: Sendable {
    public var source: BookSource?
    public var provenance: AnnotationProvenance? = .user
    public var bookID: String?
    public var kind: AnnotationKindScope = .all
    public var contentOnly = false
    public var search = ""
    public var sort: AnnotationSort = .newest

    public init() {}

    public func apply(to annotations: [Annotation], books: [Book] = [])
        -> [Annotation]
    {
        let catalog = Dictionary(
            books.map { ($0.asin, $0) }, uniquingKeysWith: { first, _ in first }
        )
        let needle = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let result = annotations.filter { item in
            if let source, item.bookSource != source { return false }
            if let provenance, item.provenance != provenance { return false }
            if let bookID, item.asin != bookID { return false }
            guard kind.matches(item), !contentOnly || item.hasContent else {
                return false
            }
            guard !needle.isEmpty else { return true }
            return [
                item.bookTitle, catalog[item.asin]?.title ?? "",
                catalog[item.asin]?.author ?? "",
                item.passageText ?? "", item.personalNote ?? "",
            ]
            .contains { $0.localizedStandardContains(needle) }
        }
        return result.sorted { left, right in
            switch sort {
            case .newest, .oldest:
                // Unknown dates always follow known dates in either direction.
                if (left.createdAt == nil) != (right.createdAt == nil) {
                    return left.createdAt != nil
                }
                if let l = left.createdAt, let r = right.createdAt, l != r {
                    return sort == .newest ? l > r : l < r
                }
            case .book, .location:
                let l =
                    left.bookTitle.isEmpty
                    ? catalog[left.asin]?.title ?? left.asin : left.bookTitle
                let r =
                    right.bookTitle.isEmpty
                    ? catalog[right.asin]?.title ?? right.asin : right.bookTitle
                if l != r {
                    return l.localizedStandardCompare(r) == .orderedAscending
                }
                if sort == .location, left.start != right.start {
                    return (left.start ?? "").localizedStandardCompare(
                        right.start ?? "") == .orderedAscending
                }
            }
            return left.id < right.id
        }
    }
}

public struct AnnotationSelection: Sendable {
    public var ids: Set<String> = []
    public var anchor: String?
    public var focusedID: String?
    public init() {}
    public mutating func select(
        _ id: String, in ordered: [String], extending: Bool = false,
        toggling: Bool = false
    ) {
        guard ordered.contains(id) else { return }
        focusedID = id
        if extending, let anchor, let start = ordered.firstIndex(of: anchor),
            let end = ordered.firstIndex(of: id)
        {
            let range = Set(ordered[min(start, end)...max(start, end)])
            ids = toggling ? ids.union(range) : range
        } else if toggling {
            if ids.contains(id) { ids.remove(id) } else { ids.insert(id) }
            anchor = id
        } else {
            ids = [id]
            anchor = id
        }
    }
    public mutating func move(
        by delta: Int, in ordered: [String], extending: Bool = false
    ) {
        guard !ordered.isEmpty else { return }
        let origin = focusedID.flatMap { ordered.firstIndex(of: $0) }
        let target =
            origin.map { max(0, min(ordered.count - 1, $0 + delta)) } ?? 0
        select(ordered[target], in: ordered, extending: extending)
    }
    public mutating func reconcile(with visible: [String]) {
        ids.formIntersection(visible)
        if let anchor, !visible.contains(anchor) { self.anchor = nil }
        if let focusedID, !visible.contains(focusedID) { self.focusedID = nil }
    }
}
