import Foundation
import UIKit

enum AvatarStore {
    static func saveAvatar(_ image: UIImage, userId: String, replacing oldPath: String?) throws -> String {
        let directory = try avatarDirectory()
        let processedImage = image.normalizedForAvatar()
        guard let data = processedImage.jpegData(compressionQuality: 0.82) else {
            throw AvatarStoreError.encodingFailed
        }

        let fileName = "avatar-\(userId)-\(Int(Date().timeIntervalSince1970)).jpg"
        let fileURL = directory.appendingPathComponent(fileName)
        try data.write(to: fileURL, options: [.atomic])

        removeLocalAvatar(at: oldPath, keeping: fileURL.path)
        return fileURL.path
    }

    static func image(from path: String?) -> UIImage? {
        guard let path, !path.isEmpty else { return nil }
        if path.hasPrefix("file://"), let url = URL(string: path) {
            return UIImage(contentsOfFile: url.path)
        }
        if path.hasPrefix("/") {
            return UIImage(contentsOfFile: path)
        }
        return nil
    }

    private static func avatarDirectory() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = base.appendingPathComponent("Avatars", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private static func removeLocalAvatar(at oldPath: String?, keeping newPath: String) {
        guard let oldPath, oldPath != newPath, oldPath.hasPrefix("/") else { return }
        try? FileManager.default.removeItem(atPath: oldPath)
    }
}

enum AvatarStoreError: LocalizedError {
    case encodingFailed

    var errorDescription: String? {
        switch self {
        case .encodingFailed:
            return "头像压缩失败，请重新选择图片"
        }
    }
}

private extension UIImage {
    func normalizedForAvatar(maxPixelSize: CGFloat = 640) -> UIImage {
        let normalized = normalizedOrientation()
        let side = min(normalized.size.width, normalized.size.height)
        let origin = CGPoint(
            x: (normalized.size.width - side) / 2,
            y: (normalized.size.height - side) / 2
        )
        let cropRect = CGRect(origin: origin, size: CGSize(width: side, height: side))

        guard let cgImage = normalized.cgImage?.cropping(to: cropRect.applying(.init(scaleX: normalized.scale, y: normalized.scale))) else {
            return normalized
        }

        let cropped = UIImage(cgImage: cgImage, scale: normalized.scale, orientation: .up)
        let targetSide = min(maxPixelSize, side)
        let targetSize = CGSize(width: targetSide, height: targetSide)
        let renderer = UIGraphicsImageRenderer(size: targetSize)
        return renderer.image { _ in
            cropped.draw(in: CGRect(origin: .zero, size: targetSize))
        }
    }

    func normalizedOrientation() -> UIImage {
        guard imageOrientation != .up else { return self }
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { _ in
            draw(in: CGRect(origin: .zero, size: size))
        }
    }
}
