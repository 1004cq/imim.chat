// Compiled together (via stdin) with the production PushPayload and the
// production markMessageDisplayed method. No UIKit stubs or server requests.
private final class NotificationRegressionHarness {
    private var recentlyDisplayedMessageIDs: [String: Date] = [:]
    // The runner inserts the production markMessageDisplayed method here.
    // INSERT_PRODUCTION_DEDUPE
}

@main
private enum MessageNotificationRegression {
    static func main() {
        var checks = 0
        func check(_ passed: Bool, _ name: String) {
            precondition(passed, name)
            checks += 1
        }
        let modern = PushPayload(userInfo: [
            "type": "private_message", "senderId": "peer-1", "senderName": " 李四 ",
            "avatarUrl": "https://example.invalid/avatar.jpg?v=2", "chatId": "chat-1", "messageId": "m1",
            "message": "DO NOT LEAK", "aps": ["alert": ["title": "新消息", "body": "DO NOT LEAK"]]
        ])
        check(modern.isMessage, "modern message type")
        check(modern.title == "李四", "sender nickname overrides generic alert title")
        check(modern.body == "新消息", "never copies plaintext preview")
        check(modern.senderId == "peer-1", "sender identity")
        check(modern.senderAvatarURL == "https://example.invalid/avatar.jpg?v=2", "full avatar URL")
        check(modern.chatId == "chat-1", "conversation identity")
        check(modern.messageId == "m1", "dedupe identity")

        let legacy = PushPayload(userInfo: [
            "message_type": "encrypted", "sender_id": "peer-2", "sender_name": "王五",
            "sender_avatar": "https://example.invalid/old.png", "conversation_id": "chat-2", "message_id": "m2"
        ])
        check(legacy.isMessage, "legacy encrypted type")
        check(legacy.title == "王五", "legacy nickname")
        check(legacy.body == "新消息", "legacy generic body")
        check(legacy.senderId == "peer-2", "legacy identity")
        check(legacy.senderAvatarURL?.hasSuffix("old.png") == true, "legacy avatar")
        check(legacy.chatId == "chat-2" && legacy.messageId == "m2", "legacy routing")

        let nested = PushPayload(userInfo: ["data": [
            "type": "group_message", "senderId": "peer-3", "senderName": "小明",
            "avatarUrl": "https://example.invalid/3.png", "chatId": "group-1", "messageId": "m3"
        ]])
        check(nested.isMessage && nested.body == "新消息", "nested message privacy")
        check(nested.title == "小明" && nested.senderId == "peer-3", "nested sender")
        check(nested.senderAvatarURL?.hasSuffix("3.png") == true, "nested avatar")
        check(nested.chatId == "group-1" && nested.messageId == "m3", "nested routing")

        let blank = PushPayload(userInfo: ["type": "message", "senderName": " ", "sender_name": "有效昵称",
                                          "avatarUrl": " ", "avatar_url": "https://example.invalid/fallback.png"])
        check(blank.title == "有效昵称", "blank names do not hide legacy nickname")
        check(blank.senderAvatarURL?.hasSuffix("fallback.png") == true, "blank avatar fallback")
        check(PushPayload(userInfo: ["type": "message"]).senderAvatarURL == nil, "missing avatar is ordinary notification")
        check(PushPayload(userInfo: [:]).title == "IMIM Chat", "missing title fallback")
        let call = PushPayload(userInfo: ["type": "call_invite", "senderId": "peer", "chatId": "chat",
                                         "caller_name": "来电人", "aps": ["alert": ["body": "语音通话"]]])
        check(!call.isMessage && call.title == "来电人" && call.body == "语音通话", "VoIP not rerouted")

        let gate = NotificationRegressionHarness()
        check(gate.markMessageDisplayed("same"), "first transport reserves message")
        check(!gate.markMessageDisplayed("same"), "second transport does not duplicate")
        check(gate.markMessageDisplayed("next"), "other message is independent")
        check(gate.markMessageDisplayed(nil), "legacy missing IDs remain deliverable")
        check(gate.markMessageDisplayed(""), "empty IDs remain deliverable")
        print("Notification metadata/privacy/dedupe: \(checks) checks passed")
    }
}
