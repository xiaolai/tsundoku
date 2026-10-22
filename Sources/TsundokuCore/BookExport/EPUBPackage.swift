import Foundation

public enum EPUBError: Error, CustomStringConvertible, Sendable {
    case missingContainer(URL)
    case missingRootfile(URL)
    case unreadableOPF(URL)
    case malformedXML(String)
    case unsafePath(String)

    public var description: String {
        switch self {
        case .missingContainer(let url):
            "The EPUB has no META-INF/container.xml at \(url.path)."
        case .missingRootfile(let url):
            "The EPUB has no package document at \(url.path)."
        case .unreadableOPF(let url):
            "The EPUB package document is unreadable: \(url.path)."
        case .malformedXML(let reason):
            "The EPUB package document is malformed: \(reason)."
        case .unsafePath(let path):
            "The EPUB package document points outside the book: \(path)."
        }
    }
}

public struct EPUBManifestItem: Sendable, Equatable {
    public let id: String
    public let href: String
    public let mediaType: String?
    public let properties: String?

    public init(id: String, href: String, mediaType: String?, properties: String?) {
        self.id = id
        self.href = href
        self.mediaType = mediaType
        self.properties = properties
    }
}

/// The parts of an EPUB package document the export bundle needs. Parsed
/// read-only; nothing here writes to the book or extracts its text.
public struct EPUBPackage: Sendable, Equatable {
    public let rootURL: URL
    public let opfURL: URL
    public let title: String?
    public let creators: [String]
    public let publisher: String?
    public let publishedDate: String?
    public let language: String?
    public let identifier: String?
    public let identifierScheme: String?
    public let coverImageURL: URL?
    public let items: [EPUBManifestItem]

    public init(
        rootURL: URL,
        opfURL: URL,
        title: String?,
        creators: [String],
        publisher: String?,
        publishedDate: String?,
        language: String?,
        identifier: String?,
        identifierScheme: String?,
        coverImageURL: URL?,
        items: [EPUBManifestItem]
    ) {
        self.rootURL = rootURL
        self.opfURL = opfURL
        self.title = title
        self.creators = creators
        self.publisher = publisher
        self.publishedDate = publishedDate
        self.language = language
        self.identifier = identifier
        self.identifierScheme = identifierScheme
        self.coverImageURL = coverImageURL
        self.items = items
    }

    /// Parse an unpacked EPUB directory: read `META-INF/container.xml` for the
    /// package path, then the package document itself.
    public static func load(fromEPUBDirectory root: URL) throws -> EPUBPackage {
        let root = root.standardizedFileURL
        let container = root.appendingPathComponent("META-INF/container.xml")
        guard contains(container, in: root) else {
            throw EPUBError.unsafePath(container.path)
        }
        let opfURL: URL
        if FileManager.default.fileExists(atPath: container.path) {
            guard let data = try? Data(contentsOf: container) else {
                throw EPUBError.missingContainer(container)
            }
            let parser = XMLParser(data: data)
            let delegate = ContainerXMLDelegate()
            parser.delegate = delegate
            guard parser.parse() else {
                throw EPUBError.malformedXML(
                    parser.parserError?.localizedDescription ?? "container.xml")
            }
            guard let path = delegate.rootfile, !path.isEmpty else {
                throw EPUBError.missingRootfile(container)
            }
            opfURL = try resolve(path, relativeTo: root, root: root)
        } else if let found = firstPackageDocument(in: root) {
            opfURL = found
        } else {
            throw EPUBError.missingContainer(container)
        }
        guard let data = try? Data(contentsOf: opfURL) else {
            throw EPUBError.unreadableOPF(opfURL)
        }
        return try parse(opfData: data, opfURL: opfURL, rootURL: root)
    }

