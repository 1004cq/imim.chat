import CryptoKit
import Foundation

@main
struct PreviewRegression {
    static func main() throws {
        let privateKey = P256.KeyAgreement.PrivateKey()
        let publicData = privateKey.publicKey.x963Representation
        let recipient = NotificationPreviewKey(keyId: NotificationPreview.keyID(publicData), publicKey: publicData.base64EncodedString(), userId: "recipient")
        let fixture = "加密预览测试 😀 café"
        let local = try NotificationPreview.seal(fixture, to: recipient, senderId: "sender", chatId: "chat")
        let localText = try NotificationPreview.open(local, with: privateKey, userId: "recipient", senderId: "sender", chatId: "chat")
        precondition(localText == fixture)

        let child = Process()
        child.executableURL = URL(fileURLWithPath: CommandLine.arguments[1])
        child.arguments = [CommandLine.arguments[2], recipient.publicKey]
        let output = Pipe()
        child.standardOutput = output
        try child.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        child.waitUntilExit()
        precondition(child.terminationStatus == 0)
        let webBox = try JSONDecoder().decode(NotificationPreviewBox.self, from: data)
        let webText = try NotificationPreview.open(webBox, with: privateKey, userId: "recipient", senderId: "sender", chatId: "chat")
        precondition(webText == fixture)

        for (user, sender, chat) in [("other", "sender", "chat"), ("recipient", "other", "chat"), ("recipient", "sender", "other")] {
            precondition((try? NotificationPreview.open(webBox, with: privateKey, userId: user, senderId: sender, chatId: chat)) == nil)
        }
        var dictionary = try JSONSerialization.jsonObject(with: JSONEncoder().encode(webBox)) as! [String: Any]
        dictionary["tag"] = Data(repeating: 0, count: 16).base64EncodedString()
        let changed = try JSONDecoder().decode(NotificationPreviewBox.self, from: JSONSerialization.data(withJSONObject: dictionary))
        precondition((try? NotificationPreview.open(changed, with: privateKey, userId: "recipient", senderId: "sender", chatId: "chat")) == nil)
        precondition((try? NotificationPreview.open(webBox, with: P256.KeyAgreement.PrivateKey(), userId: "recipient", senderId: "sender", chatId: "chat")) == nil)
        precondition(NotificationPreview.shortText(String(repeating: "😀", count: 200)).utf8.count <= 480)
        precondition(NotificationPreview.notificationBody(fields: [:]) == "新消息")
        print("Preview regression: Swift roundtrip, WebCrypto interoperability, tamper/context/wrong-key/fallback/limits passed")
    }
}
