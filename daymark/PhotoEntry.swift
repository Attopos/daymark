import Foundation
import SwiftData

@Model
final class PhotoEntry {
    var id: String = UUID().uuidString
    var day: Date = Date.distantPast
    @Attribute(.externalStorage) var imageData: Data?
    @Attribute(.externalStorage) var thumbnailData: Data?
    var captureDate: Date?
    var imageFilename: String?
    var localOriginalFilename: String?
    var localThumbnailFilename: String?
    var localViewPhotoFilename: String?
    var originalByteCount: Int64?
    var originalContentHash: String?
    var originalLastSyncedHash: String?
    var thumbnailByteCount: Int64?
    var thumbnailContentHash: String?
    var thumbnailModifiedAt: Date?
    var viewPhotoByteCount: Int64?
    var viewPhotoContentHash: String?
    var viewPhotoModifiedAt: Date?
    var latitude: Double?
    var longitude: Double?
    var timezone: String?
    var countryCode: String?
    var countryName: String?
    var city: String?
    var caption: String?
    var metadataSyncStateRaw: String = SyncState.untracked.rawValue
    var thumbnailSyncStateRaw: String = SyncState.untracked.rawValue
    var viewPhotoSyncStateRaw: String = SyncState.untracked.rawValue
    var originalSyncStateRaw: String = SyncState.untracked.rawValue
    var syncStateUpdatedAt: Date?
    var lastSyncErrorComponentRaw: String?
    var lastSyncErrorMessage: String?
    @Attribute(.externalStorage) var metadataVersionData: Data?
    @Attribute(.externalStorage) var metadataBaselineData: Data?
    var originalConflictRemoteHash: String?
    var originalConflictRemoteByteCount: Int64?
    var originalConflictRemoteModifiedAt: Date?
    var originalConflictRemoteFilename: String?
    var originalConflictDetectedAt: Date?
    var originalConflictResolutionRaw: String?

    init(
        id: String = UUID().uuidString,
        day: Date,
        imageData: Data? = nil,
        thumbnailData: Data? = nil,
        captureDate: Date? = nil,
        imageFilename: String? = nil,
        localOriginalFilename: String? = nil,
        localThumbnailFilename: String? = nil,
        localViewPhotoFilename: String? = nil,
        originalByteCount: Int64? = nil,
        originalContentHash: String? = nil,
        originalLastSyncedHash: String? = nil,
        thumbnailByteCount: Int64? = nil,
        thumbnailContentHash: String? = nil,
        thumbnailModifiedAt: Date? = nil,
        viewPhotoByteCount: Int64? = nil,
        viewPhotoContentHash: String? = nil,
        viewPhotoModifiedAt: Date? = nil,
        latitude: Double? = nil,
        longitude: Double? = nil,
        timezone: String? = nil,
        countryCode: String? = nil,
        countryName: String? = nil,
        city: String? = nil,
        caption: String? = nil,
        metadataSyncState: SyncState = .untracked,
        thumbnailSyncState: SyncState = .untracked,
        viewPhotoSyncState: SyncState = .untracked,
        originalSyncState: SyncState = .untracked
    ) {
        self.id = id
        self.day = day
        self.imageData = imageData
        self.thumbnailData = thumbnailData
        self.captureDate = captureDate
        self.imageFilename = imageFilename
        self.localOriginalFilename = localOriginalFilename
        self.localThumbnailFilename = localThumbnailFilename
        self.localViewPhotoFilename = localViewPhotoFilename
        self.originalByteCount = originalByteCount
        self.originalContentHash = originalContentHash
        self.originalLastSyncedHash = originalLastSyncedHash
        self.thumbnailByteCount = thumbnailByteCount
        self.thumbnailContentHash = thumbnailContentHash
        self.thumbnailModifiedAt = thumbnailModifiedAt
        self.viewPhotoByteCount = viewPhotoByteCount
        self.viewPhotoContentHash = viewPhotoContentHash
        self.viewPhotoModifiedAt = viewPhotoModifiedAt
        self.latitude = latitude
        self.longitude = longitude
        self.timezone = timezone
        self.countryCode = countryCode
        self.countryName = countryName
        self.city = city
        self.caption = caption
        self.metadataSyncStateRaw = metadataSyncState.rawValue
        self.thumbnailSyncStateRaw = thumbnailSyncState.rawValue
        self.viewPhotoSyncStateRaw = viewPhotoSyncState.rawValue
        self.originalSyncStateRaw = originalSyncState.rawValue
    }

    var flagEmoji: String? {
        guard let countryCode, countryCode.count == 2 else { return nil }
        let scalars = countryCode.uppercased().unicodeScalars.compactMap {
            UnicodeScalar(127397 + $0.value)
        }
        guard scalars.count == 2 else { return nil }
        return String(scalars.map { Character($0) })
    }
}

extension PhotoEntry {
    var metadataSyncState: SyncState {
        get { SyncState(rawValue: metadataSyncStateRaw) ?? .untracked }
        set { metadataSyncStateRaw = newValue.rawValue }
    }

    var thumbnailSyncState: SyncState {
        get { SyncState(rawValue: thumbnailSyncStateRaw) ?? .untracked }
        set { thumbnailSyncStateRaw = newValue.rawValue }
    }

