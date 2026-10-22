import Foundation

/// Classifies an EPUB `META-INF/encryption.xml`. The standard font
/// obfuscation algorithms are not DRM; any other or unknown algorithm is
/// treated as protected, and an unreadable declaration fails closed.
public enum EPUBEncryption {
    static let xmlEncryptionNamespace =
        "http://www.w3.org/2001/04/xmlenc#"

    public static let fontObfuscationAlgorithms: Set<String> = [
        "http://www.idpf.org/2008/embedding",
        "http://ns.adobe.com/pdf/enc#RC",
    ]

    /// Classify `META-INF/encryption.xml` in an unpacked EPUB directory.
    /// Exactly the standard spelling is accepted; a case-variant duplicate is
    /// ambiguous and fails closed rather than letting a harmless declaration
    /// mask a protected one.
    public static func status(unpackedEPUB url: URL) -> BooksDRMStatus {
        let manager = FileManager.default
        let meta = url.appendingPathComponent("META-INF")
        guard EPUBPackage.contains(meta, in: url) else {
            return .unknown(
                reason: "META-INF points outside the book; refusing to call "
                    + "it an original.")
        }
        var isDirectory: ObjCBool = false
        if !manager.fileExists(
            atPath: meta.path, isDirectory: &isDirectory)
        {
            do {
                _ = try manager.attributesOfItem(atPath: meta.path)
                return .unknown(
                    reason: "META-INF is not a readable directory.")
            } catch let error as NSError {
                if error.code == NSFileReadNoSuchFileError { return .clear }
                return .unknown(
                    reason: "META-INF could not be inspected: "
                        + error.localizedDescription)
            }
        }
        guard isDirectory.boolValue else {
            return .unknown(reason: "META-INF is not a directory.")
        }
        let entries: [String]
        do {
            entries = try manager.contentsOfDirectory(atPath: meta.path)
        } catch {
            return .unknown(
                reason: "META-INF could not be listed: "
                    + error.localizedDescription)
        }
        let candidates = entries.filter {
            $0.lowercased() == "encryption.xml"
        }
        guard !candidates.isEmpty else { return .clear }
        guard candidates.count == 1, candidates[0] == "encryption.xml" else {
            return .unknown(
                reason: "The EPUB has ambiguous encryption declarations.")
        }
        let encryption = meta.appendingPathComponent("encryption.xml")
        guard EPUBPackage.contains(encryption, in: url) else {
            return .unknown(
                reason: "encryption.xml points outside the book.")
        }
        guard
            let data = BoundedFileReader.read(
                encryption, limit: 1_000_000)
        else {
            return .unknown(
                reason: "The EPUB encryption declaration is unreadable "
                    + "or too large.")
        }
        return status(encryptionXML: data)
    }

    public static func status(encryptionXML data: Data) -> BooksDRMStatus {
        let parser = XMLParser(data: data)
        let delegate = EncryptionXMLDelegate()
        parser.delegate = delegate
        // Without namespace processing XMLParser reports no namespaceURI, so
        // every element would look foreign and one encrypted element would
        // silently make the whole declaration unreadable.
        parser.shouldProcessNamespaces = true
        guard parser.parse() else {
            return .unknown(
                reason: "The EPUB encryption declaration is malformed.")
        }
        guard !delegate.missingMethod, delegate.stack.isEmpty,
            !delegate.algorithms.isEmpty
        else {
            return .unknown(
                reason: "An EPUB EncryptedData has no algorithm.")
        }
        let unexpected = delegate.algorithms.filter {
            !fontObfuscationAlgorithms.contains($0)
        }
        if unexpected.isEmpty {
            // Recognized font obfuscation, not content encryption.
            return .clear
        }
        return .protected(
            reason: "The EPUB declares encryption algorithm "
                + "\(unexpected[0]).")
    }
}

private final class EncryptionXMLDelegate: NSObject, XMLParserDelegate {
    var algorithms: [String] = []
    var stack: [Bool] = []
    var missingMethod = false

    func parser(
        _ parser: XMLParser, didStartElement elementName: String,
        namespaceURI: String?, qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        guard namespaceURI == EPUBEncryption.xmlEncryptionNamespace
        else { return }
        let local = localName(elementName)
        if local == "encrypteddata" {
            stack.append(false)
            return
        }
        guard local == "encryptionmethod" else { return }
        if !stack.isEmpty { stack[stack.count - 1] = true }
        // Only the unqualified XML Encryption Algorithm attribute counts; a
        // prefixed decoy:Algorithm must not shadow it.
        algorithms.append(attributeDict["Algorithm"] ?? "")
    }

    func parser(
        _ parser: XMLParser, didEndElement elementName: String,
        namespaceURI: String?, qualifiedName qName: String?
    ) {
        guard namespaceURI == EPUBEncryption.xmlEncryptionNamespace,
            localName(elementName) == "encrypteddata"
        else { return }
        if let hasMethod = stack.popLast(), !hasMethod {
            missingMethod = true
        }
    }

    private func localName(_ name: String) -> String {
        guard let colon = name.lastIndex(of: ":") else {
            return name.lowercased()
        }
        return String(name[name.index(after: colon)...]).lowercased()
    }
}
