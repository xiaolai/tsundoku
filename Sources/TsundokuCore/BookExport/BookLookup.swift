import Foundation

/// Matches an archive row by identifier and source. The same identifier can
/// exist in both libraries; taking the other source's row would mix its title
/// or author into an export.
public enum BookLookup {
    public static func book(
        asin: String?, source: BookSource, in books: [Book]
    ) -> Book? {
        guard let asin else { return nil }
        let wanted = BookIdentity.normalize(asin)
        guard !wanted.isEmpty else { return nil }
        return books.first {
            $0.source == source
                && BookIdentity.normalize($0.asin) == wanted
        }
    }
}
