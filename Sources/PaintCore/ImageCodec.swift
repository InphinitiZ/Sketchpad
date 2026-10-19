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

    public static func decode(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    public static func encode(_ image: CGImage, as type: UTType, jpegQuality: Double = 0.9) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else {
            throw Failure.unsupportedType(type.identifier)
        }
        var options: [CFString: Any] = [:]
        if type.conforms(to: .jpeg) {
            options[kCGImageDestinationLossyCompressionQuality] = jpegQuality
        }
        // JPEG and BMP carry no useful alpha; write them from an opaque copy.
        let output = type.conforms(to: .png) ? image : (opaqueCopy(of: image) ?? image)
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
