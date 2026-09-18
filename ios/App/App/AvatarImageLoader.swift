import Kingfisher
import UIKit

enum AvatarImageLoader {
    static func loadAvatar(urlString: String?, into imageView: UIImageView) {
        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true

        let placeholder = placeholderImage(size: imageView.bounds.size)

        if let localImage = AvatarStore.image(from: urlString) {
            imageView.image = localImage
            return
        }

        guard let urlString,
              let url = URL(string: urlString),
              ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
            imageView.image = placeholder
            return
        }

        let radius = max(imageView.bounds.width, imageView.bounds.height) / 2
        imageView.kf.indicatorType = .activity
        imageView.kf.setImage(
            with: url,
            placeholder: placeholder,
            options: [
                .processor(RoundCornerImageProcessor(cornerRadius: radius)),
                .cacheOriginalImage,
                .transition(.fade(0.18)),
                .retryStrategy(DelayRetryStrategy(maxRetryCount: 2, retryInterval: .seconds(1)))
            ]
        )
    }

    private static func placeholderImage(size: CGSize) -> UIImage? {
        let side = max(size.width, size.height, 48)
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: side, height: side))
        return renderer.image { context in
            UIColor(red: 0.91, green: 0.98, blue: 0.94, alpha: 1).setFill()
            context.fill(CGRect(x: 0, y: 0, width: side, height: side))

            let symbolConfig = UIImage.SymbolConfiguration(pointSize: side * 0.44, weight: .semibold)
            let symbol = UIImage(systemName: "person.fill", withConfiguration: symbolConfig)
            UIColor(red: 0.20, green: 0.58, blue: 0.36, alpha: 1).setFill()
            symbol?.draw(
                in: CGRect(
                    x: side * 0.28,
                    y: side * 0.25,
                    width: side * 0.44,
                    height: side * 0.44
                )
            )
        }
    }
}

func loadAvatar(urlString: String?, into imageView: UIImageView) {
    AvatarImageLoader.loadAvatar(urlString: urlString, into: imageView)
}
