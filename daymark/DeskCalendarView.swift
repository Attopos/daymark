import ImageIO
import SwiftData
import SwiftUI
import UIKit

/// A front-facing standing desk calendar: one daymark per page, each photo shown
/// in full. Swiping up lifts the current page over the top binding to reveal the
/// next day; swiping down brings the previous page back over the binding.
struct DeskCalendarView: View {
    @Query(sort: \PhotoEntry.day) private var entries: [PhotoEntry]

    /// Index into `entries`; `Int.max` means "the most recent page".
    @State private var index = Int.max
    /// The entry the calendar is open at, so inserts/deletes keep the same page.
    @State private var anchorID: String?
    /// Flip progress, -1...1. Negative lifts the current page away (next day);
    /// positive brings the previous page back down over it.
    @State private var flip: CGFloat = 0
    @State private var isSettling = false
    @State private var selectedEntry: PhotoEntry?

    private let photoStore = PhotoStore()
    private let pageAspect: CGFloat = 0.72
    private let standDepth: CGFloat = 18

    var body: some View {
        NavigationStack {
            GeometryReader { proxy in
                if let current = resolvedIndex() {
                    deskCalendar(at: current, fitting: proxy.size)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 28)
            .padding(.bottom, 12)
            .background(DaymarkPalette.paper)
            .daymarkNavigationTitle("Daily", inline: true)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if let current = resolvedIndex(), current < entries.count - 1 {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            withAnimation(.easeInOut(duration: 0.25)) {
                                index = Int.max
                                anchorID = nil
                                flip = 0
                            }
                        } label: {
                            Image(systemName: "arrow.down.to.line")
                                .font(.system(size: 15, weight: .semibold))
                        }
                        .accessibilityLabel("Latest daymark")
                    }
                }
            }
            .navigationDestination(item: $selectedEntry) { entry in
                PhotoDetailView(entry: entry)
            }
            .overlay {
                if entries.isEmpty {
                    ContentUnavailableView(
                        "No Daymarks Yet",
                        systemImage: "calendar",
                        description: Text("Your desk calendar fills in as you add daymarks.")
                    )
                }
            }
            .sensoryFeedback(.selection, trigger: anchorID)
            .task(id: anchorID) {
                prefetchNeighbours()
            }
            .daymarkScreen()
        }
    }

    // MARK: - Calendar

    private func deskCalendar(at current: Int, fitting size: CGSize) -> some View {
        let pageHeight = min(size.height - standDepth - 28, (size.width - 12) / pageAspect)
        let pageSize = CGSize(width: pageHeight * pageAspect, height: pageHeight)

        return VStack(spacing: 10) {
            ZStack(alignment: .top) {
                DeskCalendarStand(pageSize: pageSize, depth: standDepth)

                ZStack(alignment: .top) {
                    ForEach(underPageEdges(at: current), id: \.self) { depth in
                        PageEdge()
                            .offset(y: CGFloat(depth) * 2.5)
                            .zIndex(-Double(depth))
                    }

                    ForEach(layers(at: current)) { layer in
                        CalendarLeaf(entry: layer.entry, angle: layer.angle, underShade: layer.underShade)
                            .zIndex(layer.zIndex)
                    }
                }
                .frame(width: pageSize.width, height: pageSize.height)

                CalendarBinding(width: pageSize.width)
                    .offset(y: -CalendarBinding.overhang)
                    .zIndex(10)
            }
            .frame(width: pageSize.width, height: pageSize.height + standDepth, alignment: .top)
            // The calendar stands on the desk, leaning back slightly.
            .rotation3DEffect(.degrees(5), axis: (x: 1, y: 0, z: 0), anchor: .bottom, perspective: 0.4)
            .contentShape(Rectangle())
            .onTapGesture {
                guard flip == 0, !isSettling else { return }
                selectedEntry = entries[current]
            }
            .gesture(flipGesture(at: current, pageHeight: pageSize.height))
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityHint("Swipe up or down to turn the page.")
            .accessibilityAction {
                selectedEntry = entries[current]
            }
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: turnPage(by: 1, from: current)
                case .decrement: turnPage(by: -1, from: current)
                @unknown default: break
                }
            }

            Text("\(current + 1) of \(entries.count)")
                .font(DaymarkTypography.metadata)
                .monospacedDigit()
                .foregroundStyle(DaymarkPalette.secondaryInk)
        }
    }

    /// The pages on screen, bottom to top. Pages keep their entry ID as identity
    /// so the page underneath does not reload when a flip completes.
    private func layers(at current: Int) -> [CalendarLayer] {
        let entry = entries[current]

        if flip < 0 {
            let angle = Double(-flip) * 180
            var result: [CalendarLayer] = []
            if current + 1 < entries.count {
                result.append(CalendarLayer(entry: entries[current + 1], angle: 0, underShade: shade(under: angle), zIndex: 0))
            }
            result.append(CalendarLayer(entry: entry, angle: angle, underShade: 0, zIndex: 1))
            return result
        }

        if flip > 0, current > 0 {
            let angle = Double(1 - flip) * 180
            return [
                CalendarLayer(entry: entry, angle: 0, underShade: shade(under: angle), zIndex: 0),
                CalendarLayer(entry: entries[current - 1], angle: angle, underShade: 0, zIndex: 1)
            ]
        }

        return [CalendarLayer(entry: entry, angle: 0, underShade: 0, zIndex: 0)]
    }

    /// The page beneath a turning leaf sits in its shadow until the leaf clears it.
    private func shade(under leafAngle: Double) -> Double {
        0.22 * max(0, 1 - leafAngle / 150)
    }

    /// Paper edges peeking out under the pad hint at how many days are still to come.
    private func underPageEdges(at current: Int) -> [Int] {
        let remaining = entries.count - 1 - current
        return remaining > 0 ? Array(1...min(remaining, 3)) : []
    }

    // MARK: - Turning pages

    private func flipGesture(at current: Int, pageHeight: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 10)
            .onChanged { value in
                guard !isSettling else { return }
                let progress = value.translation.height / (pageHeight * 0.85)
                if progress < 0 {
                    // With no next page the last leaf only lifts a little off the board.
                    flip = current + 1 < entries.count ? max(progress, -1) : max(progress * 0.25, -0.1)
                } else {
                    flip = current > 0 ? min(progress, 1) : 0
                }
            }
            .onEnded { value in
                guard !isSettling else { return }
                let projected = value.predictedEndTranslation.height / pageHeight
                if flip < 0, current + 1 < entries.count, flip < -0.35 || projected < -0.6 {
                    turnPage(by: 1, from: current)
                } else if flip > 0, current > 0, flip > 0.35 || projected > 0.6 {
                    turnPage(by: -1, from: current)
                } else {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
                        flip = 0
                    }
                }
            }
    }

    private func turnPage(by step: Int, from current: Int) {
        let target = current + step
        guard !isSettling, entries.indices.contains(target) else { return }
        isSettling = true
        let finalFlip: CGFloat = step > 0 ? -1 : 1

        // A turn started from rest (VoiceOver) needs the leaf on screen before it animates.
        if flip == 0 {
            withTransaction(Transaction(animation: nil)) {
                flip = finalFlip * 0.001
            }
        }

        Task { @MainActor in
            await Task.yield()
            let remaining = 1 - abs(flip)
            withAnimation(.easeOut(duration: 0.18 + 0.27 * Double(remaining))) {
                flip = finalFlip
            } completion: {
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    if entries.indices.contains(target) {
                        index = target
                        anchorID = entries[target].id
                    }
                    flip = 0
                }
                isSettling = false
            }
        }
    }

    private func resolvedIndex() -> Int? {
        guard !entries.isEmpty else { return nil }
        let clamped = min(max(index, 0), entries.count - 1)
        guard let anchorID, entries[clamped].id != anchorID else { return clamped }
        return entries.firstIndex { $0.id == anchorID } ?? clamped
    }

    private func prefetchNeighbours() {
        guard let current = resolvedIndex() else { return }
        for neighbour in [current + 1, current - 1] where entries.indices.contains(neighbour) {
            CalendarPhotoLoader.shared.prefetch(entries[neighbour], using: photoStore)
        }
    }
}

