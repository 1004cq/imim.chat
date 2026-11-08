import Intents
import UIKit
import UserNotifications

final class NotificationService: UNNotificationServiceExtension {
    // NSE entry points, URLSession and Intents callbacks may use different
    // threads. Confine all request state to one queue; never block a callback.
    private let deliveryQueue = DispatchQueue(label: "chat.imim.notification-delivery")
    private var requestID: UUID?
    private var contentHandler: ((UNNotificationContent) -> Void)?
    private var originalContent: UNNotificationContent?
    private var deadline: DispatchWorkItem?
    private var session: URLSession?

    override func didReceive(
        _ request: UNNotificationRequest,
        withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
    ) {
        deliveryQueue.async { [self] in
            finish(originalContent)
            let id = UUID()
            requestID = id
            self.contentHandler = contentHandler
            originalContent = request.content

            let fields = request.content.userInfo
            // Decrypt only the dedicated preview box, never a chat ratchet.
            if stringValue(fields["type"]) != "call_invite",
               let decrypted = request.content.mutableCopy() as? UNMutableNotificationContent {
                decrypted.body = NotificationPreview.notificationBody(fields: fields)
                originalContent = decrypted
            }
            guard stringValue(fields["type"]) != "call_invite",
                  let senderID = stringValue(fields["senderId"]),
                  let senderName = stringValue(fields["senderName"]),
                  let chatID = stringValue(fields["chatId"]),
                  let avatarURL = validatedHTTPSURL(stringValue(fields["avatarUrl"])) else {
                finish(originalContent)
                return
            }

            // Includes the Intents donation, not just the avatar download.
            let timeout = DispatchWorkItem { [weak self] in
                guard let self, self.requestID == id else { return }
                self.finish(self.originalContent)
            }
            deadline = timeout
            deliveryQueue.asyncAfter(deadline: .now() + 4, execute: timeout)
            downloadAvatar(from: avatarURL, requestID: id) { [weak self] imageData in
                guard let self, self.requestID == id else { return }
                guard let imageData else {
                    self.finish(self.originalContent)
                    return
                }
                self.applyMessageIntent(
                    to: self.originalContent ?? request.content, requestID: id,
                    senderID: senderID, senderName: senderName,
                    chatID: chatID, imageData: imageData
                )
            }
        }
    }

    private func applyMessageIntent(
        to content: UNNotificationContent, requestID id: UUID,
        senderID: String, senderName: String, chatID: String, imageData: Data
    ) {
        let intent = messageIntent(to: content, senderID: senderID, senderName: senderName,
                                   chatID: chatID, imageData: imageData)
        let interaction = INInteraction(intent: intent, response: nil)
        interaction.direction = .incoming
        interaction.donate { [weak self] error in
            guard let self else { return }
            self.deliveryQueue.async {
                guard self.requestID == id else { return }
                guard error == nil else {
                    self.finish(self.originalContent)
                    return
                }
                do {
                    // The system owns the avatar layout and App icon overlay.
                    self.finish(try content.updating(from: intent))
                } catch {
                    self.finish(self.originalContent)
                }
            }
        }
    }

    private func messageIntent(
        to content: UNNotificationContent,
        senderID: String, senderName: String, chatID: String, imageData: Data
    ) -> INSendMessageIntent {
        let senderImage = INImage(imageData: imageData)
        let sender = INPerson(
            personHandle: INPersonHandle(value: senderID, type: .unknown),
            nameComponents: nil,
            displayName: senderName,
            image: senderImage,
            contactIdentifier: nil,
            customIdentifier: senderID
        )
        let intent = INSendMessageIntent(
            // iOS implicitly adds the current user for an incoming donation.
            recipients: nil,
            outgoingMessageType: .outgoingMessageText,
            content: content.body,
            speakableGroupName: nil,
            conversationIdentifier: chatID,
            serviceName: "imim",
            sender: sender,
            attachments: nil
        )
        intent.setImage(senderImage, forParameterNamed: \.sender)
        return intent
    }

    private func downloadAvatar(
        from url: URL, requestID id: UUID, completion: @escaping (Data?) -> Void
    ) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 2
        configuration.timeoutIntervalForResource = 2
        configuration.waitsForConnectivity = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        let session = URLSession(configuration: configuration)
        self.session = session
        // Download to a temporary file so a large response cannot fill the
        // extension's memory before we get a chance to check its size.
        session.downloadTask(with: url) { [weak self] fileURL, response, error in
            guard let self else { return }
            let imageData: Data?
            if error == nil,
               let response = response as? HTTPURLResponse,
               (200..<300).contains(response.statusCode),
               response.url?.scheme?.lowercased() == "https",
               let fileURL,
               let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
               let size = attributes[.size] as? NSNumber,
               size.intValue > 0, size.intValue <= 1_024 * 1_024,
               let data = try? Data(contentsOf: fileURL),
               let image = UIImage(data: data),
               image.size.width <= 2_048, image.size.height <= 2_048 {
                imageData = data
            } else {
                imageData = nil
            }
            self.deliveryQueue.async {
                guard self.requestID == id else { return }
                completion(imageData)
            }
        }.resume()
    }

    private func validatedHTTPSURL(_ value: String?) -> URL? {
        guard let value, let url = URL(string: value),
              url.scheme?.lowercased() == "https", url.host?.isEmpty == false,
              url.user == nil, url.password == nil else { return nil }
        return url
    }

    private func stringValue(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    // Called only on deliveryQueue. Clearing the handler before invocation
    // prevents timeout / expiry / late download from delivering twice.
    private func finish(_ content: UNNotificationContent?) {
        guard let handler = contentHandler, let content else { return }
        contentHandler = nil
        requestID = nil
        deadline?.cancel()
        deadline = nil
        session?.invalidateAndCancel()
        session = nil
        originalContent = nil
        // Recheck privacy if it changed while downloading/donating.
        if stringValue(content.userInfo["type"]) != "call_invite",
           let final = content.mutableCopy() as? UNMutableNotificationContent {
            // Includes account logout/switch, missing key and privacy changes.
            final.body = NotificationPreview.notificationBody(fields: content.userInfo)
            handler(final)
        } else { handler(content) }
    }

    override func serviceExtensionTimeWillExpire() {
        deliveryQueue.async { [self] in
            finish(originalContent)
        }
    }
}
