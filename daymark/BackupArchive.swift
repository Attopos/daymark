import Foundation
import CryptoKit
import ImageIO
import UniformTypeIdentifiers
import ZIPFoundation

nonisolated enum BackupCalendar {
    static func dayKey(for date: Date, calendar: Calendar = .current) -> String {
        let calendar = gregorianCalendar(in: calendar.timeZone)
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    static func restoredDay(_ entry: DaymarkBackupEntry, calendar: Calendar = .current) throws -> Date {
        let calendar = gregorianCalendar(in: calendar.timeZone)
        var sourceCalendar = calendar
        if let timezone = entry.timezone, let zone = TimeZone(identifier: timezone) { sourceCalendar.timeZone = zone }
        let key = entry.dayKey ?? dayKey(for: entry.day, calendar: sourceCalendar)
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3, parts[0] > 0, parts[0] < 2100,
              let date = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])),
              dayKey(for: date, calendar: calendar) == key else { throw BackupError.invalidEntriesJSON }
        if entry.dayKey != nil {
            // A day key may cross time-zone boundaries, but cannot move the
            // stored date by years (as an unidentified old display calendar
            // could). Refuse ambiguous keys rather than restoring a wrong day.
            guard abs(date.timeIntervalSince(entry.day)) < 3 * 24 * 60 * 60 else {
                throw BackupError.invalidEntriesJSON
            }
        }
        return calendar.startOfDay(for: date)
    }

    private static func gregorianCalendar(in timeZone: TimeZone) -> Calendar {
        // Archive keys describe civil dates, independently of the system's
        // display calendar (for example Buddhist years or Chinese year cycles).
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }
}

/// A serial worker keeps ZIP I/O and checksums off the UI actor. Only one
/// original is supplied at a time; the complete archive never lives in RAM.
actor BackupArchiveWriter {
    private var archive: Archive?
    private let directory: URL
    private let url: URL

    init() throws {
        directory = try BackupArchiveReader.makeWorkingDirectory(prefix: "export")
        url = directory.appendingPathComponent("daymark-backup.zip")
        let created: Archive = try Archive(url: url, accessMode: .create)
        archive = created
    }

    func addPhoto(_ data: Data, metadata: DaymarkBackupEntry, index: Int) throws -> DaymarkBackupEntry {
        try Task.checkCancellation()
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0, let type = CGImageSourceGetType(source),
              let ext = UTType(type as String)?.preferredFilenameExtension else {
            throw BackupError.damagedPhoto(metadata.dayKey ?? "unknown date")
        }
        try BackupArchiveReader.verifyDecodablePhoto(source, name: metadata.dayKey ?? "unknown date")
        try BackupArchiveReader.checkSpace(required: Int64(data.count) + 1_048_576, at: directory)
        var result = metadata
        result.imageFilename = String(format: "%08d", index + 1) + "." + ext
        result.imageByteCount = Int64(data.count)
        result.imageSHA256 = BackupArchiveReader.hash(data)
        try add(data, path: "images/" + result.imageFilename!)
        return result
    }

    func finish(entries: [DaymarkBackupEntry]) throws -> (url: URL, byteCount: Int64) {
        try Task.checkCancellation()
        let payload = DaymarkBackupPayload(version: 3, exportedAt: .now, entries: entries)
        try add(BackupArchiveReader.encode(payload), path: "entries.json")
        archive = nil // Flush and close before verifying or presenting the file.
        try BackupArchiveReader.verify(url: url, expected: payload)
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        return (url, Int64(size))
    }

    func cancel() {
        archive = nil
        try? FileManager.default.removeItem(at: directory)
    }

    private func add(_ data: Data, path: String) throws {
        guard let archive else { throw BackupError.invalidArchive }
        try archive.addEntry(with: path, type: .file, uncompressedSize: Int64(data.count), bufferSize: 262_144) { position, count in
            try Task.checkCancellation()
            let start = data.startIndex + Int(position)
            return data.subdata(in: start..<(start + count))
        }
    }
}

