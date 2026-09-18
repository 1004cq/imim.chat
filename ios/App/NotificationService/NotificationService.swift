import Intents
import UIKit
import UserNotifications

final class NotificationService: UNNotificationServiceExtension {
    private var contentHandler: ((UNNotificationContent) -> Void)?
    private var bestAttemptContent: UNMutableNotificationContent?
    private var hasCompleted = false

    override func didReceive(
        _ request: UNNotificationRequest,
        withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
    ) {
        self.contentHandler = contentHandler
        hasCompleted = false

        guard let content = request.content.mutableCopy() as? UNMutableNotificationContent else {
            finish(request.content)
            return
        }
        bestAttemptContent = content

        let userInfo = content.userInfo
        let pushType = userInfo["type"] as? String
        guard pushType != "call_invite" else {
            // Calls remain on their existing CallKit / VoIP path. Text messages
            // are the only payloads converted to communication notifications.
            finish(content)
            return
        }

        let chatId = stringValue(userInfo["chatId"]) ?? stringValue(userInfo["conversationId"]) ?? ""
        let senderId = stringValue(userInfo["senderId"]) ?? stringValue(userInfo["sender_id"]) ?? ""
        let senderName = stringValue(userInfo["sender_name"])
            ?? stringValue(userInfo["senderName"])
            ?? content.title.nilIfBlank
            ?? "新消息"

        // E2EE previews must never expose plaintext or ciphertext on the lock
        // screen. The server also sends this value, but enforce it here so a
        // malformed payload remains private.
        content.title = senderName
        content.body = "加密消息"
        content.categoryIdentifier = "MESSAGE"
        if !chatId.isEmpty {
            content.threadIdentifier = chatId
        }

        let avatarURL = validatedHTTPSURL(stringValue(userInfo["sender_avatar"]))
        if let avatarURL {
            downloadAvatar(from: avatarURL) { [weak self] avatar in
                self?.applyMessageIntent(
                    to: content,
                    senderId: senderId,
                    senderName: senderName,
                    chatId: chatId,
                    avatar: avatar
                )
            }
        } else {
            applyMessageIntent(
                to: content,
                senderId: senderId,
                senderName: senderName,
                chatId: chatId,
                avatar: nil
            )
        }
    }

    private func applyMessageIntent(
        to content: UNMutableNotificationContent,
        senderId: String,
        senderName: String,
        chatId: String,
        avatar: AvatarResource?
    ) {
        let handle = INPersonHandle(
            value: senderId.nilIfBlank ?? senderName,
            type: .unknown
        )
        let senderImage = avatar.flatMap { INImage(url: $0.fileURL) }
        let sender = INPerson(
            personHandle: handle,
            nameComponents: nil,
            displayName: senderName,
            image: senderImage,
            contactIdentifier: nil,
            customIdentifier: senderId.nilIfBlank
        )
        let recipient = INPerson(
            personHandle: INPersonHandle(value: "me", type: .unknown),
            nameComponents: nil,
            displayName: "我",
            image: nil,
            contactIdentifier: nil,
            customIdentifier: "me"
        )
        let intent = INSendMessageIntent(
            recipients: [recipient],
            outgoingMessageType: .outgoingMessageText,
            content: content.body,
            speakableGroupName: nil,
            conversationIdentifier: chatId.nilIfBlank,
            serviceName: "imimchat",
            sender: sender,
            attachments: nil
        )

        let interaction = INInteraction(intent: intent, response: nil)
        interaction.direction = INInteractionDirection.incoming
        interaction.donate(completion: { [weak self] (_: Error?) in
            guard let self else { return }
            do {
                // This gives the notification its system communication layout:
                // sender avatar plus the App icon badge.
                self.finish(try content.updating(from: intent))
            } catch {
                // Attachments are deliberately a fallback. They cannot replace
                // the communication layout, but still give a useful visual
                // notification when Intents is unavailable.
                if let attachment = avatar?.attachment {
                    content.attachments = [attachment]
                }
                self.finish(content)
            }
        })
    }

    private func downloadAvatar(from url: URL, completion: @escaping (AvatarResource?) -> Void) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 2
        configuration.timeoutIntervalForResource = 2
        configuration.waitsForConnectivity = false

        URLSession(configuration: configuration).dataTask(with: url) { data, response, error in
            guard error == nil,
                  let response = response as? HTTPURLResponse,
                  (200..<300).contains(response.statusCode),
                  let data,
                  !data.isEmpty,
                  data.count <= 64 * 1_024,
                  let image = UIImage(data: data),
                  let imageData = image.jpegData(compressionQuality: 0.82) else {
                completion(nil)
                return
            }

            let fileURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("notification-avatar-\(UUID().uuidString).jpg")
            do {
                try imageData.write(to: fileURL, options: .atomic)
                let attachment = try? UNNotificationAttachment(
                    identifier: "sender_avatar_fallback",
                    url: fileURL,
                    options: nil
                )
                completion(AvatarResource(fileURL: fileURL, attachment: attachment))
            } catch {
                completion(nil)
            }
        }.resume()
    }

    private func validatedHTTPSURL(_ value: String?) -> URL? {
        guard let value,
              let url = URL(string: value),
              url.scheme?.lowercased() == "https",
              url.host?.isEmpty == false else {
            return nil
        }
        return url
    }

    private func stringValue(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        return value.nilIfBlank
    }

    private func finish(_ content: UNNotificationContent) {
        guard !hasCompleted else { return }
        hasCompleted = true
        contentHandler?(content)
        contentHandler = nil
    }

    override func serviceExtensionTimeWillExpire() {
        if let bestAttemptContent {
            finish(bestAttemptContent)
        }
    }
}

private struct AvatarResource {
    let fileURL: URL
    let attachment: UNNotificationAttachment?
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
