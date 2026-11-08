import AVFoundation
import CoreImage
import UIKit

@main struct DualCameraRegression {
    static var checks = 0
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        precondition(condition(), message); checks += 1
    }

    static func solid(_ red: UInt8, _ green: UInt8, _ blue: UInt8, width: Int = 1280, height: Int = 720) -> CVPixelBuffer {
        var value: CVPixelBuffer?
        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA,
                            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &value)
        let buffer = value!
        CVPixelBufferLockBaseAddress(buffer, [])
        let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        for y in 0..<height {
            for x in 0..<width {
                let offset = y * stride + x * 4
                base[offset] = blue; base[offset + 1] = green; base[offset + 2] = red; base[offset + 3] = 255
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        return buffer
    }

    static func pixel(_ buffer: CVPixelBuffer, x: Int, y: Int) -> [UInt8] {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let pointer = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        let offset = y * CVPixelBufferGetBytesPerRow(buffer) + x * 4
        return Array(UnsafeBufferPointer(start: pointer + offset, count: 4))
    }

    static let imageContext = CIContext(options: [.cacheIntermediates: false])
    static func rgba(_ image: CIImage, at point: CGPoint) -> [UInt8] {
        var result = [UInt8](repeating: 0, count: 4)
        result.withUnsafeMutableBytes {
            imageContext.render(image, toBitmap: $0.baseAddress!, rowBytes: 4,
                                bounds: CGRect(x: point.x, y: point.y, width: 1, height: 1),
                                format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
        }
        return result
    }

    static func orientationMarker() -> CIImage {
        // Non-square, asymmetric quadrants catch a sideways sensor and a mirror
        // applied before rotation. Coordinates here are always Core Image's.
        var image = CIImage(color: .red).cropped(to: CGRect(x: 0, y: 0, width: 80, height: 120))
        for (color, rect) in [(CIColor.green, CGRect(x: 40, y: 0, width: 40, height: 60)),
                              (CIColor.blue, CGRect(x: 0, y: 60, width: 40, height: 60)),
                              (CIColor(red: 1, green: 1, blue: 0), CGRect(x: 40, y: 60, width: 40, height: 60))] {
            image = CIImage(color: color).cropped(to: rect).composited(over: image)
        }
        return image
    }

    static func audio(at pts: CMTime) -> CMSampleBuffer {
        var description = AudioStreamBasicDescription(mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked, mBytesPerPacket: 2,
            mFramesPerPacket: 1, mBytesPerFrame: 2, mChannelsPerFrame: 1, mBitsPerChannel: 16, mReserved: 0)
        var format: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(allocator: nil, asbd: &description, layoutSize: 0, layout: nil,
                                      magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &format)
        var block: CMBlockBuffer?
        CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: 4000,
            blockAllocator: nil, customBlockSource: nil, offsetToData: 0, dataLength: 4000, flags: 0, blockBufferOut: &block)
        CMBlockBufferFillDataBytes(with: 0, blockBuffer: block!, offsetIntoDestination: 0, dataLength: 4000)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 48_000), presentationTimeStamp: pts, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        CMSampleBufferCreateReady(allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: 2000,
            sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sample)
        return sample!
    }

    static func finish(_ writer: DualCameraMovieWriter) async -> Result<URL, Error> {
        await withCheckedContinuation { continuation in writer.finish { continuation.resume(returning: $0) } }
    }

    static func main() async throws {
        let marker = orientationMarker()
        let expectedCorners: [CGFloat: [[UInt8]]] = [
            0: [[255, 0, 0], [0, 255, 0], [0, 0, 255], [255, 255, 0]],
            90: [[0, 255, 0], [255, 255, 0], [255, 0, 0], [0, 0, 255]],
            180: [[255, 255, 0], [0, 0, 255], [0, 255, 0], [255, 0, 0]],
            270: [[0, 0, 255], [255, 0, 0], [255, 255, 0], [0, 255, 0]],
        ]
        for angle: CGFloat in [0, 90, 180, 270] {
            for mirrored in [false, true] {
                let image = DualCameraFrameOrientation(clockwiseDegrees: angle, mirrored: mirrored).upright(marker)
                let rotated = angle == 90 || angle == 270
                check(abs(image.extent.width - (rotated ? 120 : 80)) < 0.01 &&
                      abs(image.extent.height - (rotated ? 80 : 120)) < 0.01, "sensor rotation preserves the complete non-square image")
                check(abs(image.extent.minX) < 0.01 && abs(image.extent.minY) < 0.01, "rotation rebases negative extents before crop")
                let points = [CGPoint(x: image.extent.width / 4, y: image.extent.height / 4),
                              CGPoint(x: image.extent.width * 3 / 4, y: image.extent.height / 4),
                              CGPoint(x: image.extent.width / 4, y: image.extent.height * 3 / 4),
                              CGPoint(x: image.extent.width * 3 / 4, y: image.extent.height * 3 / 4)]
                let order = mirrored ? [1, 0, 3, 2] : [0, 1, 2, 3]
                for index in points.indices {
                    check(Array(rgba(image, at: points[index]).prefix(3)) == expectedCorners[angle]![order[index]],
                          "clockwise camera orientation and upright selfie mirror preserve quadrant positions")
                }
            }
        }
        let shifted = marker.transformed(by: CGAffineTransform(translationX: 13, y: -7))
        let shiftedResult = DualCameraFrameOrientation(clockwiseDegrees: 0, mirrored: true).upright(shifted)
        check(shiftedResult.extent == marker.extent, "offset source extent is normalized before mirroring")

        var automaticLight = CameraAutoFlashPolicy()
        check(automaticLight.needsLight(at: 1) == nil, "no brightness must not invent an auto decision")
        automaticLight.record(brightnessValue: -2, aperture: 0, shutterSeconds: 0, iso: 0, at: 1)
        check(automaticLight.needsLight(at: 1.1) == true, "dark APEX metadata requests light")
        check(automaticLight.needsLight(at: 2.1) == nil, "stale brightness is not used")
        check(automaticLight.needsLight(at: 0.9) == nil, "clock reversal invalidates auto decision")
        automaticLight.reset()
        automaticLight.record(brightnessValue: 3, aperture: 0, shutterSeconds: 0, iso: 0, at: 2)
        check(automaticLight.needsLight(at: 2.1) == false, "bright scene avoids unnecessary light")
        automaticLight.reset()
        automaticLight.record(brightnessValue: nil, aperture: 1.8, shutterSeconds: 1.0 / 24, iso: 800, at: 3)
        check(automaticLight.needsLight(at: 3.1) == true, "exposure fallback detects dim scene")
        automaticLight.reset()
        automaticLight.record(brightnessValue: .nan, aperture: 1.8, shutterSeconds: 1.0 / 1000, iso: 100, at: 4)
        check(automaticLight.needsLight(at: 4.1) == false, "invalid EXIF uses valid exposure fallback")
        automaticLight.reset()
        automaticLight.record(brightnessValue: nil, aperture: 1.8, shutterSeconds: 0, iso: 100, at: 5)
        check(automaticLight.needsLight(at: 5) == nil, "invalid exposure is rejected")
        for index in 0..<5 { automaticLight.record(brightnessValue: index == 2 ? -10 : 4, aperture: 1.8, shutterSeconds: 0.01, iso: 100, at: 6 + Double(index) * 0.02) }
        check(automaticLight.needsLight(at: 6.2) == false, "one transitional frame cannot enable flash")
        automaticLight.record(brightnessValue: -2, aperture: 1.8, shutterSeconds: 0.01, iso: 100, at: 9)
        check(automaticLight.needsLight(at: 9.1) == true, "gap drops obsolete scene history")
        automaticLight.reset()
        check(automaticLight.needsLight(at: 10) == nil, "mode/lifecycle reset drops old light measurements")
        let firstEngine = DualCameraCaptureEngine(), otherEngine = DualCameraCaptureEngine()
        let firstOwner = UUID(), otherOwner = UUID()
        check(CameraHardwareLease.acquire(firstOwner, engine: firstEngine), "first owner acquires camera")
        check(!CameraHardwareLease.acquire(otherOwner, engine: otherEngine), "simultaneous owner rejected")
        CameraHardwareLease.release(otherOwner)
        check(CameraHardwareLease.current() === firstEngine, "wrong owner cannot release active capture")
        CameraHardwareLease.release(firstOwner)
        check(CameraHardwareLease.acquire(otherOwner, engine: otherEngine), "new capture acquires after release")
        CameraHardwareLease.release(otherOwner)
        check(CameraHardwareLease.current() == nil, "stop releases camera owner")
        let viewport = CGSize(width: 430, height: 932)
        let centerPoint = DualCameraGeometry.captureCenter(for: CGPoint(x: 215, y: 466), viewport: viewport)
        check(abs(centerPoint.x - 0.5) < 0.001 && abs(centerPoint.y - 0.5) < 0.001, "fullscreen center maps to encoded center")
        let dragged = DualCameraGeometry.captureCenter(for: CGPoint(x: 260, y: 300), viewport: viewport)
        let scale = max(viewport.width / 720, viewport.height / 1280)
        let offset = CGPoint(x: (viewport.width - 720 * scale) / 2, y: (viewport.height - 1280 * scale) / 2)
        check(abs(dragged.x * 720 * scale + offset.x - 260) < 0.01, "drag accounts for horizontal aspect-fill crop")
        check(abs((1 - dragged.y) * 1280 * scale + offset.y - 300) < 0.01, "drag converts vertical image origin")
        for view in [viewport, CGSize(width: 932, height: 430), CGSize(width: 320, height: 568)] {
            for point in [CGPoint.zero, CGPoint(x: view.width, y: view.height)] {
                let center = DualCameraGeometry.captureCenter(for: point, viewport: view)
                let circle = DualCameraGeometry.insetRect(center: center)
                let scale = max(view.width / 720, view.height / 1280)
                let x = circle.midX * scale + (view.width - 720 * scale) / 2
                let y = (1280 - circle.midY) * scale + (view.height - 1280 * scale) / 2
                let radius = circle.width * scale / 2
                check(x - radius >= 15.9 && x + radius <= view.width - 15.9, "circle stays inside fullscreen horizontal crop")
                check(y - radius >= 15.9 && y + radius <= view.height - 15.9, "circle stays inside fullscreen vertical crop")
            }
        }
        let emptyViewport = DualCameraGeometry.captureCenter(for: .zero, viewport: .zero)
        check(emptyViewport == CGPoint(x: 0.5, y: 0.5), "zero-size layout remains finite")
        var cadence = DualCameraFrameCadence()
        var count = 0
        for index in 0..<120 {
            if cadence.accepts(CMTime(value: Int64(index), timescale: 30)) { count += 1 }
        }
        check(count == 96, "30 fps resampled to 24, not 15")
        check(!cadence.accepts(CMTime(value: 119, timescale: 30)), "duplicate capture timestamp ignored")
        check(cadence.accepts(CMTime(value: 20, timescale: 1)), "resume after a long gap")
        check(cadence.accepts(CMTime(value: 1, timescale: 1)), "clock discontinuity resets scheduling")
        check(!cadence.accepts(.invalid), "invalid timestamp rejected")
        cadence.reset()
        check(cadence.accepts(.zero), "explicit session reset allows first frame")
        let red = solid(255, 0, 0), blue = solid(0, 0, 255, width: 720, height: 1280)
        let compositor = DualCameraCompositor()
        let center = CGPoint(x: 0.5, y: 0.5)
        let frame = compositor.compose(main: red, inset: blue, center: center)!
        check(CVPixelBufferGetWidth(frame) == 720 && CVPixelBufferGetHeight(frame) == 1280, "fixed encoded extent")
        check(pixel(frame, x: 360, y: 640)[0] > 240, "inset center is second camera")
        check(pixel(frame, x: 10, y: 10)[2] > 240, "main camera fills background")
        check(pixel(frame, x: 245, y: 525)[2] > 240, "circle corner exposes main camera, not square crop")
        let moved = compositor.compose(main: blue, inset: red, center: CGPoint(x: 0, y: 1))!
        let rect = DualCameraGeometry.insetRect(center: CGPoint(x: 0, y: 1))
        check(rect.minX >= 16 && rect.maxY <= 1264, "inset clamped inside output")
        // CVPixelBuffer rows and Core Image coordinates use opposite vertical origins.
        let sampleA = pixel(moved, x: Int(rect.midX), y: Int(rect.midY))
        let sampleB = pixel(moved, x: Int(rect.midX), y: 1280 - Int(rect.midY))
        check(sampleA[2] > 240 || sampleB[2] > 240, "swapping and moving are applied to encoded pixels")
        let data = compositor.jpeg(frame)!
        let jpeg = UIImage(data: data)!
        check(jpeg.size == CGSize(width: 720, height: 1280), "JPEG contains composed resolution")
        let transform = DualCameraGeometry.aspectFill(CGRect(x: 5, y: 7, width: 1280, height: 720),
                                                       into: CGRect(x: 0, y: 0, width: 720, height: 1280))
        let fitted = CGRect(x: 5, y: 7, width: 1280, height: 720).applying(transform)
        check(fitted.width >= 720 && fitted.height >= 1280, "aspect fill never leaves black bars")
        check(abs(fitted.midX - 360) < 0.01 && abs(fitted.midY - 640) < 0.01, "aspect fill centered")
        let portraitFront = solid(0, 0, 0, width: 80, height: 120)
        imageContext.render(marker, to: portraitFront, bounds: marker.extent, colorSpace: CGColorSpaceCreateDeviceRGB())
        let frontOrientation = DualCameraFrameOrientation(clockwiseDegrees: 0, mirrored: true)
        let portraitComposite = compositor.compose(main: red, inset: portraitFront, center: center,
                                                   insetOrientation: frontOrientation)!
        let compositeImage = CIImage(cvPixelBuffer: portraitComposite)
        let upperLeft = CGPoint(x: 320, y: 680), upperRight = CGPoint(x: 400, y: 680)
        check(Array(rgba(compositeImage, at: upperLeft).prefix(3)) == [255, 255, 0], "portrait front sensor is upright in circular inset")
        check(Array(rgba(compositeImage, at: upperRight).prefix(3)) == [0, 0, 255], "front selfie mirror is applied after sensor rotation")
        let photoImage = CIImage(data: compositor.jpeg(portraitComposite)!)!
        let photoCorner = rgba(photoImage, at: upperLeft)
        check(photoCorner[0] > 230 && photoCorner[1] > 230 && photoCorner[2] < 25, "JPEG retains the same upright circular inset")
        let swapped = compositor.compose(main: portraitFront, inset: red, center: center,
                                          mainOrientation: frontOrientation)!
        check(Array(rgba(CIImage(cvPixelBuffer: swapped), at: CGPoint(x: 100, y: 1100)).prefix(3)) == [255, 255, 0], "orientation follows the front camera when promoted to main")
        var retained: [CVPixelBuffer] = []
        for _ in 0..<12 { if let result = compositor.compose(main: red, inset: nil, center: center) { retained.append(result) } }
        check(retained.count <= 6, "buffer pool has bounded allocations including retained outputs")
        check(compositor.compose(main: red, inset: nil, center: center) == nil, "backpressure drops frame instead of allocating indefinitely")
        retained.removeAll()
        check(compositor.compose(main: red, inset: nil, center: center) != nil, "pool resumes after consumer releases buffers")

        let empty = try DualCameraMovieWriter()
        if case .failure = await finish(empty) { checks += 1 } else { preconditionFailure("empty recording accepted") }
        let silent = try DualCameraMovieWriter()
        silent.appendVideo(frame, pts: CMTime(seconds: 2, preferredTimescale: 600))
        if case .failure = await finish(silent) { checks += 1 } else { preconditionFailure("missing microphone accepted") }
        let writer = try DualCameraMovieWriter()
        for index in 0..<24 {
            let pts = CMTime(value: Int64(48 + index), timescale: 24)
            writer.appendVideo(portraitComposite, pts: pts)
            // A non-increasing video frame must be ignored; it must not invalidate the writer.
            writer.appendVideo(portraitComposite, pts: pts)
            writer.appendAudio(audio(at: pts))
            try await Task.sleep(for: .milliseconds(42))
        }
        let url = try await finish(writer).get()
        defer { try? FileManager.default.removeItem(at: url) }
        let asset = AVURLAsset(url: url)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        check(videoTracks.count == 1 && audioTracks.count == 1, "MP4 contains video and microphone tracks")
        let duration = try await asset.load(.duration)
        check(duration.seconds > 0.5 && duration.seconds < 2, "recording timeline rebased from capture PTS")
        let dimensions = try await videoTracks[0].load(.naturalSize)
        check(dimensions == CGSize(width: 720, height: 1280), "encoded composite dimensions")
        let movieFrame = try AVAssetImageGenerator(asset: asset).copyCGImage(at: CMTime(seconds: 0.3, preferredTimescale: 600), actualTime: nil)
        let movieCorner = rgba(CIImage(cgImage: movieFrame), at: upperLeft)
        check(movieCorner[0] > 210 && movieCorner[1] > 210 && movieCorner[2] < 45, "decoded MP4 retains upright circular inset pixels")
        print("PASS: \(checks) actual Core Image pixel, pool, JPEG and AVAssetWriter checks (no camera/TRTC hardware proof)")
    }
}