nonisolated enum BackupArchiveReader {
    // The library stores one entry/day. A 32 MB metadata cap allows many
    // decades of captions while refusing malformed/bomb metadata payloads.
    static let metadataLimit: UInt64 = 32 * 1_024 * 1_024

    static func read(from url: URL) throws -> BackupContents {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        var result: Result<BackupContents, Error>?
        var coordinationError: NSError?
        // Coordinates reads with iCloud Drive/Google Drive file providers.
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { readableURL in
            result = Result { try readCoordinated(from: readableURL) }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw BackupError.invalidArchive }
        return try result.get()
    }

    private static func readCoordinated(from url: URL) throws -> BackupContents {
        try Task.checkCancellation()
        let handle = try FileHandle(forReadingFrom: url)
        let signature = try handle.read(upToCount: 4)
        try handle.close()
        if signature?.starts(with: [0x50, 0x4b]) != true {
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            // Legacy v1 JSON can contain original image bytes as base64.
            guard size <= 512 * 1_024 * 1_024 else { throw BackupError.invalidEntriesJSON }
            let payload = try decode(Data(contentsOf: url, options: .mappedIfSafe))
            try validateMetadata(payload)
            for entry in payload.entries {
                let name = entry.dayKey ?? entry.day.description
                guard let data = entry.legacyImageData else { throw BackupError.damagedPhoto(name) }
                try verifyDecodablePhoto(CGImageSourceCreateWithData(data as CFData, nil), name: name)
            }
            return BackupContents(payload: payload)
        }
        let archive = try Archive(url: url, accessMode: .read)
        try validateArchivePaths(archive)
        let payload = try readPayload(archive)
        try validateMetadata(payload)
        let directory = try makeWorkingDirectory(prefix: "import")
        do {
            try FileManager.default.createDirectory(at: directory.appendingPathComponent("images"), withIntermediateDirectories: true)
            for metadata in payload.entries {
                try Task.checkCancellation()
                guard let filename = metadata.imageFilename else {
                    guard let data = metadata.legacyImageData else { throw BackupError.damagedPhoto(metadata.day.description) }
                    try verifyDecodablePhoto(CGImageSourceCreateWithData(data as CFData, nil), name: metadata.day.description)
                    continue
                }
                guard isSafeFilename(filename), let photo = archive["images/" + filename], photo.type == .file else {
                    throw BackupError.damagedPhoto(filename)
                }
                guard photo.uncompressedSize <= UInt64(Int64.max) else { throw BackupError.invalidArchive }
                try checkSpace(required: Int64(photo.uncompressedSize), at: directory)
                let destination = directory.appendingPathComponent("images").appendingPathComponent(filename)
                _ = FileManager.default.createFile(atPath: destination.path, contents: nil,
                                                  attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
                let file = try FileHandle(forWritingTo: destination)
                do {
                    try verifyPhoto(archive, entry: photo, metadata: metadata) { try file.write(contentsOf: $0) }
                    try file.close()
                    try verifyDecodablePhoto(CGImageSourceCreateWithURL(destination as CFURL, nil), name: filename)
                } catch {
                    try? file.close()
                    throw error
                }
            }
            var result = BackupContents(payload: payload)
            result.workingDirectory = directory
            return result
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    static func verify(url: URL, expected: DaymarkBackupPayload) throws {
        let archive = try Archive(url: url, accessMode: .read)
        let payload = try readPayload(archive)
        let serializedExpected = try decode(encode(expected))
        guard payload.entries == serializedExpected.entries else { throw BackupError.invalidEntriesJSON }
        for metadata in payload.entries {
            try Task.checkCancellation()
            guard let filename = metadata.imageFilename, let entry = archive["images/" + filename] else {
                throw BackupError.invalidArchive
            }
            try verifyPhoto(archive, entry: entry, metadata: metadata) { _ in }
        }
    }

    private static func verifyPhoto(_ archive: Archive, entry: Entry, metadata: DaymarkBackupEntry,
                                    consumer: (Data) throws -> Void) throws {
        var digest = SHA256()
        var bytes: Int64 = 0
        let crc = try archive.extract(entry, bufferSize: 262_144) { data in
            try Task.checkCancellation()
            bytes += Int64(data.count)
            guard UInt64(bytes) <= entry.uncompressedSize else { throw BackupError.invalidArchive }
            digest.update(data: data)
            try consumer(data)
        }
        let hash = digest.finalize().map { String(format: "%02x", $0) }.joined()
        guard crc == entry.checksum, UInt64(bytes) == entry.uncompressedSize,
              metadata.imageByteCount.map({ $0 == bytes }) ?? true,
              metadata.imageSHA256.map({ $0 == hash }) ?? true else {
            throw BackupError.damagedPhoto(entry.path)
        }
    }

    static func validateMetadata(_ payload: DaymarkBackupPayload) throws {
        guard (1...3).contains(payload.version) else { throw BackupError.unsupportedVersion(payload.version) }
        var days = Set<Date>()
        var ids = Set<String>()
        var filenames = Set<String>()
        for entry in payload.entries {
            let day = try BackupCalendar.restoredDay(entry)
            guard days.insert(day).inserted else { throw BackupError.duplicateDay }
            if let id = entry.id, !ids.insert(id).inserted { throw BackupError.invalidEntriesJSON }
            if let filename = entry.imageFilename {
                guard isSafeFilename(filename), filenames.insert(filename).inserted else { throw BackupError.invalidArchive }
                if payload.version == 3 {
                    guard let count = entry.imageByteCount, count > 0,
                          let hash = entry.imageSHA256, hash.count == 64,
                          hash.allSatisfy({ $0.isHexDigit }), entry.dayKey != nil else { throw BackupError.invalidEntriesJSON }
                }
            }
            if let latitude = entry.latitude, !(-90...90).contains(latitude) { throw BackupError.invalidEntriesJSON }
            if let longitude = entry.longitude, !(-180...180).contains(longitude) { throw BackupError.invalidEntriesJSON }
        }
    }

    private static func readPayload(_ archive: Archive) throws -> DaymarkBackupPayload {
        guard let entry = archive["entries.json"], entry.type == .file else { throw BackupError.missingEntriesJSON }
        guard entry.uncompressedSize <= metadataLimit else { throw BackupError.invalidEntriesJSON }
        var data = Data()
        let crc = try archive.extract(entry) { chunk in
            try Task.checkCancellation()
            guard UInt64(data.count + chunk.count) <= metadataLimit else { throw BackupError.invalidEntriesJSON }
            data.append(chunk)
        }
        guard crc == entry.checksum else { throw BackupError.invalidEntriesJSON }
        return try decode(data)
    }

    private static func validateArchivePaths(_ archive: Archive) throws {
        var paths = Set<String>()
        for entry in archive {
            guard paths.insert(entry.path).inserted, !entry.path.hasPrefix("/"),
                  !entry.path.contains("\\"), !entry.path.split(separator: "/").contains(".."),
                  entry.type != .symlink else { throw BackupError.invalidArchive }
        }
    }

    static func isSafeFilename(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\\") && !name.contains("\0")
    }

    static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func verifyDecodablePhoto(_ source: CGImageSource?, name: String) throws {
        try Task.checkCancellation()
        // A valid image header and checksum do not prove pixels can be read.
        // Exercise the same ImageIO downsampling path used by restored view
        // photos, without allocating a full-resolution bitmap.
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 2_048,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let source, CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) != nil else {
            throw BackupError.damagedPhoto(name)
        }
    }

    static func makeWorkingDirectory(prefix: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("DaymarkBackups", isDirectory: true)
        let directory = root.appendingPathComponent(prefix + "-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                              attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        return directory
    }

    static func checkSpace(required: Int64, at url: URL) throws {
        let values = try url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        if let available = values.volumeAvailableCapacityForImportantUsage, available < required {
            throw BackupError.insufficientSpace
        }
    }

    static func encode(_ payload: DaymarkBackupPayload) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(date.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: true).timeZone(separator: .colon)))
        }
        return try encoder.encode(payload)
    }

    static func decode(_ data: Data) throws -> DaymarkBackupPayload {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: text) { return date }
            formatter.formatOptions = [.withInternetDateTime]
            guard let date = formatter.date(from: text) else { throw BackupError.invalidEntriesJSON }
            return date
        }
        do { return try decoder.decode(DaymarkBackupPayload.self, from: data) }
        catch { throw BackupError.invalidEntriesJSON }
    }
}

nonisolated struct BackupImportSummary: Sendable {
    let imported: Int
    let skipped: Int
}