    /// Parse package-document bytes. `opfURL` and `rootURL` are used to resolve
    /// relative cover paths and to reject paths outside the book.
    public static func parse(
        opfData: Data, opfURL: URL, rootURL: URL
    ) throws -> EPUBPackage {
        let parser = XMLParser(data: opfData)
        let delegate = OPFXMLDelegate()
        parser.delegate = delegate
        guard parser.parse() else {
            throw EPUBError.malformedXML(
                parser.parserError?.localizedDescription ?? "package document")
        }
        let base = opfURL.deletingLastPathComponent()
        let coverURL = try coverURL(
            delegate: delegate, base: base, root: rootURL)
        let identifier = delegate.identifier
        return EPUBPackage(
            rootURL: rootURL.standardizedFileURL,
            opfURL: opfURL.standardizedFileURL,
            title: delegate.title,
            creators: delegate.creators,
            publisher: delegate.publisher,
            publishedDate: delegate.publishedDate,
            language: delegate.language,
            identifier: identifier,
            identifierScheme: delegate.identifierScheme,
            coverImageURL: coverURL,
            items: delegate.items)
    }

    private static func coverURL(
        delegate: OPFXMLDelegate, base: URL, root: URL
    ) throws -> URL? {
        var candidates: [EPUBManifestItem] = []
        if let coverID = delegate.metaCoverID {
            candidates.append(contentsOf: delegate.items.filter {
                $0.id.caseInsensitiveCompare(coverID) == .orderedSame
            })
        }
        candidates.append(contentsOf: delegate.items.filter { item in
            let properties = item.properties?.lowercased() ?? ""
            return properties.split(separator: " ").contains("cover-image")
        })
        candidates.append(contentsOf: delegate.items.filter { item in
            let mediaType = item.mediaType?.lowercased() ?? ""
            guard mediaType.hasPrefix("image/") else { return false }
            let name = (item.href as NSString).lastPathComponent.lowercased()
            return name == "cover.jpg" || name == "cover.jpeg"
                || name == "cover.png"
        })
        for item in candidates {
            let url = try resolve(item.href, relativeTo: base, root: root)
            if FileManager.default.fileExists(atPath: url.path) {
                return url
            }
        }
        return conventionalCover(in: root)
    }

    private static func conventionalCover(in root: URL) -> URL? {
        let directories = [
            root.appendingPathComponent("OEBPS/images"),
            root.appendingPathComponent("OEBPS/Images"),
            root.appendingPathComponent("OEBPS"),
            root.appendingPathComponent("Images"),
            root,
        ]
        let names: Set<String> = ["cover.jpg", "cover.jpeg", "cover.png"]
        for directory in directories {
            guard
                let entries = try? FileManager.default.contentsOfDirectory(
                    at: directory, includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles])
            else { continue }
            let matches = entries
                .filter { names.contains($0.lastPathComponent.lowercased()) }
                .filter { contains($0, in: root) }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
            if let first = matches.first { return first }
        }
        return nil
    }

    private static func firstPackageDocument(in root: URL) -> URL? {
        guard
            let enumerator = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles])
        else { return nil }
        var found: [URL] = []
        for case let url as URL in enumerator {
            if url.pathExtension.lowercased() == "opf",
                contains(url, in: root)
            {
                found.append(url)
            }
        }
        return found.sorted { $0.path < $1.path }.first
    }

    /// Resolve a relative href and refuse anything that escapes the EPUB root.
    static func resolve(
        _ href: String, relativeTo base: URL, root: URL
    ) throws -> URL {
        let decoded = href.removingPercentEncoding ?? href
        guard !decoded.hasPrefix("/") else {
            throw EPUBError.unsafePath(href)
        }
        let url = URL(fileURLWithPath: decoded, relativeTo: base)
            .standardizedFileURL
        guard contains(url, in: root) else {
            throw EPUBError.unsafePath(href)
        }
        return url
    }

    /// Lexical containment catches `..`; resolving symlinks catches a link
    /// inside the book that points at a file outside it. The original URL is
    /// returned so the caller keeps the book's own path, not the resolved one.
    static func contains(_ url: URL, in root: URL) -> Bool {
        let rootPath = root.resolvingSymlinksInPath()
            .standardizedFileURL.path
        let targetPath = url.resolvingSymlinksInPath()
            .standardizedFileURL.path
        return targetPath == rootPath
            || targetPath.hasPrefix(rootPath + "/")
    }
}

