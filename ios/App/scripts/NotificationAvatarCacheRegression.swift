import Kingfisher
import UIKit

// Standalone Catalyst regression linked against the existing Kingfisher build.
enum AppServer { static let origin = "https://app.imim.chat" }

@main
private enum NotificationAvatarCacheRegression {
    @MainActor static func main() async {
        let namespace = "notification-avatar-\(UUID().uuidString)"
        let cache = ImageCache(name: namespace)
        let defaults = UserDefaults(suiteName: namespace)!
        let loader = AvatarImageLoader(cache: cache, defaults: defaults)
        let image = UIGraphicsImageRenderer(size: CGSize(width: 32, height: 32)).image { context in
            UIColor.blue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            cache.store(image, forKey: "peer-a") { _ in continuation.resume() }
        }
        var checks = 0
        func check(_ passed: Bool, _ name: String) {
            precondition(passed, name)
            checks += 1
        }
        func isBlueFixture(_ value: UIImage?) -> Bool {
            guard let cgImage = value?.cgImage, cgImage.width == image.cgImage?.width,
                  cgImage.height == image.cgImage?.height else { return false }
            var bytes = [UInt8](repeating: 0, count: 4)
            bytes.withUnsafeMutableBytes {
                let context = CGContext(data: $0.baseAddress, width: 1, height: 1, bitsPerComponent: 8,
                    bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                context.draw(cgImage, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            }
            // Kingfisher may serialize an opaque image as JPEG. Compare the
            // decoded pixels, not encoded PNG bytes (which need not be equal).
            return bytes[0] < 15 && bytes[1] < 15 && bytes[2] > 240 && bytes[3] == 255
        }
        check(AvatarImageLoader.cacheKey(userId: "peer-a", urlString: "https://example.invalid/a.png?v=2") == "peer-a",
              "stable peer cache identity")
        let memory = await loader.cachedNotificationImage(userId: "peer-a", urlString: "https://example.invalid/a.png?v=2")
        check(memory === image, "memory avatar reused without download")
        let withoutURL = await loader.cachedNotificationImage(userId: "peer-a", urlString: nil)
        check(withoutURL === image, "known peer can use cache even when payload omits URL")
        let missing = await loader.cachedNotificationImage(userId: "peer-b", urlString: nil)
        check(missing == nil, "missing peer never borrows another user's avatar")
        cache.clearMemoryCache()
        check(cache.retrieveImageInMemoryCache(forKey: "peer-a") == nil, "disk-only fixture")
        let disk = await loader.cachedNotificationImage(userId: "peer-a", urlString: "https://example.invalid/a.png?v=999")
        check(isBlueFixture(disk), "disk cache survives query revision without download")
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            cache.store(image, forKey: "/a.png") { _ in continuation.resume() }
        }
        let path = await loader.cachedNotificationImage(userId: nil, urlString: "https://example.invalid/a.png?signature=new")
        check(isBlueFixture(path), "URL-path fallback ignores query")
        let empty = await loader.cachedNotificationImage(userId: nil, urlString: nil)
        check(empty == nil, "missing metadata returns ordinary fallback")
        print("Notification avatar memory/disk: \(checks) checks passed")
    }
}