private struct CalendarLayer: Identifiable {
    let entry: PhotoEntry
    let angle: Double
    let underShade: Double
    let zIndex: Double

    var id: String { entry.id }
}

// MARK: - Leaf

/// One calendar page, rotating about its top edge. Animatable so the front/back
/// swap and shading follow the angle frame by frame during a flip.
private struct CalendarLeaf: View, Animatable {
    let entry: PhotoEntry
    var angle: Double
    var underShade: Double

    nonisolated var animatableData: AnimatablePair<Double, Double> {
        get { AnimatablePair(angle, underShade) }
        set {
            angle = newValue.first
            underShade = newValue.second
        }
    }

    var body: some View {
        let showsFront = angle < 90

        ZStack {
            CalendarPage(entry: entry)
                .opacity(showsFront ? 1 : 0)
            CalendarPageBack()
                .opacity(showsFront ? 0 : 1)
        }
        .overlay {
            CalendarPage.shape
                .fill(DaymarkSwatch.heiSeBlack.opacity(foldShade + underShade))
                .allowsHitTesting(false)
        }
        .shadow(color: DaymarkSwatch.heiSeBlack.opacity(angle > 0 ? 0.18 : 0.08), radius: angle > 0 ? 10 : 3, y: 2)
        .rotation3DEffect(.degrees(angle), axis: (x: 1, y: 0, z: 0), anchor: .top, perspective: 0.35)
        // Fade the leaf as it settles behind the binding instead of covering the bar.
        .opacity(angle <= 120 ? 1 : max(0, (180 - angle) / 60))
    }

