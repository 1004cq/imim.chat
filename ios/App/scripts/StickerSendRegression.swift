// Actual production send, ACK, mapping and render-source code is compiled above.
// In-memory SwiftData and synthetic transport only. No messages reach a server.
let fixtureDomain = "imim.sticker.fixture." + UUID().uuidString
let fixtureDefaults = UserDefaults(suiteName: fixtureDomain)!
enum AppServer { static let origin = "https://fixture.invalid" }
enum AIConversation { static func matches(_ id: String) -> Bool { id == "bot" } }
extension Date { init(milliseconds: Int64) { self.init(timeIntervalSince1970: Double(milliseconds)/1000) } }
enum MessageDeliveryState {
 static func merging(status: String, readAt: Date?, remoteStatus: String) -> String { status == "read" || readAt != nil ? "read" : remoteStatus }
}
@MainActor final class AuthTokenStore { static let shared = AuthTokenStore(); var token: String? = "fixture-token" }
@MainActor final class E2EEManager {
 static let shared = E2EEManager(); var hook: (() async -> Void)?
 func encryptText(_ text: String, peerId: String) async throws -> String { if let hook { await hook() }; return "synthetic-envelope" }
}
@MainActor final class APIClient {
 static let shared = APIClient(); var calls = 0; var lastExtra: [String: Any] = [:]
 var onReply: ((RemoteMessage) -> Void)?
 var fail = false
 func sendMessage(chatId: String, encryptedEnvelope: String, extra: [String: Any], notificationText: String?) async throws -> RemoteMessage {
  precondition(encryptedEnvelope == "synthetic-envelope"); calls += 1; lastExtra = extra
  if fail { throw URLError(.timedOut) }
  let result = try Self.remote(id: "remote-\(calls)", chatId: chatId, extra: extra)
  onReply?(result)
  return result
 }
 static func remote(id: String, chatId: String = "chat", extra: [String: Any] = [:]) throws -> RemoteMessage {
  let data = try JSONSerialization.data(withJSONObject: ["id":id,"chatId":chatId,"senderId":"owner","msgType":"encrypted","content":"synthetic-envelope","createdAt":Int64(1700000000000),"extra":extra])
  return try JSONDecoder().decode(RemoteMessage.self,from:data)
 }
}
@MainActor final class FixtureModel {
 var isSending = false; var isShowingAttachmentPanel = true; var errorMessage: String?
 var groupEncryptionUnavailableMessage = "group blocked"
 func sendMessage(_ text: String, in chat: Chat, modelContext: ModelContext) async {}
 func save(_ context: ModelContext) { try! context.save() }
 func previewText(for message: Message) -> String { message.type }
 func appendIncomingMessage(_ message: Message, to chat: Chat, modelContext: ModelContext) {}
// ACTUAL_METHODS
}
@main @MainActor struct Regression {
 static var count = 0
 static func check(_ value: Bool, _ label: String) { if !value { FileHandle.standardError.write(Data(("FAIL: " + label + "\n").utf8)) }; precondition(value,label); count += 1 }
 static func item(format: String = "tgs", url: String = "/api/media/sticker", mediaType: String = "sticker") throws -> StickerItem {
  try JSONDecoder().decode(StickerItem.self,from:JSONSerialization.data(withJSONObject:["id":"item","url":url,"format":format,"mediaType":mediaType,"emoji":"🙂","thumbUrl":"/api/media/thumb","packId":"pack"]))
 }
 static func main() async throws {
  defer { fixtureDefaults.removePersistentDomain(forName:fixtureDomain) }
  fixtureDefaults.set("owner",forKey:"current_user_id")
  let schema = Schema([Chat.self,Message.self,User.self])
  let container = try ModelContainer(for:schema,configurations:[ModelConfiguration(schema:schema,isStoredInMemoryOnly:true)])
  let context = ModelContext(container), model = FixtureModel(), api = APIClient.shared
  let chat = Chat(chatId:"chat",name:"fixture",memberIds:["owner","peer"]); context.insert(chat)
  let tgs = try item()
  if ProcessInfo.processInfo.environment["STICKER_ECHO_BASELINE"] == "1" {
   api.onReply = { remote in chat.messages.append(remote.toLocalMessage(currentUserId:"owner")) }
   await model.sendSticker(tgs,from:nil,in:chat,modelContext:context)
   check(chat.messages.count == 1, "self echo before HTTP response must not create two sticker rows")
   return
  }
  await model.sendSticker(tgs,from:nil,in:chat,modelContext:context)
  check(api.lastExtra["originalType"] as? String == "sticker", "wire metadata must retain sticker originalType")
  check(chat.messages.count == 1 && chat.messages[0].type == "sticker", "outgoing sticker stays sticker")
  let received = try APIClient.remote(id:"received",extra:api.lastExtra).toLocalMessage(currentUserId:"other")
  check(received.type == "sticker" && received.stickerRenderSource?.isLottie == true, "recipient/history classifies opaque TGS correctly")
  let outgoing = chat.messages[0]
  let oldAck = try APIClient.remote(id:outgoing.messageId).toLocalMessage(currentUserId:"owner")
  model.handleSocketMessage(oldAck,isAck:true,in:chat,modelContext:context)
  check(outgoing.type == "sticker", "legacy ACK cannot demote sticker to text")
  check(outgoing.stickerFormat == "tgs" && outgoing.stickerThumbURL == "/api/media/thumb", "legacy ACK preserves format and thumbnail")
  check(outgoing.stickerURL == tgs.url && outgoing.stickerPackID == "pack", "legacy ACK preserves source and pack")
  check(outgoing.stickerRenderSource?.isLottie == true, "sticker renderer survives sparse ACK")
  let emptyAck = try APIClient.remote(id:outgoing.messageId,extra:["stickerUrl":" ","stickerFormat":"","thumbUrl":" "]).toLocalMessage(currentUserId:"owner")
  model.handleSocketMessage(emptyAck,isAck:true,in:chat,modelContext:context)
  check(outgoing.stickerURL == tgs.url && outgoing.stickerFormat == "tgs", "blank ACK metadata cannot erase working source")
  let gif = try item(format:"gif",mediaType:"gif")
  await model.sendSticker(gif,from:nil,in:chat,modelContext:context)
  check(api.lastExtra["originalType"] as? String == "image", "GIF keeps deployed image wire type")
  check(chat.messages.last?.stickerRenderSource?.isAnimatedBitmap == true, "opaque GIF is still animated sticker content")
  let calls = api.calls; model.isSending = true
  await model.sendSticker(tgs,from:nil,in:chat,modelContext:context)
  check(api.calls == calls && chat.messages.count == 2, "concurrent send does not append duplicate sticker")
  model.isSending = false
  let photo = Message(messageId:"photo",chatId:"chat",senderId:"peer",content:"image",type:"image",mediaURL:"/image.webp",stickerURL:"/image.webp",isOutgoing:false)
  check(photo.stickerRenderSource == nil, "ordinary WebP photo is not promoted to sticker")
  photo.stickerFormat = "image/webp"; photo.stickerName = "photo.webp"
  check(photo.stickerRenderSource == nil, "generic format and filename do not change photo renderer")
  for (input,expected) in [(".TGS","tgs"),("IMAGE/WEBP","webp"),("image/gif; charset=binary","gif"),("application/json","json")] {
   check(try item(format:input).normalizedFormat == expected,"format normalization: \(input)")
  }
  check(try item(format:"image",url:"/library/example.gif").normalizedFormat == "gif", "generic media hint does not override concrete extension")
  let emptyURL = Message(messageId:"fallback",chatId:"chat",senderId:"peer",content:"sticker",type:"sticker",mediaURL:"/api/media/source",stickerURL:" ",stickerFormat:"tgs")
  check(emptyURL.stickerRenderSource?.url?.path == "/api/media/source", "blank sticker URL falls back to usable media URL")
  let legacy = try APIClient.remote(id:"legacy",extra:["stickerUrl":"/api/media/static","stickerFormat":"png"]).toLocalMessage(currentUserId:"other")
  check(legacy.type == "text" && legacy.stickerRenderSource?.format == "png", "legacy static sticker metadata renders despite old text type")
  legacy.content = "消息已撤回"
  check(legacy.stickerRenderSource == nil, "recalled sticker cannot reappear from retained metadata")
  let damaged = Message(messageId:"damaged",chatId:"chat",senderId:"owner",content:"[贴纸]",type:"text")
  let metadata = try APIClient.remote(id:"damaged",extra:["stickerUrl":"/api/media/old","stickerFormat":"tgs","thumbUrl":"/thumb","originalType":"sticker"]).extra
  damaged.restoreStickerMetadata(from:metadata)
  check(damaged.type == "sticker" && damaged.stickerRenderSource?.isLottie == true, "old persisted sticker can restore display metadata without decrypting")
  damaged.stickerURL = "/local/revision"
  damaged.restoreStickerMetadata(from:metadata)
  check(damaged.stickerURL == "/local/revision", "history restoration preserves usable local metadata")
  legacy.stickerURL = nil
  legacy.restoreStickerMetadata(from:metadata)
  check(legacy.stickerURL == nil && legacy.type == "text", "history restoration cannot revive recalled sticker")
  let beforeEcho = chat.messages.count
  api.onReply = { remote in
   let echo = remote.toLocalMessage(currentUserId:"owner")
   echo.status = "read"; echo.readAt = Date(timeIntervalSince1970:1700000001)
   chat.messages.append(echo)
  }
  await model.sendSticker(tgs,from:nil,in:chat,modelContext:context)
  check(chat.messages.count == beforeEcho + 1, "self echo before HTTP response leaves exactly one new sticker")
  let serverID = "remote-\(api.calls)"
  let sameMessage = chat.messages.filter { $0.messageId == serverID }
  check(sameMessage.count == 1 && sameMessage[0].stickerRenderSource?.isLottie == true, "one persistent row and render identity per server message")
  check(sameMessage[0].status == "read" && sameMessage[0].readAt != nil, "echo coalescing preserves earlier read receipt")
  check(chat.messages.filter { $0.stickerURL == tgs.url && $0.stickerFormat == "tgs" }.count == 2, "intentional repeated sticker sends with different IDs remain")
  for width in [CGFloat(160),240,320,393,600] {
   let side = StickerMessageLayout.stickerSide(viewportWidth:width,avatarSize:32,horizontalPadding:16)
   let content = StickerMessageLayout.contentWidth(viewportWidth:width,avatarSize:32,horizontalPadding:16)
   check(side <= 176 && side >= 0 && side <= content, "sticker fits actual viewport content width")
   check(content + 128 <= width, "avatar, spacing and sticker cannot overflow narrow viewport")
  }
  check(StickerMessageLayout.stickerSide(viewportWidth:.infinity,avatarSize:32,horizontalPadding:16) == 0,"invalid viewport produces no infinite frame")
  print("PASS: \(count) actual sticker send/ACK/history/render checks; memory-only fixtures, not device playback proof")
 }
}
