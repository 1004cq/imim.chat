
actor CancellationProbe { var cancelled=false; func mark() { cancelled=true } }
@main struct ReleaseChatRegression {
 @MainActor static func main() async throws {
  var checks=0
  func check(_ c:Bool,_ label:String) { precondition(c,label);checks += 1 }
  let defaults=UserDefaults.standard
  let ownerBefore=defaults.object(forKey:"current_user_id"), languageBefore=defaults.object(forKey:AppLanguage.preferenceKey)
  defer { defaults.set(ownerBefore,forKey:"current_user_id");defaults.set(languageBefore,forKey:AppLanguage.preferenceKey) }
  defaults.set("fixture-A",forKey:"current_user_id")
  let h=SortHarness(), t=Date(timeIntervalSince1970:1700000000)
  let a=Message(messageId:"a",chatId:"chat",senderId:"peer",content:"one",type:"text",status:"sent",createdAt:t,isOutgoing:false,chat:nil)
  let b=Message(messageId:"b",chatId:"chat",senderId:"peer",content:"two",type:"text",status:"sent",createdAt:t.addingTimeInterval(1),isOutgoing:false,chat:nil)
  let c=Chat(chatId:"chat",name:"Fixture",messages:[b,a])
  check(h.sortedMessages(for:c).map(\.messageId)==["a","b"],"initial sort")
  let replacement=Message(messageId:"a",chatId:"chat",senderId:"peer",content:"replacement",type:"text",status:"sent",createdAt:t,isOutgoing:false,chat:nil)
  c.messages=[b,replacement]
  check(h.sortedMessages(for:c).first === replacement,"same count same ID object replacement invalidates")
  b.createdAt=t.addingTimeInterval(-1)
  check(h.sortedMessages(for:c).first === b,"timestamp mutation reorders without count change")
  replacement.content="edited"
  check(h.sortedMessages(for:c).last?.content=="edited","content edits use live model references")
  let ai=Chat(chatId:"bot",name:"AI")
  let aa=Message(messageId:AIConversation.messagePrefix(owner:"fixture-A")+"a",chatId:ai.chatId,senderId:"fixture-A",content:"A",type:"text",status:"sent",createdAt:t,isOutgoing:true,chat:nil)
  let bb=Message(messageId:AIConversation.messagePrefix(owner:"fixture-B")+"b",chatId:ai.chatId,senderId:"fixture-B",content:"B",type:"text",status:"sent",createdAt:t,isOutgoing:true,chat:nil)
  ai.messages=[aa,bb]
  check(h.sortedMessages(for:ai).map(\.content)==["A"],"AI account A")
  defaults.set("fixture-B",forKey:"current_user_id")
  check(h.sortedMessages(for:ai).map(\.content)==["B"],"AI owner change invalidates")
  defaults.removeObject(forKey:"current_user_id")
  check(h.sortedMessages(for:ai).isEmpty,"logged-out AI projection empty")
  defaults.set("fixture-A",forKey:"current_user_id")
  let rows=IMConversationViewModel()
  c.lastMessage="[加密消息]";defaults.set("zh-Hans",forKey:AppLanguage.preferenceKey)
  _=rows.conversationRows(from:[c]);c.avatar="https://fixture.invalid/new.png"
  check(rows.conversationRows(from:[c])[0].conversation.avatarURL==c.avatar,"avatar cache invalidates")
  c.isMuted=true;c.unreadCount=7
  check(rows.conversationRows(from:[c])[0].conversation.unreadCount==0,"mute cache invalidates")
  c.isEncrypted=false
  check(!rows.conversationRows(from:[c])[0].conversation.isEncrypted,"encryption cache invalidates")
  c.type="group"
  check(rows.conversationRows(from:[c])[0].conversation.isGroup,"type cache invalidates")
  defaults.set("en",forKey:AppLanguage.preferenceKey)
  check(rows.conversationRows(from:[c])[0].conversation.subtitle==AppLocalization.string("加密消息"),"language cache invalidates")
  let sync=SortHarness()
  try await sync.sync();try await sync.sync()
  check(E2EEManager.shared.calls==1,"ordinary sync throttled")
  defaults.set("fixture-B",forKey:"current_user_id");try await sync.sync()
  check(E2EEManager.shared.calls==2,"new account not throttled")
  AuthTokenStore.shared.token="fixture-new-token";try await sync.sync()
  check(E2EEManager.shared.calls==3,"new authentication epoch not throttled")
  let failed=SortHarness();E2EEManager.shared.fail=true
  do {try await failed.sync();preconditionFailure("expected sync failure")} catch FixtureError.failed {checks += 1}
  E2EEManager.shared.fail=false;try await failed.sync()
  check(E2EEManager.shared.calls==5,"failed sync does not consume cooldown")
  check(try await ChatAsyncDeadline.run(timeout:.seconds(1)){true},"MLS preparation wins")
  check(!(try await ChatAsyncDeadline.run(timeout:.seconds(1)){false}),"MLS missing-state false preserved")
  do {_ = try await ChatAsyncDeadline.run(timeout:.seconds(1)){throw FixtureError.failed};preconditionFailure("expected actual error")} catch FixtureError.failed {checks += 1}
  let probe=CancellationProbe()
  let timed=try await ChatAsyncDeadline.run(timeout:.milliseconds(10)) {
   do {try await Task.sleep(for:.seconds(20));return true} catch {await probe.mark();throw error}
  }
  check(!timed,"deadline reports waiting")
  let cancelled=await probe.cancelled;check(cancelled,"losing MLS child cancelled and joined")
  let parent=Task {try await ChatAsyncDeadline.run(timeout:.seconds(20)) {try await Task.sleep(for:.seconds(20));return true}}
  parent.cancel()
  do {_=try await parent.value;preconditionFailure("expected cancellation")} catch is CancellationError {checks += 1}
  print("PASS: \(checks) actual-source message/row cache, account throttle and structured MLS deadline checks")
 }
}