    /// Darkest when the leaf is edge-on to the light.
    private var foldShade: Double {
        0.3 * min(angle, 180 - angle) / 90
    }
}

private struct CalendarPage: View {
    static let shape = UnevenRoundedRectangle(
        topLeadingRadius: 6,
        bottomLeadingRadius: 14,
        bottomTrailingRadius: 14,
        topTrailingRadius: 6,
        style: .continuous
    )

    let entry: PhotoEntry

    private let calendar = Calendar.current

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Color.clear
                .frame(height: CalendarBinding.pageInset)

            header
                .padding(.bottom, 12)

            CalendarPagePhoto(entry: entry)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(DaymarkPalette.recessed, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            footer
                .padding(.top, 12)
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DaymarkPalette.surface, in: Self.shape)
        .overlay {
            Self.shape.strokeBorder(DaymarkPalette.rule, lineWidth: 0.75)
        }
        .overlay(alignment: .top) {
            CalendarBinding.holes
        }
    }

    private var header: some View {
        HStack(alignment: .lastTextBaseline, spacing: 12) {
            Text(entry.day.formatted(.dateTime.day()))
                .font(.system(size: 60, weight: .semibold, design: .serif))
                .monospacedDigit()
                .foregroundStyle(calendar.isDateInToday(entry.day) ? DaymarkPalette.highlight : DaymarkPalette.accent)
                .lineLimit(1)
                .minimumScaleFactor(0.6)

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.day.formatted(.dateTime.weekday(.wide)))
                    .font(DaymarkTypography.entryTitle)
                    .foregroundStyle(DaymarkPalette.ink)
                Text(entry.day.formatted(.dateTime.month(.wide).year()).uppercased())
                    .font(.caption.weight(.semibold))
                    .tracking(1.2)
                    .foregroundStyle(DaymarkPalette.secondaryInk)
            }
            .lineLimit(1)
            .minimumScaleFactor(0.7)

            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(entry.day.formatted(.dateTime.weekday(.wide).month(.wide).day().year()))
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if let flagEmoji = entry.flagEmoji {
                Text(flagEmoji)
                    .font(.system(size: 20))
            }

            VStack(alignment: .leading, spacing: 1) {
                if let city = entry.city {
                    Text(city)
                        .font(DaymarkTypography.entryTitle)
                        .foregroundStyle(DaymarkPalette.ink)
                }
                if let caption = entry.caption, !caption.isEmpty {
                    Text(caption)
                        .font(DaymarkTypography.metadata)
                        .foregroundStyle(DaymarkPalette.secondaryInk)
                } else if let countryName = entry.countryName {
                    Text(countryName)
                        .font(DaymarkTypography.metadata)
                        .foregroundStyle(DaymarkPalette.secondaryInk)
                }
            }
            .lineLimit(1)

            Spacer(minLength: 0)
        }
        .frame(minHeight: 28)
    }
}

private struct CalendarPageBack: View {
    var body: some View {
        CalendarPage.shape
            .fill(DaymarkPalette.recessed)
            .overlay {
                CalendarPage.shape.strokeBorder(DaymarkPalette.rule, lineWidth: 0.75)
            }
            .overlay(alignment: .bottom) {
                // The leaf is upside down here, so the hole strip sits at the bottom.
                CalendarBinding.holes
                    .rotationEffect(.degrees(180))
            }
    }
}

private struct PageEdge: View {
    var body: some View {
        CalendarPage.shape
            .fill(DaymarkPalette.surface)
            .overlay {
                CalendarPage.shape.strokeBorder(DaymarkPalette.rule, lineWidth: 0.75)
            }
    }
}

// MARK: - Binding and stand

private struct CalendarBinding: View {
    /// How far the rings rise above the top edge of the pad.
    static let overhang: CGFloat = 10
    /// Blank strip at the top of every page that the rings pass through.
    static let pageInset: CGFloat = 26
    static let ringSpacing: CGFloat = 22

    let width: CGFloat

    static func ringCount(for width: CGFloat) -> Int {
        max(4, Int((width - 40) / ringSpacing))
    }

