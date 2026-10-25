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
            var payload = try decode(Data(contentsOf: url, options: .mappedIfSafe))
            var report = LegacyRestoreReport()
            if isLegacy(payload) { (payload, report, _) = try normalizeLegacy(payload, archive: nil) }
            try validateMetadata(payload)
            for entry in payload.entries {
                let name = entry.dayKey ?? entry.day.description
                guard let data = entry.legacyImageData else { throw BackupError.damagedPhoto(name) }
                try verifyDecodablePhoto(CGImageSourceCreateWithData(data as CFData, nil), name: name)
            }
            var result = BackupContents(payload: payload)
            result.legacyReport = report
            return result
        }
        let archive = try Archive(url: url, accessMode: .read)
        var payload = try readPayload(archive)
        let legacy = isLegacy(payload)
        try validateArchivePaths(archive, allowsRepeatedImagePaths: legacy)
        var report = LegacyRestoreReport()
        var legacySources: [String: Entry] = [:]
        if legacy { (payload, report, legacySources) = try normalizeLegacy(payload, archive: archive) }
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
                guard isSafeFilename(filename), let photo = legacy ? legacySources[filename] : archive["images/" + filename],
                      photo.type == .file else {
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
            result.legacyReport = report
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

    private static func validateArchivePaths(_ archive: Archive, allowsRepeatedImagePaths: Bool = false) throws {
        var paths = Set<String>()
        for entry in archive {
            // The v2 writer named photos after entry IDs, so a library with a
            // duplicated ID wrote the same images/ path twice. Those are
            // matched to records by position in normalizeLegacy.
            let repeatable = allowsRepeatedImagePaths && entry.path.hasPrefix("images/")
            guard paths.insert(entry.path).inserted || repeatable, !entry.path.hasPrefix("/"),
                  !entry.path.contains("\\"), !entry.path.split(separator: "/").contains(".."),
                  entry.type != .symlink else { throw BackupError.invalidArchive }
        }
    }

    private static func isLegacy(_ payload: DaymarkBackupPayload) -> Bool {
        (1...2).contains(payload.version)
    }

    /// v1/v2 backups were written without validation, from libraries that
    /// could hold duplicate days (sync duplicates), duplicate IDs, and records
    /// whose photo had not arrived yet. The old importer tolerated all three.
    /// Rejecting the whole file left no way to restore it, so records without
    /// a photo are dropped, same-day records are merged into one, and repeated
    /// IDs are given fresh identities. v3 archives stay strictly validated.
    static func normalizeLegacy(
        _ payload: DaymarkBackupPayload, archive: Archive?
    ) throws -> (DaymarkBackupPayload, LegacyRestoreReport, [String: Entry]) {
        var report = LegacyRestoreReport()
        var queues: [String: [Entry]] = [:]
        if let archive {
            for entry in archive where entry.type == .file && entry.path.hasPrefix("images/") {
                queues[String(entry.path.dropFirst("images/".count)), default: []].append(entry)
            }
        }
        var sources: [String: Entry] = [:]
        var kept: [DaymarkBackupEntry] = []
        var indexByDay: [Date: Int] = [:]
        for (index, original) in payload.entries.enumerated() {
            var entry = original
            if archive != nil, let filename = entry.imageFilename {
                // Repeated paths are stored in record order; extra references
                // reuse the last copy, as the old importer did.
                guard isSafeFilename(filename), var queue = queues[filename], let photo = queue.first else {
                    throw BackupError.damagedPhoto(filename)
                }
                if queue.count > 1 { queue.removeFirst(); queues[filename] = queue }
                let staged = sources[filename] == nil ? filename : String(format: "%08d-", index + 1) + filename
                sources[staged] = photo
                entry.imageFilename = staged
            } else if archive == nil {
                entry.imageFilename = nil // v1 JSON embeds the photo; old names are not files here.
            }
            guard entry.imageFilename != nil || entry.legacyImageData != nil else {
                report.entriesWithoutPhoto += 1
                continue
            }
            let day = try BackupCalendar.restoredDay(entry)
            if let existing = indexByDay[day] {
                report.duplicateDaysMerged += 1
                let current = kept[existing]
                // Later records win ties, matching the old importer's overwrite.
                kept[existing] = legacyScore(current) > legacyScore(entry)
                    ? current.fillingMissingValues(from: entry)
                    : entry.fillingMissingValues(from: current)
            } else {
                indexByDay[day] = kept.count
                kept.append(entry)
            }
        }
        var ids = Set<String>()
        for index in kept.indices {
            if let id = kept[index].id, !ids.insert(id).inserted { kept[index] = kept[index].withID(nil) }
        }
        let referenced = Set(kept.compactMap(\.imageFilename))
        sources = sources.filter { referenced.contains($0.key) }
        return (DaymarkBackupPayload(version: payload.version, exportedAt: payload.exportedAt, entries: kept), report, sources)
    }

    private static func legacyScore(_ entry: DaymarkBackupEntry) -> Int {
        [entry.caption?.isEmpty == false, entry.latitude != nil && entry.longitude != nil,
         entry.countryCode != nil, entry.city != nil, entry.captureDate != nil].filter { $0 }.count
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

    /// Export and import stage whole libraries in tmp. If the app is killed
    /// mid-operation nothing removes them, so clear leftovers at launch,
    /// before any backup operation can be running.
    static func removeStaleWorkingDirectories() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("DaymarkBackups", isDirectory: true)
        try? FileManager.default.removeItem(at: root)
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

nonisolated struct LegacyRestoreReport: Sendable, Equatable {
    var entriesWithoutPhoto = 0
    var duplicateDaysMerged = 0
}

nonisolated extension DaymarkBackupEntry {
    /// Keeps this record's photo, day and time zone; fills absent details
    /// from another record for the same day.
    func fillingMissingValues(from other: DaymarkBackupEntry) -> DaymarkBackupEntry {
        let hasLocation = latitude != nil && longitude != nil
        let hasCountry = countryCode != nil
        var merged = DaymarkBackupEntry(
            id: id ?? other.id, day: day, captureDate: captureDate ?? other.captureDate,
            imageFilename: imageFilename,
            latitude: hasLocation ? latitude : other.latitude ?? latitude,
            longitude: hasLocation ? longitude : other.longitude ?? longitude,
            timezone: timezone,
            countryCode: hasCountry ? countryCode : other.countryCode,
            countryName: hasCountry ? countryName : other.countryName ?? countryName,
            city: city ?? other.city,
            caption: caption?.isEmpty == false ? caption : other.caption ?? caption
        )
        merged.legacyImageData = legacyImageData
        merged.imageByteCount = imageByteCount
        merged.imageSHA256 = imageSHA256
        merged.dayKey = dayKey
        return merged
    }

    func withID(_ newID: String?) -> DaymarkBackupEntry {
        var copy = DaymarkBackupEntry(
            id: newID, day: day, captureDate: captureDate, imageFilename: imageFilename,
            latitude: latitude, longitude: longitude, timezone: timezone,
            countryCode: countryCode, countryName: countryName, city: city, caption: caption
        )
        copy.legacyImageData = legacyImageData
        copy.imageByteCount = imageByteCount
        copy.imageSHA256 = imageSHA256
        copy.dayKey = dayKey
        return copy
    }
}
