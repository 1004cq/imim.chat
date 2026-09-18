import SwiftUI

struct NotificationBannerView: View {
    let title: String
    let bodyText: String
    let avatarURL: String?
    var onTap: () -> Void
    
    @State private var isShowing = false
    
    var body: some View {
        VStack {
            if isShowing {
                bannerContent
                    .modifier(GlassNotificationSurface())
                    .padding(.horizontal, 12)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        onTap()
                        withAnimation { isShowing = false }
                    }
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            Spacer()
        }
        .onAppear {
            withAnimation(.spring()) {
                isShowing = true
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                withAnimation {
                    isShowing = false
                }
            }
        }
    }

    private var bannerContent: some View {
        HStack(spacing: 14) {
            NotificationAvatar(urlString: avatarURL, title: title)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(bodyText)
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }
}

private struct NotificationAvatar: View {
    let urlString: String?
    let title: String

    var body: some View {
        Group {
            if let url = urlString.flatMap(URL.init(string:)) {
                AsyncImage(url: url) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFill()
                    } else {
                        placeholder
                    }
                }
            } else {
                placeholder
            }
        }
        .frame(width: 54, height: 54)
        .clipShape(Circle())
        .overlay(Circle().stroke(.white.opacity(0.86), lineWidth: 1))
    }

    private var placeholder: some View {
        ZStack {
            Circle().fill(Color.green.opacity(0.20))
            Text(String(title.prefix(1)).uppercased())
                .font(.system(size: 21, weight: .bold))
                .foregroundStyle(DoveTheme.green)
        }
    }
}

private struct GlassNotificationSurface: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(.regular.interactive(), in: .rect(cornerRadius: 30))
        } else {
            content
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 30, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 30, style: .continuous)
                        .stroke(.white.opacity(0.65), lineWidth: 0.8)
                }
                .shadow(color: .black.opacity(0.14), radius: 18, y: 8)
        }
    }
}