    var originalSyncState: SyncState {
        get { SyncState(rawValue: originalSyncStateRaw) ?? .untracked }
        set { originalSyncStateRaw = newValue.rawValue }
    }

    var viewPhotoSyncState: SyncState {
        get { SyncState(rawValue: viewPhotoSyncStateRaw) ?? .untracked }
        set { viewPhotoSyncStateRaw = newValue.rawValue }
    }

    var overallSyncState: SyncState {
        SyncStateMachine.overallState(
            metadata: metadataSyncState,
            thumbnail: thumbnailSyncState,
            viewPhoto: viewPhotoSyncState,
            original: originalSyncState
        )
    }

    var originalConflictResolution: OriginalConflictResolution? {
        get {
            guard let originalConflictResolutionRaw else { return nil }
            return OriginalConflictResolution(rawValue: originalConflictResolutionRaw)
        }
        set { originalConflictResolutionRaw = newValue?.rawValue }
    }

    func recordOriginalConflict(
        remote: RemoteOriginalPhoto,
        filename: String? = nil,
        at date: Date = .now
    ) {
        originalConflictRemoteHash = remote.contentHash
        originalConflictRemoteByteCount = remote.byteCount
        originalConflictRemoteModifiedAt = remote.modifiedAt
        originalConflictRemoteFilename = filename
        originalConflictDetectedAt = date
        originalConflictResolution = nil
    }

    func clearOriginalConflict(resolution: OriginalConflictResolution) {
        originalConflictRemoteHash = nil
        originalConflictRemoteByteCount = nil
        originalConflictRemoteModifiedAt = nil
        originalConflictRemoteFilename = nil
        originalConflictDetectedAt = nil
        originalConflictResolution = resolution
    }

    @discardableResult
    func transitionSyncState(
        for component: SyncComponent,
        to newState: SyncState,
        at date: Date = .now,
        errorMessage: String? = nil
    ) -> Bool {
        let currentState = syncState(for: component)
        guard SyncStateMachine.canTransition(from: currentState, to: newState) else {
            return false
        }

        setSyncState(newState, for: component)
        syncStateUpdatedAt = date

        if newState == .failed {
            lastSyncErrorComponentRaw = component.rawValue
            lastSyncErrorMessage = errorMessage
        } else if lastSyncErrorComponentRaw == component.rawValue {
            lastSyncErrorComponentRaw = nil
            lastSyncErrorMessage = nil
        }

        return true
    }

    func syncState(for component: SyncComponent) -> SyncState {
        switch component {
        case .metadata: metadataSyncState
        case .thumbnail: thumbnailSyncState
        case .viewPhoto: viewPhotoSyncState
        case .original: originalSyncState
        }
    }

    private func setSyncState(_ state: SyncState, for component: SyncComponent) {
        switch component {
        case .metadata: metadataSyncState = state
        case .thumbnail: thumbnailSyncState = state
        case .viewPhoto: viewPhotoSyncState = state
        case .original: originalSyncState = state
        }
    }
}

enum SyncComponent: String, CaseIterable, Codable {
    case metadata
    case thumbnail
    case viewPhoto
    case original
}

enum SyncState: String, CaseIterable, Codable {
    case untracked
    case localOnly
    case pendingUpload
    case uploading
    case pendingDownload
    case downloading
    case synced
    case failed
    case conflict
}

enum OriginalConflictResolution: String, Codable {
    case keptLocal
    case usedICloud
}

enum SyncStateMachine {
    static func canTransition(from current: SyncState, to next: SyncState) -> Bool {
        guard current != next else { return true }

        switch current {
        case .untracked:
            return [.localOnly, .pendingUpload, .pendingDownload, .synced, .failed].contains(next)
        case .localOnly:
            return [.pendingUpload, .pendingDownload, .synced, .failed].contains(next)
        case .pendingUpload:
            return [.uploading, .synced, .failed, .conflict, .localOnly].contains(next)
        case .uploading:
            return [.pendingUpload, .synced, .failed, .conflict].contains(next)
        case .pendingDownload:
            return [.downloading, .synced, .failed, .localOnly].contains(next)
        case .downloading:
            return [.pendingDownload, .synced, .failed, .conflict].contains(next)
        case .synced:
            return [.pendingUpload, .pendingDownload, .failed, .conflict, .localOnly].contains(next)
        case .failed:
            return [.pendingUpload, .uploading, .pendingDownload, .downloading, .synced, .conflict, .localOnly].contains(next)
        case .conflict:
            return [.pendingUpload, .pendingDownload, .synced, .failed, .localOnly].contains(next)
        }
    }

    static func overallState(
        metadata: SyncState,
        thumbnail: SyncState,
        viewPhoto: SyncState,
        original: SyncState
    ) -> SyncState {
        let states = [metadata, thumbnail, viewPhoto, original]
        let priority: [SyncState] = [
            .conflict,
            .failed,
            .uploading,
            .downloading,
            .pendingUpload,
            .pendingDownload,
            .localOnly,
            .untracked
        ]

        return priority.first(where: states.contains) ?? .synced
    }
}
