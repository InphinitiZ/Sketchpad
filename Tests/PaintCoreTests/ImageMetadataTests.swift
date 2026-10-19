import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import PaintCore

/// A JPEG of `grid` with camera metadata and the given EXIF orientation.
func photoJPEG(_ grid: PixelGrid, orientation: Int) throws -> Data {
    let image = try #require(Bitmap(grid: grid).makeImage())
    let data = NSMutableData()
    let destination = try #require(CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil))
    let properties: [CFString: Any] = [
        kCGImagePropertyOrientation: orientation,
        kCGImageDestinationLossyCompressionQuality: 1.0,
        kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "Sketchpad Camera", kCGImagePropertyTIFFOrientation: orientation],
        kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2026:10:19 08:30:00"],
        kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 31.23, kCGImagePropertyGPSLatitudeRef: "N"],
    ]
    CGImageDestinationAddImage(destination, image, properties as CFDictionary)
    #expect(CGImageDestinationFinalize(destination))
    return data as Data
}

@Suite struct ImageMetadataTests {
    /// 3×2:  1 2 3 / 4 5 6
    let grid = PixelGrid(width: 3, height: 2, pixels: [1, 2, 3, 4, 5, 6])

    @Test func everyEXIFOrientationTurnsUpright() {
        #expect(grid.upright(fromEXIFOrientation: 1) == grid)
        #expect(grid.upright(fromEXIFOrientation: 2).pixels == [3, 2, 1, 6, 5, 4])
        #expect(grid.upright(fromEXIFOrientation: 3).pixels == [6, 5, 4, 3, 2, 1])
        #expect(grid.upright(fromEXIFOrientation: 4).pixels == [4, 5, 6, 1, 2, 3])
        // Transpose: rows become columns.
        let transposed = grid.upright(fromEXIFOrientation: 5)
        #expect(transposed.width == 2 && transposed.pixels == [1, 4, 2, 5, 3, 6])
        #expect(grid.upright(fromEXIFOrientation: 6).pixels == [4, 1, 5, 2, 6, 3])
        #expect(grid.upright(fromEXIFOrientation: 7).pixels == [6, 3, 5, 2, 4, 1])
        #expect(grid.upright(fromEXIFOrientation: 8).pixels == [3, 6, 2, 5, 1, 4])
    }

    @Test func decodingReportsOrientationAndMetadata() throws {
        let decoded = try #require(ImageCodec.decodeWithResolution(photoJPEG(grid, orientation: 6)))
        #expect(decoded.orientation == 6)
        #expect(decoded.opensUpright)
        #expect(decoded.typeIdentifier == UTType.jpeg.identifier)
        let tiff = decoded.metadata[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        #expect(tiff?[kCGImagePropertyTIFFMake] as? String == "Sketchpad Camera")
    }

    @Test func carriedMetadataSurvivesASaveAndIsMarkedUpright() throws {
        let decoded = try #require(ImageCodec.decodeWithResolution(photoJPEG(grid, orientation: 6)))
        let carried = ImageCodec.carriedMetadata(decoded.metadata, width: 2, height: 3)
        #expect(carried[kCGImagePropertyOrientation] as? Int == 1)
        let image = try #require(Bitmap(grid: grid.upright(fromEXIFOrientation: 6)).makeImage())
        let saved = try ImageCodec.encode(image, as: .jpeg, metadata: carried)

        let reread = try #require(ImageCodec.decodeWithResolution(saved))
        #expect(reread.orientation == 1, "the pixels are upright now")
        let exif = reread.metadata[kCGImagePropertyExifDictionary] as? [CFString: Any]
        #expect(exif?[kCGImagePropertyExifDateTimeOriginal] as? String == "2026:10:19 08:30:00")
        let gps = reread.metadata[kCGImagePropertyGPSDictionary] as? [CFString: Any]
        #expect((gps?[kCGImagePropertyGPSLatitude] as? Double).map { abs($0 - 31.23) < 0.001 } == true)
        let tiff = reread.metadata[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        #expect(tiff?[kCGImagePropertyTIFFMake] as? String == "Sketchpad Camera")
    }

    @Test func pngsAreNotTurned() throws {
        let image = try #require(Bitmap(grid: grid).makeImage())
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyOrientation: 6] as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        let decoded = try #require(ImageCodec.decodeWithResolution(data as Data))
        #expect(!decoded.opensUpright, "Paint turns only JPEG photos")
    }
}