    static var holes: some View {
        GeometryReader { proxy in
            let count = ringCount(for: proxy.size.width)
            HStack(spacing: 0) {
                ForEach(0..<count, id: \.self) { _ in
                    Capsule()
                        .fill(DaymarkPalette.paper)
                        .overlay(Capsule().strokeBorder(DaymarkPalette.rule, lineWidth: 0.5))
                        .frame(width: 5, height: 8)
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
        }
        .frame(height: pageInset)
        .accessibilityHidden(true)
    }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(0..<Self.ringCount(for: width), id: \.self) { _ in
                Capsule()
                    .strokeBorder(
                        LinearGradient(
                            colors: [DaymarkSwatch.grauzone, DaymarkSwatch.siestaTan, DaymarkSwatch.grauzone],
                            startPoint: .leading,
                            endPoint: .trailing
                        ),
                        lineWidth: 2.5
                    )
                    .frame(width: 8, height: Self.overhang + 14)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, 20)
        .frame(width: width)
        .shadow(color: DaymarkSwatch.heiSeBlack.opacity(0.25), radius: 1, y: 1)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// The back board the pad hangs from, showing as a frame around and below the pages.
private struct DeskCalendarStand: View {
    let pageSize: CGSize
    let depth: CGFloat

    var body: some View {
        ZStack(alignment: .bottom) {
            Ellipse()
                .fill(DaymarkSwatch.heiSeBlack.opacity(0.18))
                .frame(width: pageSize.width * 1.05, height: 18)
                .blur(radius: 8)
                .offset(y: 10)

            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(DaymarkPalette.bloom)
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(DaymarkSwatch.heiSeBlack.opacity(0.25))
                }
                .frame(width: pageSize.width + 12, height: pageSize.height + depth)
        }
        .frame(width: pageSize.width, height: pageSize.height + depth, alignment: .bottom)
        .offset(y: -4)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// MARK: - Photo

/// Shows the entry's photo uncropped. Starts from a cached thumbnail when one is
/// available and swaps in the full view photo once it is decoded.
private struct CalendarPagePhoto: View {
    let entry: PhotoEntry

    @State private var image: UIImage?

    private let photoStore = PhotoStore()

    var body: some View {
        let identity = CalendarPhotoLoader.identity(for: entry)
        let shown = image ?? CalendarPhotoLoader.shared.cachedImage(for: identity)
            ?? ThumbnailImageLoader.shared.cachedImage(for: ThumbnailImageLoader.identity(for: entry))

        Group {
            if let shown {
                Image(uiImage: shown)
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: "photo")
                    .font(.system(size: 32))
                    .foregroundStyle(DaymarkPalette.secondaryInk)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: identity) {
            image = await CalendarPhotoLoader.shared.image(for: entry, using: photoStore)
        }
    }
}

/// Decodes page-sized photos off the main thread, downsampled so even a large
/// original stays light enough to rotate in 3D.
final class CalendarPhotoLoader {
    static let shared = CalendarPhotoLoader()

    private let cache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 12
        return cache
    }()
    private var inFlight: [String: Task<UIImage?, Never>] = [:]

    static func identity(for entry: PhotoEntry) -> String {
        "\(entry.id)|\(entry.localViewPhotoFilename ?? entry.localOriginalFilename ?? "legacy")"
    }

    func cachedImage(for identity: String) -> UIImage? {
        cache.object(forKey: identity as NSString)
    }

    func prefetch(_ entry: PhotoEntry, using photoStore: PhotoStore) {
        Task { _ = await image(for: entry, using: photoStore) }
    }

    func image(for entry: PhotoEntry, using photoStore: PhotoStore) async -> UIImage? {
        let identity = Self.identity(for: entry)
        if let cached = cachedImage(for: identity) {
            return cached
        }
        if let task = inFlight[identity] {
            return await task.value
        }

        // Read the files here on the main actor; only decoding moves off it.
        let data = photoStore.viewPhotoData(for: entry)
            ?? photoStore.originalData(for: entry)
            ?? photoStore.thumbnailData(for: entry)
        guard let data else { return nil }

        let task = Task.detached(priority: .userInitiated) {
            Self.decode(data, maxPixelSize: 2048)
        }
        inFlight[identity] = task
        let image = await task.value
        inFlight[identity] = nil
        if let image {
            cache.setObject(image, forKey: identity as NSString)
        }
        return image
    }

    private nonisolated static func decode(_ data: Data, maxPixelSize: Int) -> UIImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else { return nil }
        let thumbnailOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ] as [CFString: Any] as CFDictionary
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}

#Preview {
    DeskCalendarView()
        .modelContainer(for: PhotoEntry.self, inMemory: true)
}