// MARK: - XML delegates

private func localName(_ name: String) -> String {
    guard let colon = name.lastIndex(of: ":") else { return name.lowercased() }
    return String(name[name.index(after: colon)...]).lowercased()
}

private func attribute(
    _ attributes: [String: String], _ name: String
) -> String? {
    for (key, value) in attributes where localName(key) == name.lowercased() {
        return value
    }
    return nil
}

private final class ContainerXMLDelegate: NSObject, XMLParserDelegate {
    var rootfile: String?

    func parser(
        _ parser: XMLParser, didStartElement elementName: String,
        namespaceURI: String?, qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        guard localName(elementName) == "rootfile", rootfile == nil
        else { return }
        if let path = attribute(attributeDict, "full-path"), !path.isEmpty {
            rootfile = path
        }
    }
}

private final class OPFXMLDelegate: NSObject, XMLParserDelegate {
    var title: String?
    var creators: [String] = []
    var publisher: String?
    var publishedDate: String?
    var language: String?
    var identifier: String?
    var identifierScheme: String?
    var metaCoverID: String?
    var items: [EPUBManifestItem] = []

    private var inMetadata = false
    private var currentElement: String?
    private var currentScheme: String?
    private var buffer = ""

    func parser(
        _ parser: XMLParser, didStartElement elementName: String,
        namespaceURI: String?, qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        let local = localName(elementName)
        if local == "metadata" {
            inMetadata = true
            return
        }
        guard inMetadata else {
            if local == "item" {
                let id = attribute(attributeDict, "id") ?? ""
                let href = attribute(attributeDict, "href") ?? ""
                if !id.isEmpty, !href.isEmpty {
                    items.append(
                        EPUBManifestItem(
                            id: id, href: href,
                            mediaType: attribute(attributeDict, "media-type"),
                            properties: attribute(attributeDict, "properties")))
                }
            }
            return
        }
        switch local {
        case "meta":
            let name = attribute(attributeDict, "name")?.lowercased()
            if name == "cover",
                let content = attribute(attributeDict, "content"),
                !content.isEmpty
            {
                metaCoverID = content
            }
        case "title", "creator", "publisher", "date", "language",
            "identifier":
            currentElement = local
            currentScheme = attribute(attributeDict, "scheme")
            buffer = ""
        case "item":
            let id = attribute(attributeDict, "id") ?? ""
            let href = attribute(attributeDict, "href") ?? ""
            if !id.isEmpty, !href.isEmpty {
                items.append(
                    EPUBManifestItem(
                        id: id, href: href,
                        mediaType: attribute(attributeDict, "media-type"),
                        properties: attribute(attributeDict, "properties")))
            }
        default:
            break
        }
    }

    func parser(
        _ parser: XMLParser, foundCharacters string: String
    ) {
        guard currentElement != nil else { return }
        buffer += string
    }

    func parser(
        _ parser: XMLParser, didEndElement elementName: String,
        namespaceURI: String?, qualifiedName qName: String?
    ) {
        let local = localName(elementName)
        if local == "metadata" {
            inMetadata = false
            return
        }
        guard inMetadata, let currentElement, local == currentElement else {
            return
        }
        let value = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        if !value.isEmpty {
            switch currentElement {
            case "title":
                if title == nil { title = value }
            case "creator":
                creators.append(value)
            case "publisher":
                if publisher == nil { publisher = value }
            case "date":
                if publishedDate == nil { publishedDate = value }
            case "language":
                if language == nil { language = value }
            case "identifier":
                let scheme = currentScheme?.uppercased()
                if identifier == nil
                    || (scheme == "ASIN" && identifierScheme != "ASIN")
                {
                    identifier = value
                    identifierScheme = scheme
                }
            default:
                break
            }
        }
        self.currentElement = nil
        self.currentScheme = nil
        buffer = ""
    }
}
