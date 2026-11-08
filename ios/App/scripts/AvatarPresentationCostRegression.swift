import CryptoKit
import Kingfisher
import UIKit

// These extensions compile beside the actual loader in one standalone source.
// No test hook or benchmark entry point is added to the shipping App target.
private extension AvatarImageLoader {
    func presentationTestDigest(_ value: String) -> String { digest(value) }
}

@main
private struct AvatarPresentationCostRegression {
    @MainActor
    static func legacyPlaceholder(size: CGSize, name: String?, isGroup: Bool) -> UIImage {
        let side = max(size.width, size.height, 48)
        return UIGraphicsImageRenderer(size: CGSize(width: side, height: side)).image { context in
            let colors = isGroup
                ? [UIColor(DoveTheme.green).cgColor, UIColor.systemTeal.cgColor]
                : [UIColor(DoveTheme.greenSoft).cgColor, UIColor(DoveTheme.warmGray).cgColor]
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: [0, 1]) {
                context.cgContext.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: side, y: side), options: [])
            }
            if !isGroup, let first = name?.trimmingCharacters(in: .whitespacesAndNewlines).first {
                let text = String(first) as NSString
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: UIFont.systemFont(ofSize: side * 0.38, weight: .semibold),
                    .foregroundColor: UIColor(DoveTheme.green)
                ]
                let textSize = text.size(withAttributes: attributes)
                text.draw(at: CGPoint(x: (side - textSize.width) / 2, y: (side - textSize.height) / 2), withAttributes: attributes)
            } else {
                let config = UIImage.SymbolConfiguration(pointSize: side * 0.38, weight: .semibold)
                let symbol = UIImage(systemName: isGroup ? "person.2.fill" : "person.fill", withConfiguration: config)?
                    .withTintColor(isGroup ? .white : UIColor(DoveTheme.green), renderingMode: .alwaysOriginal)
                symbol?.draw(in: CGRect(x: side * 0.25, y: side * 0.25, width: side * 0.5, height: side * 0.5))
            }
        }
    }

    @MainActor static func rgba(_ image: UIImage) -> [UInt8] {
        let cgImage = image.cgImage!
        var bytes = [UInt8](repeating: 0, count: cgImage.width * cgImage.height * 4)
        bytes.withUnsafeMutableBytes {
            let context = CGContext(data: $0.baseAddress, width: cgImage.width, height: cgImage.height,
                                    bitsPerComponent: 8, bytesPerRow: cgImage.width * 4,
                                    space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height))
        }
        return bytes
    }

    @MainActor static func median(_ operation: () -> Int) -> Double {
        let expected = operation()
        return (0..<7).map { _ in
            let start = DispatchTime.now().uptimeNanoseconds
            precondition(operation() == expected)
            return Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
        }.sorted()[3]
    }

    @MainActor static func main() throws {
        let namespace = UUID().uuidString
        let cache = ImageCache(name: "imim-avatar-cost-\(namespace)")
        let defaults = UserDefaults(suiteName: "imim-avatar-cost-\(namespace)")!
        let loader = AvatarImageLoader(cache: cache, defaults: defaults)
        var checks = 0
        for value in ["", "a", "peer-123", "中文", "👩‍💻", " a/b?x=1 ", "https://avatars.example.invalid/a.png?v=2"] {
            let legacy = SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
            precondition(loader.presentationTestDigest(value) == legacy)
            checks += 1
        }
        let expectReuse = ProcessInfo.processInfo.arguments.contains("--expect-reuse")
        for style in [UIUserInterfaceStyle.light, .dark] {
            for contrast in [UIAccessibilityContrast.normal, .high] {
                let traits = UITraitCollection { traits in
                    traits.userInterfaceStyle = style
                    traits.accessibilityContrast = contrast
                }
                traits.performAsCurrent {
                    for side in [32.0, 56, 96] {
                        for name in [nil, "", "   ", " Alice ", "Bob", "张三", "👩‍💻 Developer"] as [String?] {
                            for group in [false, true] {
                                let size = CGSize(width: side, height: side)
                                let view = UIImageView(frame: CGRect(origin: .zero, size: size))
                                loader.load(urlString: nil, name: name, isGroup: group, into: view)
                                let first = view.image!
                                let expected = legacyPlaceholder(size: size, name: name, isGroup: group)
                                precondition(first.size == expected.size && first.scale == expected.scale)
                                precondition(rgba(first) == rgba(expected), "placeholder pixels changed")
                                checks += 2
                                loader.load(urlString: nil, name: name, isGroup: group, into: view)
                                if expectReuse { precondition(view.image === first); checks += 1 }
                            }
                        }
                    }
                }
            }
        }
        let letters = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ")
        let views = (0..<500).map { _ in UIImageView(frame: CGRect(x: 0, y: 0, width: 56, height: 56)) }
        let placeholderMS = median {
            var checksum = 0
            for (index, view) in views.enumerated() {
                loader.load(urlString: nil, name: "\(letters[index % letters.count]) fixture", into: view)
                checksum += Int(view.image!.size.width)
            }
            return checksum
        }
        let digestMS = median {
            (0..<500).reduce(0) { $0 + loader.presentationTestDigest("https://avatars.example.invalid/peer-\($1).png?v=2").utf8.count }
        }
        let output: [String: Any] = [
            "kind": "synthetic_mac_catalyst_avatar_presentation_not_device_ui",
            "checks": checks,
            "expects_placeholder_reuse": expectReuse,
            "placeholder_500_loads_median_ms": placeholderMS,
            "digest_500_revisions_median_ms": digestMS,
            "timestamp": ISO8601DateFormatter().string(from: Date())
        ]
        print(String(decoding: try JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self))
    }
}
