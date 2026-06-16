import SwiftUI
import UIKit

/// Off-main-thread thumbnail decoder with an in-memory cache. Decoding image
/// data is the expensive part; doing it on the main thread while scrolling is
/// what makes long libraries stutter, so all reads/decodes happen on a
/// background task and only the finished `UIImage` is handed back.
final class ThumbnailImageLoader: @unchecked Sendable {
    static let shared = ThumbnailImageLoader()

    // NSCache is thread-safe; it is the only shared state, hence @unchecked Sendable.
    private let cache = NSCache<NSString, UIImage>()

    /// Stable key that changes when the entry's thumbnail file changes (e.g. an
    /// edit), so an updated photo reloads instead of showing a stale cache hit.
    nonisolated static func identity(for entry: PhotoEntry) -> String {
        "\(entry.id)|\(entry.localThumbnailFilename ?? "embedded")"
    }

    /// Synchronous cache peek so an already-decoded thumbnail appears instantly
    /// (no flash of placeholder) when a row scrolls back into view.
    func cachedImage(for identity: String) -> UIImage? {
        cache.object(forKey: identity as NSString)
    }

    /// Returns the decoded thumbnail, decoding off the main thread on a miss.
    /// `filename`/`embedded` must be read from the SwiftData model by the caller
    /// (on the main actor) and passed in, so this never touches the model.
    func thumbnail(identity: String, filename: String?, embedded: Data?) async -> UIImage? {
        if let cached = cache.object(forKey: identity as NSString) {
            return cached
        }

        let image = await Task.detached(priority: .userInitiated) {
            Self.decode(filename: filename, embedded: embedded)
        }.value

        if let image {
            cache.setObject(image, forKey: identity as NSString)
        }
        return image
    }

    private nonisolated static func decode(filename: String?, embedded: Data?) -> UIImage? {
        let data: Data?
        if let filename {
            data = try? Data(contentsOf: thumbnailURL(for: filename), options: [.mappedIfSafe])
        } else {
            data = embedded
        }
        guard let data else { return nil }
        // preparingForDisplay() forces the decode here (off-main) instead of on
        // the first draw, keeping the render pass cheap.
        return UIImage(data: data)?.preparingForDisplay()
    }

    private nonisolated static func thumbnailURL(for filename: String) throws -> URL {
        guard filename == URL(fileURLWithPath: filename).lastPathComponent,
              filename.hasSuffix(".thumb") else {
            throw OriginalPhotoFileStoreError.invalidFilename
        }

        return FileManager.default.urls(
            for: .cachesDirectory,
            in: .userDomainMask
        )[0]
        .appendingPathComponent("Daymark", isDirectory: true)
        .appendingPathComponent("Thumbnails", isDirectory: true)
        .appendingPathComponent(filename, isDirectory: false)
    }
}

/// Asynchronously loads an entry's thumbnail and shows `placeholder` until it is
/// ready. Loading is cancelled when the view scrolls away and resumes (from
/// cache, instantly) when it returns.
struct EntryThumbnail<Placeholder: View>: View {
    let entry: PhotoEntry
    @ViewBuilder var placeholder: () -> Placeholder

    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                placeholder()
            }
        }
        .task(id: ThumbnailImageLoader.identity(for: entry)) {
            await load()
        }
    }

    private func load() async {
        let identity = ThumbnailImageLoader.identity(for: entry)
        if let cached = ThumbnailImageLoader.shared.cachedImage(for: identity) {
            image = cached
            return
        }

        // Read the model's properties here on the main actor, decode off-main.
        let filename = entry.localThumbnailFilename
        let embedded = filename == nil ? entry.thumbnailData : nil
        let loaded = await ThumbnailImageLoader.shared.thumbnail(
            identity: identity,
            filename: filename,
            embedded: embedded
        )
        guard !Task.isCancelled else { return }
        image = loaded
    }
}
