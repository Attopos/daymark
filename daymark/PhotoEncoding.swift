import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import UIKit
import UniformTypeIdentifiers

/// How Daymark stores a photo on disk and in iCloud.
///
/// Since storage format 2 the kept "original" is no longer the camera's file.
/// It is a bounded HEIC rendition: the long edge is capped and the encoder
/// quality is stepped down until the file fits a byte budget, so one day costs
/// roughly 1 MB instead of 3-25 MB. Capture date, GPS and the other EXIF
/// metadata are carried over; orientation is baked into the pixels.
nonisolated enum PhotoEncoding {
    /// Bump when the rules below change in a way that should re-encode the
    /// existing library. Entries remember the version they were stored with.
    static let storageVersion = 2

    struct Profile: Sendable {
        let maxPixelSize: CGFloat
        let qualities: [CGFloat]
        let byteBudget: Int
        /// A source already within these limits is kept byte for byte.
        let passThroughBytes: Int
    }

    static let original = Profile(
        maxPixelSize: 3_072,
        qualities: [0.78, 0.68, 0.58, 0.48],
        byteBudget: 1_400_000,
        passThroughBytes: 1_800_000
    )

    static let viewPhoto = Profile(
        maxPixelSize: 2_048,
        qualities: [0.72, 0.62, 0.52],
        byteBudget: 450_000,
        passThroughBytes: 0
    )

    static let thumbnail = Profile(
        maxPixelSize: 300,
        qualities: [0.8],
        byteBudget: .max,
        passThroughBytes: 0
    )

    static var heicIsAvailable: Bool {
        let types = CGImageDestinationCopyTypeIdentifiers() as? [String] ?? []
        return types.contains(UTType.heic.identifier)
    }

    /// The bytes Daymark keeps as a day's photo. Returns `data` unchanged when
    /// it is already within the size and pixel limits.
    static func storedOriginal(from data: Data) throws -> Data {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0 else {
            throw PhotoStoreError.invalidImageData
        }
        if !needsReencoding(source: source, byteCount: data.count, profile: original) {
            return data
        }
        return try encode(source: source, profile: original, keepMetadata: true)
    }

    static func rendition(from data: Data, profile: Profile) throws -> Data {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0 else {
            throw PhotoStoreError.invalidImageData
        }
        return try encode(source: source, profile: profile, keepMetadata: false)
    }

    /// The stored original for an edited image (edits carry no camera EXIF).
    /// `cgImage` must already be upright (see `UIImage.normalizedImage()`).
    static func storedOriginal(from cgImage: CGImage) throws -> Data {
        let scaled = try downscaled(cgImage, maxPixelSize: original.maxPixelSize)
        return try encode(cgImage: scaled, properties: [:], profile: original)
    }

    /// Whether an already stored original is over today's limits.
    static func isOverLimits(_ data: Data) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0 else { return false }
        return needsReencoding(source: source, byteCount: data.count, profile: original)
    }

    static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Internals

    private static func needsReencoding(
        source: CGImageSource,
        byteCount: Int,
        profile: Profile
    ) -> Bool {
        // Any format ImageIO decodes is kept as is while it is small enough.
        guard byteCount <= profile.passThroughBytes else { return true }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let width = (properties?[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue ?? .infinity
        let height = (properties?[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue ?? .infinity
        return max(width, height) > profile.maxPixelSize
    }

    private static func encode(
        source: CGImageSource,
        profile: Profile,
        keepMetadata: Bool
    ) throws -> Data {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: profile.maxPixelSize
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw PhotoStoreError.invalidImageData
        }
        let properties = keepMetadata ? carriedMetadata(from: source) : [:]
        return try encode(cgImage: cgImage, properties: properties, profile: profile)
    }

    private static func encode(
        cgImage: CGImage,
        properties: [CFString: Any],
        profile: Profile
    ) throws -> Data {
        var smallest: Data?
        for quality in profile.qualities {
            let data = try encodeOnce(cgImage, properties: properties, quality: quality)
            if smallest.map({ data.count < $0.count }) ?? true { smallest = data }
            if data.count <= profile.byteBudget { return data }
        }
        guard let smallest else { throw PhotoStoreError.invalidImageData }
        return smallest
    }

    private static func encodeOnce(
        _ cgImage: CGImage,
        properties: [CFString: Any],
        quality: CGFloat
    ) throws -> Data {
        let type = heicIsAvailable ? UTType.heic : UTType.jpeg
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output as CFMutableData, type.identifier as CFString, 1, nil
        ) else {
            throw PhotoStoreError.invalidImageData
        }
        var imageProperties = properties
        imageProperties[kCGImageDestinationLossyCompressionQuality] = quality
        CGImageDestinationAddImage(destination, cgImage, imageProperties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw PhotoStoreError.invalidImageData
        }
        return output as Data
    }

    /// EXIF/GPS/TIFF dictionaries minus anything that describes the old pixels
    /// (orientation, dimensions), since the rendition is upright and smaller.
    private static func carriedMetadata(from source: CGImageSource) -> [CFString: Any] {
        guard var properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return [:]
        }
        for key in [kCGImagePropertyOrientation, kCGImagePropertyPixelWidth, kCGImagePropertyPixelHeight,
                    kCGImagePropertyDepth, kCGImagePropertyMakerAppleDictionary] {
            properties.removeValue(forKey: key)
        }
        if var tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            tiff.removeValue(forKey: kCGImagePropertyTIFFOrientation)
            properties[kCGImagePropertyTIFFDictionary] = tiff
        }
        if var exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            exif.removeValue(forKey: kCGImagePropertyExifPixelXDimension)
            exif.removeValue(forKey: kCGImagePropertyExifPixelYDimension)
            properties[kCGImagePropertyExifDictionary] = exif
        }
        return properties
    }

    private static func downscaled(_ image: CGImage, maxPixelSize: CGFloat) throws -> CGImage {
        let longEdge = CGFloat(max(image.width, image.height))
        guard longEdge > maxPixelSize else { return image }
        let scale = maxPixelSize / longEdge
        let width = max(1, Int((CGFloat(image.width) * scale).rounded()))
        let height = max(1, Int((CGFloat(image.height) * scale).rounded()))
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) ?? CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw PhotoStoreError.invalidImageData }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let scaled = context.makeImage() else { throw PhotoStoreError.invalidImageData }
        return scaled
    }
}
