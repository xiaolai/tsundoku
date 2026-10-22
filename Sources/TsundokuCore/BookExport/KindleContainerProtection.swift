import Foundation

/// Minimal protection inspection for Kindle containers. AZW/AZW3 files are
/// PalmDB/MOBI files whose record 0 PalmDOC header carries an encryption
/// type; a nonzero value is DRM. KFX has no equivalent header here, so it is
/// unverifiable and callers fail closed.
public enum KindleContainerProtection {
    public enum Status: Sendable, Equatable {
        case clear
        case protected(reason: String)
        case unverified(reason: String)
    }

    public static func status(
        of url: URL, kind: OriginalKind
    ) -> Status {
        switch kind {
        case .azw:
            return mobiStatus(url)
        case .kfx:
            return .unverified(
                reason: "The KFX container's protection state could not be "
                    + "verified.")
        case .epub, .pdf:
            return .unverified(
                reason: "The file is not a Kindle container.")
        }
    }

    private static func mobiStatus(_ url: URL) -> Status {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return .unverified(reason: "The AZW header could not be read.")
        }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd(), size >= 78,
            (try? handle.seek(toOffset: 0)) != nil,
            let header = try? handle.read(upToCount: 78),
            header.count == 78
        else {
            return .unverified(reason: "The AZW header is too short.")
        }
        let recordCount = Int(bigEndian16(header, 76))
        guard recordCount > 0 else {
            return .unverified(reason: "The AZW has no PalmDB records.")
        }
        guard string(header, 60, 4) == "BOOK",
            string(header, 64, 4) == "MOBI"
        else {
            return .unverified(
                reason: "The AZW is not a MOBI PalmDB container.")
        }
        let recordInfoEnd = 78 + recordCount * 8
        guard UInt64(recordInfoEnd) <= size,
            (try? handle.seek(toOffset: 78)) != nil,
            let firstRecordInfo = try? handle.read(upToCount: 8),
            firstRecordInfo.count == 8
        else {
            return .unverified(reason: "The AZW record table is truncated.")
        }
        let record0 = Int(bigEndian32(firstRecordInfo, 0))
        guard record0 >= recordInfoEnd else {
            return .unverified(reason: "The AZW record table is invalid.")
        }
        // Record 0 ends at record 1's offset, or at EOF for a single record.
        let record0End: UInt64
        if recordCount > 1 {
            guard
                (try? handle.seek(toOffset: 78 + 8)) != nil,
                let secondRecordInfo = try? handle.read(upToCount: 8),
                secondRecordInfo.count == 8
            else {
                return .unverified(
                    reason: "The AZW record table is truncated.")
            }
            let record1 = Int(bigEndian32(secondRecordInfo, 0))
            guard record1 > record0, UInt64(record1) <= size else {
                return .unverified(
                    reason: "The AZW record table is invalid.")
            }
            record0End = UInt64(record1)
        } else {
            record0End = size
        }
        guard UInt64(record0) + 24 <= record0End,
            (try? handle.seek(toOffset: UInt64(record0))) != nil,
            let recordHeader = try? handle.read(upToCount: 24),
            recordHeader.count == 24,
            string(recordHeader, 16, 4) == "MOBI"
        else {
            return .unverified(
                reason: "The AZW MOBI header is missing or invalid.")
        }
        // The MOBI header declares its own length at record0 + 20; require
        // the whole declared header to stay inside record 0.
        let mobiLength = Int(bigEndian32(recordHeader, 20))
        guard mobiLength >= 24,
            UInt64(record0) + 16 + UInt64(mobiLength) <= record0End
        else {
            return .unverified(
                reason: "The AZW MOBI header is truncated.")
        }
        let compression = bigEndian16(recordHeader, 0)
        guard [1, 2, 17480].contains(compression) else {
            return .unverified(
                reason: "The AZW PalmDOC header could not be parsed.")
        }
        let encryption = bigEndian16(recordHeader, 12)
        if encryption == 0 { return .clear }
        return .protected(
            reason: "The AZW declares encryption type \(encryption).")
    }

    private static func bigEndian16(_ data: Data, _ offset: Int) -> UInt16 {
        guard offset + 2 <= data.count else { return 0 }
        return (UInt16(data[offset]) << 8) | UInt16(data[offset + 1])
    }

    private static func bigEndian32(_ data: Data, _ offset: Int) -> UInt32 {
        guard offset + 4 <= data.count else { return 0 }
        return (UInt32(data[offset]) << 24)
            | (UInt32(data[offset + 1]) << 16)
            | (UInt32(data[offset + 2]) << 8)
            | UInt32(data[offset + 3])
    }

    private static func string(
        _ data: Data, _ offset: Int, _ length: Int
    ) -> String {
        guard offset + length <= data.count else { return "" }
        return String(
            decoding: data[offset..<(offset + length)], as: UTF8.self)
    }
}
