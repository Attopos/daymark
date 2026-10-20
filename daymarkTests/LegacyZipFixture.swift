import Foundation
@testable import Daymark_Journal

// Original v2 archive writer retained as a compatibility fixture.
// MARK: - Zip Archive

enum ZipArchive {
    struct Entry {
        let path: String
        let data: Data
    }

    struct IndexedEntry {
        let path: String
        let dataRange: Range<Int>
    }

    static func create(entries: [Entry]) -> Data {
        var archive = Data()
        var centralDirectory = Data()
        var entryCount: UInt16 = 0

        for entry in entries {
            let nameData = Data(entry.path.utf8)
            let crc = crc32Checksum(entry.data)
            let offset = UInt32(archive.count)
            let size = UInt32(entry.data.count)

            archive.appendUInt32(0x04034b50)
            archive.appendUInt16(20)
            archive.appendUInt16(0)
            archive.appendUInt16(0)
            archive.appendUInt16(0)
            archive.appendUInt16(0)
            archive.appendUInt32(crc)
            archive.appendUInt32(size)
            archive.appendUInt32(size)
            archive.appendUInt16(UInt16(nameData.count))
            archive.appendUInt16(0)
            archive.append(nameData)
            archive.append(entry.data)

            centralDirectory.appendUInt32(0x02014b50)
            centralDirectory.appendUInt16(20)
            centralDirectory.appendUInt16(20)
            centralDirectory.appendUInt16(0)
            centralDirectory.appendUInt16(0)
            centralDirectory.appendUInt16(0)
            centralDirectory.appendUInt16(0)
            centralDirectory.appendUInt32(crc)
            centralDirectory.appendUInt32(size)
            centralDirectory.appendUInt32(size)
            centralDirectory.appendUInt16(UInt16(nameData.count))
            centralDirectory.appendUInt16(0)
            centralDirectory.appendUInt16(0)
            centralDirectory.appendUInt16(0)
            centralDirectory.appendUInt16(0)
            centralDirectory.appendUInt32(0)
            centralDirectory.appendUInt32(offset)
            centralDirectory.append(nameData)

            entryCount += 1
        }

        let centralDirectoryOffset = UInt32(archive.count)
        archive.append(centralDirectory)

        archive.appendUInt32(0x06054b50)
        archive.appendUInt16(0)
        archive.appendUInt16(0)
        archive.appendUInt16(entryCount)
        archive.appendUInt16(entryCount)
        archive.appendUInt32(UInt32(centralDirectory.count))
        archive.appendUInt32(centralDirectoryOffset)
        archive.appendUInt16(0)

        return archive
    }

    static func index(from data: Data) throws -> [IndexedEntry] {
        guard data.count >= 22 else { throw BackupError.invalidArchive }

        var eocdOffset = data.count - 22
        while eocdOffset >= 0 {
            if data.readZipUInt32(at: eocdOffset) == 0x06054b50 { break }
            eocdOffset -= 1
        }
        guard eocdOffset >= 0 else { throw BackupError.invalidArchive }

        let entryCount = Int(data.readZipUInt16(at: eocdOffset + 10))
        let centralDirOffset = Int(data.readZipUInt32(at: eocdOffset + 16))

        var entries: [IndexedEntry] = []
        var offset = centralDirOffset

        for _ in 0..<entryCount {
            guard offset + 46 <= data.count,
                  data.readZipUInt32(at: offset) == 0x02014b50 else {
                throw BackupError.invalidArchive
            }

            // Only "stored" (method 0) entries are supported; re-zipped archives use deflate.
            guard data.readZipUInt16(at: offset + 10) == 0 else {
                throw BackupError.invalidArchive
            }
            let compressedSize = Int(data.readZipUInt32(at: offset + 20))
            let nameLength = Int(data.readZipUInt16(at: offset + 28))
            let extraLength = Int(data.readZipUInt16(at: offset + 30))
            let commentLength = Int(data.readZipUInt16(at: offset + 32))
            let localOffset = Int(data.readZipUInt32(at: offset + 42))

            let nameStart = offset + 46
            guard nameStart + nameLength <= data.count else { throw BackupError.invalidArchive }
            let name = String(data: data[nameStart..<nameStart + nameLength], encoding: .utf8) ?? ""

            guard localOffset + 30 <= data.count else { throw BackupError.invalidArchive }
            let localNameLength = Int(data.readZipUInt16(at: localOffset + 26))
            let localExtraLength = Int(data.readZipUInt16(at: localOffset + 28))
            let dataStart = localOffset + 30 + localNameLength + localExtraLength
            guard dataStart + compressedSize <= data.count else { throw BackupError.invalidArchive }

            entries.append(
                IndexedEntry(
                    path: name,
                    dataRange: dataStart..<(dataStart + compressedSize)
                )
            )
            offset = nameStart + nameLength + extraLength + commentLength
        }

        return entries
    }

    static func read(from data: Data) throws -> [Entry] {
        try index(from: data).map {
            Entry(path: $0.path, data: data.subdata(in: $0.dataRange))
        }
    }

    private static let crc32Table: [UInt32] = (0..<256).map { i in
        var c = UInt32(i)
        for _ in 0..<8 { c = (c & 1) != 0 ? (0xEDB88320 ^ (c >> 1)) : (c >> 1) }
        return c
    }

    private static func crc32Checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFFFFFF
        for byte in data { crc = crc32Table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8) }
        return crc ^ 0xFFFFFFFF
    }
}

private extension Data {
    mutating func appendUInt16(_ value: UInt16) {
        var v = value.littleEndian
        append(Data(bytes: &v, count: 2))
    }

    mutating func appendUInt32(_ value: UInt32) {
        var v = value.littleEndian
        append(Data(bytes: &v, count: 4))
    }

    func readZipUInt16(at offset: Int) -> UInt16 {
        UInt16(self[offset]) | (UInt16(self[offset + 1]) << 8)
    }

    func readZipUInt32(at offset: Int) -> UInt32 {
        UInt32(self[offset]) | (UInt32(self[offset + 1]) << 8) |
        (UInt32(self[offset + 2]) << 16) | (UInt32(self[offset + 3]) << 24)
    }
}
