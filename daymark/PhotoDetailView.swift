import PhotosUI
import SwiftData
import SwiftUI
import UIKit

struct PhotoDetailView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    let entry: PhotoEntry
    private let photoStore = PhotoStore()

    @State private var caption: String
    @State private var selectedItem: PhotosPickerItem?
    @State private var showingDeleteConfirmation = false
    @State private var errorMessage: String?

    init(entry: PhotoEntry) {
        self.entry = entry
        _caption = State(initialValue: entry.caption ?? "")
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                photoSection
                metadataSection
                captionSection
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
                PhotosPicker(selection: $selectedItem, matching: .images) {
                    Image(systemName: "arrow.triangle.2.circlepath.camera")
                        .font(.system(size: 15, weight: .semibold))
                }
            }
        }
        .onChange(of: selectedItem) { _, newItem in
            guard let newItem else { return }
            Task {
                do {
                    guard let data = try await newItem.loadTransferable(type: Data.self) else {
                        errorMessage = "Could not import that photo."
                        selectedItem = nil
                        return
                    }
                    try await photoStore.savePhotoData(data, for: entry.day, in: modelContext)
                } catch {
                    errorMessage = "Could not import that photo."
                }
                selectedItem = nil
            }
        }
        .onChange(of: caption) { _, newValue in
            entry.caption = newValue.isEmpty ? nil : newValue
            try? modelContext.save()
        }
        .confirmationDialog("Delete this entry?", isPresented: $showingDeleteConfirmation, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                do {
                    try photoStore.deleteEntry(entry, in: modelContext)
                    dismiss()
                } catch {
                    errorMessage = "Could not delete entry."
                }
            }
        } message: {
            Text("This photo and its data will be permanently removed.")
        }
        .alert("Error", isPresented: errorAlertBinding) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(errorMessage ?? "Something went wrong.")
        }
    }

    private var photoSection: some View {
        Group {
            if let image = photoStore.image(for: entry) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            } else {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(.secondarySystemBackground))
                    .aspectRatio(1, contentMode: .fit)
                    .overlay {
                        Image(systemName: "photo")
                            .font(.system(size: 40, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
            }
        }
    }

    private var metadataSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let captureDate = entry.captureDate {
                metadataRow(
                    icon: "clock",
                    title: "Taken",
                    value: captureDate.formatted(.dateTime.month(.wide).day().year().hour().minute())
                )
            }

            if let city = entry.city, let countryCode = entry.countryCode {
                let flag = entry.flagEmoji ?? ""
                metadataRow(icon: "location", title: "Location", value: "\(flag) \(city), \(countryCode)")
            } else if let city = entry.city {
                metadataRow(icon: "location", title: "Location", value: city)
            }

            if entry.latitude != nil, entry.longitude != nil, entry.city == nil {
                metadataRow(
                    icon: "location",
                    title: "Coordinates",
                    value: formatCoordinates(lat: entry.latitude!, lon: entry.longitude!)
                )
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var captionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Note", systemImage: "text.quote")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)

            TextField("Add a note about this day...", text: $caption, axis: .vertical)
                .lineLimit(1...6)
                .textFieldStyle(.plain)
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
                Text("Delete Entry")
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

    private var errorAlertBinding: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )
    }
}
