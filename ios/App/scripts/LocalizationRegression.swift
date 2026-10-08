import Foundation

@main
struct LocalizationRegression {
    static func main() throws {
        precondition(AppLanguage.resolve(preferredLanguages: ["en-US", "zh-Hans"]) == "en")
        precondition(AppLanguage.resolve(preferredLanguages: ["zh-Hans-CN", "en"]) == "zh-Hans")
        precondition(AppLanguage.resolve(preferredLanguages: ["fr-FR", "en"]) == "en")
        precondition(AppLanguage.resolve(preferredLanguages: []) == "en")

        let appPath = CommandLine.arguments[1]
        guard let app = Bundle(path: appPath) else { fatalError("Missing compiled app bundle") }
        let english = AppLocalization.bundle(for: .english, in: app)
        let chinese = AppLocalization.bundle(for: .simplifiedChinese, in: app)
        precondition(english.bundlePath != app.bundlePath)
        precondition(chinese.bundlePath != app.bundlePath)

        for (key, expected) in [
            ("语言", "Language"), ("消息", "Chats"), ("通讯录", "Contacts"),
            ("朋友圈", "Moments"), ("同意", "Accept"), ("拒绝", "Decline"),
            ("注销账号", "Delete Account"), ("输入加密消息...", "Message…")
        ] {
            precondition(english.localizedString(forKey: key, value: key, table: "Localizable") == expected, key)
            precondition(chinese.localizedString(forKey: key, value: key, table: "Localizable") == key, key)
        }

        let count = 4
        precondition(String(localized: "\(count) 位成员", bundle: english, locale: Locale(identifier: "en")) == "4 members")
        precondition(String(localized: "已选 \(count) 人", bundle: english, locale: Locale(identifier: "en")) == "4 selected")
        let name = "用户原文"
        precondition(String(localized: "回复 \(name)", bundle: english, locale: Locale(identifier: "en")) == "Reply to 用户原文")
        precondition(String(localized: "账号：\(name)", bundle: english, locale: Locale(identifier: "en")) == "Account: 用户原文")
        precondition(String(localized: "上传头像 \(count)%", bundle: english, locale: Locale(identifier: "en")) == "Uploading avatar 4%")

        let camera = english.localizedString(forKey: "NSCameraUsageDescription", value: nil, table: "InfoPlist")
        precondition(camera.contains("camera") && !camera.contains("摄像头"))
        print("PASS: language resolution, compiled resources, interpolation, unchanged user text, permission prompts")
    }
}
