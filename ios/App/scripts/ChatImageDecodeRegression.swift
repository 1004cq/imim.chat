import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

@main
@MainActor
struct ChatImageDecodeRegression {
    static var checks = 0
    static func check(_ condition: Bool, _ note: String) {
        precondition(condition, note)
        checks += 1
    }

    static func fixture(width: Int, height: Int, orientation: Int = 1, png: Bool = false) throws -> Data {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.2, green: 0.6, blue: 0.9, alpha: png ? 0.5 : 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let output = NSMutableData()
        let type = png ? UTType.png.identifier : UTType.jpeg.identifier
        let destination = CGImageDestinationCreateWithData(output, type as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, [
            kCGImagePropertyOrientation: orientation,
            kCGImageDestinationLossyCompressionQuality: 0.85
        ] as CFDictionary)
        check(CGImageDestinationFinalize(destination), "fixture encoding")
        return output as Data
    }

    static func main() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("imim-image-fixtures-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let decoder = ChatImageDecoder()
        let target = CGSize(width: 570, height: 420)
        let data = try fixture(width: 4000, height: 3000)
        let file = directory.appendingPathComponent("photo.jpg")
        try data.write(to: file)
        let image = try await decoder.decode(fileURL: file, targetPixels: target, fill: true)
        check(image.width == 570 && abs(image.height - 428) <= 1, "fill thumbnail dimensions")
        let bytes = image.bytesPerRow * image.height
        let fullBytes = 4000 * 3000 * 4
        check(bytes < fullBytes / 40, "decoded raster below one-fortieth of full photo")
        print("Synthetic 4000x3000 JPEG: full RGBA reference \(fullBytes) bytes; actual thumbnail \(image.width)x\(image.height), \(bytes) bytes")
        let memoryImage = try await decoder.decode(data: data, targetPixels: target, fill: true)
        check(image.width == memoryImage.width && image.height == memoryImage.height, "file/data entry parity")
        let fit = try await decoder.decode(data: data, targetPixels: target, fill: false)
        check(fit.width <= 570 && fit.height <= 420, "fit dimensions stay inside target")
        check(abs(Double(fit.width) / Double(fit.height) - 4.0 / 3) < 0.01, "fit aspect ratio")

        for orientation in 1...8 {
            let rotatedData = try fixture(width: 4000, height: 3000, orientation: orientation)
            let rotated = try await decoder.decode(data: rotatedData, targetPixels: target, fill: true)
            let portrait = (5...8).contains(orientation)
            check(rotated.width == 570, "orientation \(orientation) fill width")
            check(abs(rotated.height - (portrait ? 760 : 428)) <= 1, "orientation \(orientation) transformed height")
        }
        let small = try await decoder.decode(data: fixture(width: 80, height: 60), targetPixels: target, fill: true)
        check(small.width == 80 && small.height == 60, "do not upscale small source")
        let alpha = try await decoder.decode(data: fixture(width: 600, height: 800, png: true), targetPixels: target, fill: true)
        check(alpha.alphaInfo != .none && alpha.alphaInfo != .noneSkipFirst && alpha.alphaInfo != .noneSkipLast, "PNG alpha retained")
        let extreme = try await decoder.decode(data: fixture(width: 10000, height: 1000), targetPixels: target, fill: true)
        check(max(extreme.width, extreme.height) <= 4096, "extreme aspect edge cap")
        let bounded = try await decoder.decode(data: data, targetPixels: CGSize(width: 100000, height: 100000), fill: true)
        check(bounded.width * bounded.height <= 4_010_000, "four megapixel cap allowing ImageIO rounding")
        for invalid in [CGSize.zero, CGSize(width: -1, height: 10), CGSize(width: CGFloat.infinity, height: 10), CGSize(width: CGFloat.nan, height: 10)] {
            do {
                _ = try await decoder.decode(data: data, targetPixels: invalid, fill: true)
                check(false, "invalid target must throw")
            } catch ChatImageDecoder.DecodeError.invalidTarget { check(true, "invalid target rejected") }
        }
        for invalidData in [Data(), Data("not an image".utf8)] {
            do {
                _ = try await decoder.decode(data: invalidData, targetPixels: target, fill: true)
                check(false, "invalid data must throw")
            } catch ChatImageDecoder.DecodeError.invalidImage { check(true, "invalid image rejected") }
        }
        for invalidURL in [directory.appendingPathComponent("missing.jpg"), URL(string: "https://example.invalid/photo.jpg")!] {
            do {
                _ = try await decoder.decode(fileURL: invalidURL, targetPixels: target, fill: true)
                check(false, "invalid URL must throw without network")
            } catch ChatImageDecoder.DecodeError.invalidImage { check(true, "invalid URL rejected") }
        }
        let cancelled = Task { () throws -> CGImage in
            withUnsafeCurrentTask { $0?.cancel() }
            return try await decoder.decode(data: data, targetPixels: target, fill: true)
        }
        do { _ = try await cancelled.value; check(false, "cancelled decode must throw") }
        catch is CancellationError { check(true, "cancellation before decode") }
        print("PASS: \(checks) image decoder checks; strict Swift 6; decoding asserted off UI thread. No owner files/cache/API used.")
    }
}
