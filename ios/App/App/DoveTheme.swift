import Kingfisher
import SwiftUI
import UIKit

enum DoveTheme {
    private static let lightAccent = UIColor(red: 43.0 / 255.0, green: 162.0 / 255.0, blue: 69.0 / 255.0, alpha: 1)
    // Keep the product green in both appearances. Dark mode only raises luminance.
    private static let darkAccent = UIColor(red: 0.23, green: 0.78, blue: 0.38, alpha: 1)

    private static func adaptive(light: UIColor, dark: UIColor) -> Color {
        Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark ? dark : light
        })
    }

    /// The app has one semantic palette. Individual screens never choose a fixed canvas color.
    static let green = adaptive(light: lightAccent, dark: darkAccent)
    static let accent = adaptive(light: lightAccent, dark: darkAccent)
    // Compatibility alias while existing screens migrate to the semantic color.
    static let telegramBlue = accent
    static let telegramBlueBubble = adaptive(
        light: UIColor(red: 0.84, green: 0.95, blue: 0.87, alpha: 1),
        dark: UIColor(red: 0.10, green: 0.20, blue: 0.12, alpha: 1)
    )
    static let greenSoft = adaptive(
        light: UIColor(red: 0.91, green: 0.98, blue: 0.94, alpha: 1),
        dark: UIColor(white: 0.14, alpha: 1)
    )
    static let ink = adaptive(light: .black, dark: .white)
    static let paper = adaptive(light: .white, dark: .black)
    static let cardSurface = adaptive(light: .white, dark: UIColor(white: 0.12, alpha: 1))
    static let mist = paper
    static let warmGray = adaptive(light: UIColor(white: 0.93, alpha: 1), dark: UIColor(white: 0.14, alpha: 1))
    static let secondaryText = adaptive(light: UIColor(white: 0.45, alpha: 1), dark: UIColor(white: 0.60, alpha: 1))
    static let separator = adaptive(light: UIColor.separator, dark: UIColor(white: 0.23, alpha: 1))
    static let seal = Color(uiColor: UIColor.systemRed)
    static let sentBubble = adaptive(light: UIColor(red: 0.84, green: 0.95, blue: 0.87, alpha: 1), dark: UIColor(red: 0.10, green: 0.20, blue: 0.12, alpha: 1))
    static let sentBubbleEdge = adaptive(light: UIColor(red: 0.49, green: 0.78, blue: 0.56, alpha: 1), dark: UIColor(red: 0.25, green: 0.48, blue: 0.29, alpha: 1))
    static let receivedBubble = adaptive(light: .white, dark: UIColor(white: 0.14, alpha: 1))

    static let listRowRadius: CGFloat = 24
    static let cardRadius: CGFloat = 22
    static let controlRadius: CGFloat = 16

    enum Chat {
        static let horizontalPadding: CGFloat = 16
        static let avatarSize: CGFloat = 32
        static let maxBubbleWidthRatio: CGFloat = 0.70
        static let bubbleHPadding: CGFloat = 12
        static let bubbleVPadding: CGFloat = 9
        static let messageRowSpacing: CGFloat = 8
        static let inputHeight: CGFloat = 40
    }
}

struct DoveAvatar: View {
    let name: String
    var url: String?
    var size: CGFloat = 48
    var isGroup = false
    var isOnline = false

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            avatarContent
                .frame(width: size, height: size)
                .clipShape(Circle())
                .overlay(Circle().stroke(DoveTheme.paper.opacity(0.9), lineWidth: 2))
                .shadow(color: .black.opacity(0.08), radius: 8, y: 3)

            if isOnline {
                Circle()
                    .fill(DoveTheme.green)
                    .frame(width: 11, height: 11)
                    .overlay(Circle().stroke(DoveTheme.paper, lineWidth: 2))
            }
        }
        .accessibilityLabel(name)
    }

    @ViewBuilder
    private var avatarContent: some View {
        if let image = AvatarStore.image(from: url) {
            Image(uiImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else if let url, let imageURL = remoteImageURL(from: url) {
            KFImage(imageURL)
                .placeholder {
                    placeholder
                }
                .retry(maxCount: 2, interval: .seconds(1))
                .cacheOriginalImage()
                .fade(duration: 0.18)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else {
            placeholder
        }
    }

    private func remoteImageURL(from value: String) -> URL? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.lowercased() != "null" else { return nil }
        if trimmed.hasPrefix("/") {
            return URL(string: "https://wed.imim.chat\(trimmed)")
        }
        guard let url = URL(string: trimmed),
              ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
            return nil
        }
        return url
    }

    private var placeholder: some View {
        ZStack {
            LinearGradient(
                colors: isGroup ? [DoveTheme.green, Color.teal] : [DoveTheme.greenSoft, DoveTheme.warmGray],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            if isGroup {
                Image(systemName: "person.2.fill")
                    .font(.system(size: size * 0.38, weight: .semibold))
                    .foregroundStyle(.white)
            } else {
                Text(String(name.prefix(1)))
                    .font(.system(size: size * 0.38, weight: .semibold, design: .rounded))
                    .foregroundStyle(DoveTheme.green)
            }
        }
    }
}

struct DoveUnreadBadge: View {
    let count: Int

    var body: some View {
        if count > 0 {
            Text(count > 99 ? "99+" : "\(count)")
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .frame(minWidth: 18, minHeight: 18)
                .padding(.horizontal, count > 9 ? 4 : 0)
                .background(DoveTheme.seal, in: Capsule())
        }
    }
}

struct DoveIconButton: View {
    let systemName: String
    var foreground: Color = DoveTheme.ink
    var background: Color = DoveTheme.warmGray.opacity(0.7)
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(foreground)
                .frame(width: 36, height: 36)
                .background(background, in: Circle())
        }
        .buttonStyle(.plain)
    }
}

struct DoveSearchBar: View {
    @Binding var text: String
    var placeholder = "搜索"

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary)

            TextField(placeholder, text: $text)
                .font(.system(size: 14))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()

            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary.opacity(0.7))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(DoveTheme.warmGray.opacity(0.72), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
    }
}

struct DoveSegmentedControl<Selection: Hashable>: View {
    let items: [(Selection, String, Int)]
    @Binding var selection: Selection

    var body: some View {
        HStack(spacing: 6) {
            ForEach(items, id: \.0) { item in
                Button {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                        selection = item.0
                    }
                } label: {
                    HStack(spacing: 5) {
                        Text(item.1)
                        if item.2 > 0 {
                            DoveUnreadBadge(count: item.2)
                        }
                    }
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(selection == item.0 ? .white : DoveTheme.ink.opacity(0.65))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 9)
                    .background(selection == item.0 ? DoveTheme.green : .clear, in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(DoveTheme.warmGray.opacity(0.65), in: Capsule())
    }
}
