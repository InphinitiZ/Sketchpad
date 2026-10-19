import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Reads and writes image files through ImageIO.
public enum ImageCodec {
    public enum Failure: Error {
        case unsupportedType(String)
        case encodingFailed
    }

    /// Paint's default resolution ("96 DPI" in Image Properties).
    public static let defaultDotsPerInch: Double = 96

    public struct Decoded {
        public let image: CGImage
        public let dotsPerInch: Double
        /// The file's format, such as `public.jpeg`.
        public let typeIdentifier: String?
        /// The frame's metadata as ImageIO reports it (EXIF, GPS, TIFF, IPTC …), kept so a save
        /// in the same format can carry it over.
        public let metadata: [CFString: Any]
        /// The EXIF orientation, 1 (as stored) to 8.
        public let orientation: Int

        /// Paint turns JPEG photos upright by their EXIF orientation as it opens them
        /// (`LoadDIBGdiplus` reads tag 0x112 and calls `GdipImageRotateFlip`). HEIC photos are
        /// turned too, since on the Mac they are the camera's format.
        public var opensUpright: Bool {
            guard orientation != 1, let type = typeIdentifier.flatMap(UTType.init) else { return false }
            return type.conforms(to: .jpeg) || type.conforms(to: .heic) || type.conforms(to: .heif)
        }
    }

    public static func decode(_ data: Data) -> CGImage? {
        decodeWithResolution(data)?.image
    }

    /// The largest image in the file (icons and TIFFs can hold several) and its resolution.
    public static func decodeWithResolution(_ data: Data) -> Decoded? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let candidates = (0..<CGImageSourceGetCount(source)).compactMap { index -> (Int, CGImage)? in
            CGImageSourceCreateImageAtIndex(source, index, nil).map { (index, $0) }
        }
        guard let (index, image) = candidates.max(by: { $0.1.width * $0.1.height < $1.1.width * $1.1.height }) else {
            return nil
        }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any] ?? [:]
        let dpi = (properties[kCGImagePropertyDPIWidth] as? NSNumber)?.doubleValue ?? defaultDotsPerInch
        return Decoded(
            image: image,
            dotsPerInch: dpi > 0 ? dpi : defaultDotsPerInch,
            typeIdentifier: CGImageSourceGetType(source) as String?,
            metadata: properties,
            orientation: (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        )
    }

    /// The format and first frame's metadata of an image file, without decoding its pixels.
    public static func metadata(of url: URL) -> (typeIdentifier: String?, metadata: [CFString: Any])? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        return (CGImageSourceGetType(source) as String?, properties)
    }

    /// The parts of `metadata` that describe the photo rather than the pixels (camera, date,
    /// place, captions), ready to write with a new picture of `width`×`height`. Like Paint,
    /// which copies the original's metadata blocks and then sets System.Photo.Orientation to 1,
    /// the picture is marked upright: its pixels already are.
    public static func carriedMetadata(_ metadata: [CFString: Any], width: Int, height: Int) -> [CFString: Any] {
        let kept: [CFString] = [
            kCGImagePropertyExifDictionary, kCGImagePropertyGPSDictionary, kCGImagePropertyIPTCDictionary,
            kCGImagePropertyTIFFDictionary, kCGImagePropertyExifAuxDictionary, kCGImagePropertyMakerAppleDictionary,
            kCGImagePropertyMakerCanonDictionary, kCGImagePropertyMakerNikonDictionary,
        ]
        var result: [CFString: Any] = [:]
        for key in kept { if let value = metadata[key] { result[key] = value } }
        if var exif = result[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            exif[kCGImagePropertyExifPixelXDimension] = width
            exif[kCGImagePropertyExifPixelYDimension] = height
            result[kCGImagePropertyExifDictionary] = exif
        }
        if var tiff = result[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            tiff[kCGImagePropertyTIFFOrientation] = 1
            result[kCGImagePropertyTIFFDictionary] = tiff
        }
        result[kCGImagePropertyOrientation] = 1
        return result
    }

    /// Writes `image` as `type`. `metadata` (from `carriedMetadata`) is written with it.
    public static func encode(
        _ image: CGImage,
        as type: UTType,
        jpegQuality: Double = 0.9,
        dotsPerInch: Double = defaultDotsPerInch,
        metadata: [CFString: Any]? = nil
    ) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else {
            throw Failure.unsupportedType(type.identifier)
        }
        var options = metadata ?? [:]
        options[kCGImagePropertyDPIWidth] = dotsPerInch
        options[kCGImagePropertyDPIHeight] = dotsPerInch
        if metadata != nil, type.conforms(to: .jpeg) {
            // Paint writes a fresh, upright thumbnail with the copied metadata.
            options[kCGImageDestinationEmbedThumbnail] = true
        }
        if type.conforms(to: .jpeg) {
            options[kCGImageDestinationLossyCompressionQuality] = jpegQuality
        }
        // Only PNG and TIFF keep alpha usefully; write the others from an opaque copy.
        let keepsAlpha = type.conforms(to: .png) || type.conforms(to: .tiff)
        let output = keepsAlpha ? image : (opaqueCopy(of: image) ?? image)
        CGImageDestinationAddImage(destination, output, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw Failure.encodingFailed }
        return data as Data
    }

    private static func opaqueCopy(of image: CGImage) -> CGImage? {
        guard let context = CGContext(
            data: nil,
            width: image.width,
            height: image.height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        context.setFillColor(RGBA.white.cgColor)
        context.fill(rect)
        context.draw(image, in: rect)
        return context.makeImage()
    }
}
