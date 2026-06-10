import PhotosUI
import SwiftData
import SwiftUI
import UIKit

struct PhotoDetailView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @Environment(LocationLocalizer.self) private var locationLocalizer
    @Query private var allEntries: [PhotoEntry]

    let entry: PhotoEntry
    private let photoStore = PhotoStore()
    @State private var selectedItem: PhotosPickerItem?
    @State private var showingDeleteConfirmation = false
    @State private var showingPhotoEditor = false
    @State private var showingLocationPicker = false
    @State private var pendingReplacementImport: PendingPhotoReplacement?
    @State private var errorMessage: String?
    @State private var isDownloadingViewPhoto = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                photoSection
                metadataSection
                deleteSection
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 32)
        }
        .navigationTitle(entry.day.formatted(.dateTime.month(.wide).day().year()))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                HStack(spacing: 16) {
                    if photoStore.image(for: entry) != nil {
                        Button {
                            showingPhotoEditor = true
                        } label: {
                            Image(systemName: "slider.horizontal.3")
                                .font(.system(size: 15, weight: .semibold))
                        }
                    }

                    PhotosPicker(selection: $selectedItem, matching: .images) {
                        Image(systemName: "arrow.triangle.2.circlepath.camera")
                            .font(.system(size: 15, weight: .semibold))
                    }
                }
            }
        }
        .onChange(of: selectedItem) { _, newItem in
            guard let newItem else { return }
            Task {
                await importReplacementPhoto(newItem)
                selectedItem = nil
            }
        }
        .alert("Delete this photo?", isPresented: $showingDeleteConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Delete", role: .destructive) {
                do {
                    try photoStore.deleteEntry(entry, in: modelContext)
                    dismiss()
                } catch {
                    errorMessage = "Could not delete."
                }
            }
        } message: {
            Text("This photo will be permanently removed.")
        }
        .alert("Error", isPresented: errorAlertBinding) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(errorMessage ?? "Something went wrong.")
        }
        .task {
            await locationLocalizer.localize(entry)
        }
        .task(id: entry.localViewPhotoFilename) {
            await downloadViewPhotoIfNeeded()
        }
        .sheet(isPresented: $showingPhotoEditor) {
            if let image = photoStore.image(for: entry) {
                PhotoEditView(image: image) { editedImage in
                    do {
                        try photoStore.saveEditedImage(editedImage, for: entry, in: modelContext)
                    } catch {
                        errorMessage = "Could not save photo edits."
                    }
                }
            }
        }
        .sheet(isPresented: $showingLocationPicker) {
            LocationPickerView { lat, lon, city, countryCode, countryName in
                entry.latitude = lat
                entry.longitude = lon
                entry.city = city
                entry.countryCode = countryCode
                entry.countryName = countryName
                entry.metadataSyncState = .localOnly
                try? modelContext.save()
                Task {
                    await locationLocalizer.localize(entry)
                }
            }
        }
        .sheet(item: $pendingReplacementImport, onDismiss: {
            pendingReplacementImport = nil
        }) { pendingImport in
            LocationPickerView { lat, lon, city, countryCode, countryName in
                let location = PhotoLocationOverride(
                    latitude: lat,
                    longitude: lon,
                    city: city,
                    countryCode: countryCode,
                    countryName: countryName
                )
                Task {
                    await savePendingReplacement(pendingImport, location: location)
                }
            }
        }
    }

    private var photoSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Group {
                if let image = photoStore.viewImage(for: entry) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                } else {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color(.secondarySystemBackground))
                        .aspectRatio(1, contentMode: .fit)
                        .overlay {
                            if isDownloadingViewPhoto {
                                ProgressView()
                            } else {
                                Image(systemName: "photo")
                                    .font(.system(size: 40, weight: .medium))
                                    .foregroundStyle(.secondary)
                            }
                        }
                }
            }

            if viewPhotoStatusVisible {
                HStack(spacing: 6) {
                    if isDownloadingViewPhoto || entry.viewPhotoSyncState == .downloading {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text(viewPhotoStatusText)
                        .font(.caption)
                        .foregroundStyle(entry.viewPhotoSyncState == .failed ? .red : .secondary)
                }
            }
        }
    }

    private var viewPhotoStatusVisible: Bool {
        isDownloadingViewPhoto ||
        [.pendingDownload, .downloading, .failed].contains(entry.viewPhotoSyncState)
    }

    private var viewPhotoStatusText: String {
        let size = entry.viewPhotoByteCount.map {
            ByteCountFormatter.string(fromByteCount: $0, countStyle: .file)
        }

        switch entry.viewPhotoSyncState {
        case .pendingDownload:
            return ["Waiting to download", size].compactMap { $0 }.joined(separator: " · ")
        case .downloading:
            return ["Downloading", size].compactMap { $0 }.joined(separator: " · ")
        case .failed:
            return entry.lastSyncErrorMessage ?? "Download failed"
        default:
            return size.map { "Downloading · \($0)" } ?? "Downloading"
        }
    }

    @MainActor
    private func downloadViewPhotoIfNeeded() async {
        guard photoStore.viewPhotoData(for: entry) == nil,
              photoStore.originalData(for: entry) == nil,
              !isDownloadingViewPhoto else {
            return
        }

        isDownloadingViewPhoto = true
        defer { isDownloadingViewPhoto = false }
        do {
            let downloadedBytes = try await ViewPhotoSyncCoordinator().downloadOnDemand(
                entry: entry,
                in: modelContext
            )
            SyncEngineStatusStore.shared.addTransferred(downloaded: downloadedBytes)
            SyncEngineStatusStore.shared.refresh(entries: allEntries)
        } catch {
            // The thumbnail remains visible while iCloud is unavailable.
        }
    }

    private var metadataSection: some View {
        HStack {
            if let city = locationLocalizer.localizedCity(for: entry), let countryCode = entry.countryCode {
                let flag = entry.flagEmoji ?? ""
                metadataRow(icon: "location", title: "Location", value: "\(flag) \(city), \(countryCode)")
            } else if let city = locationLocalizer.localizedCity(for: entry) {
                metadataRow(icon: "location", title: "Location", value: city)
            } else if entry.latitude != nil, entry.longitude != nil {
                metadataRow(
                    icon: "location",
                    title: "Coordinates",
                    value: formatCoordinates(lat: entry.latitude!, lon: entry.longitude!)
                )
            }

            Spacer()

            Button {
                showingLocationPicker = true
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "map")
                        .font(.system(size: 13, weight: .semibold))
                    Text("Choose on the map")
                        .font(.subheadline)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var deleteSection: some View {
        Button(role: .destructive) {
            showingDeleteConfirmation = true
        } label: {
            HStack {
                Image(systemName: "trash")
                Text("Delete")
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
        }
        .buttonStyle(.bordered)
        .tint(.red)
    }

    private func metadataRow(icon: String, title: String, value: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.subheadline)
            }
        }
    }

    private func formatCoordinates(lat: Double, lon: Double) -> String {
        String(format: "%.4f, %.4f", lat, lon)
    }

    @MainActor
    private func importReplacementPhoto(_ item: PhotosPickerItem) async {
        do {
            guard let data = try await item.loadTransferable(type: Data.self) else {
                errorMessage = "Could not import that photo."
                return
            }

            if photoStore.hasEmbeddedLocation(in: data) {
                try await photoStore.savePhotoData(data, for: entry.day, in: modelContext)
                await locationLocalizer.localize(entry)
            } else {
                pendingReplacementImport = PendingPhotoReplacement(data: data)
            }
        } catch {
            errorMessage = "Could not import that photo."
        }
    }

    @MainActor
    private func savePendingReplacement(_ importItem: PendingPhotoReplacement, location: PhotoLocationOverride) async {
        do {
            try await photoStore.savePhotoData(
                importItem.data,
                for: entry.day,
                in: modelContext,
                locationOverride: location
            )
            await locationLocalizer.localize(entry)
            pendingReplacementImport = nil
        } catch {
            errorMessage = "Could not import that photo."
        }
    }

    private var errorAlertBinding: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )
    }
}

private struct PendingPhotoReplacement: Identifiable {
    let id = UUID()
    let data: Data
}
