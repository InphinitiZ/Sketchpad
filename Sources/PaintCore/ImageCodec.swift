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
        let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
        let dpi = (properties?[kCGImagePropertyDPIWidth] as? NSNumber)?.doubleValue ?? defaultDotsPerInch
        return Decoded(image: image, dotsPerInch: dpi > 0 ? dpi : defaultDotsPerInch)
    }

    public static func encode(
        _ image: CGImage,
        as type: UTType,
        jpegQuality: Double = 0.9,
        dotsPerInch: Double = defaultDotsPerInch
    ) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else {
            throw Failure.unsupportedType(type.identifier)
        }
        var options: [CFString: Any] = [
            kCGImagePropertyDPIWidth: dotsPerInch,
            kCGImagePropertyDPIHeight: dotsPerInch,
        ]
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
