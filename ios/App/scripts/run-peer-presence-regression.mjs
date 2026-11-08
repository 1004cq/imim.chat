// Production parser/store with synthetic HTTP and an isolated defaults suite.
// No real authentication, users, server writes, socket, database or Keychain.
import assert from 'node:assert/strict';
import {readFileSync,writeFileSync,mkdtempSync} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {spawnSync} from 'node:child_process';
const root=path.resolve(path.dirname(fileURLToPath(import.meta.url)),'..');
const source=readFileSync(path.join(root,'App/SocketManager.swift'),'utf8');
const api=readFileSync(path.join(root,'App/APIClient.swift'),'utf8');
const record=api.slice(api.indexOf('struct RemotePeerPresence:'),api.indexOf('\n}',api.indexOf('struct RemotePeerPresence:'))+2);
const production=source.slice(source.indexOf('enum PeerPresenceEvent:'),source.indexOf('\nclass SocketManager:')).replaceAll('UserDefaults.standard','fixtureDefaults');
const fixture=String.raw`
import Foundation
import Combine
let domain="imim.peer-presence-fixture."+UUID().uuidString
@MainActor let fixtureDefaults=UserDefaults(suiteName:domain)!
@MainActor final class AuthTokenStore {
 static let shared=AuthTokenStore(); var token:String?="synthetic-token"
}
struct RemoteFriend { let id:String; let online:Bool?; let lastSeen:Int64? }
@MainActor final class APIClient {
 static let shared=APIClient()
 var value=RemotePeerPresence(userId:"peer",online:true,lastSeen:nil)
 var friends:[RemoteFriend]=[]
 var fail=false
 var hook:(() -> Void)?
 func step() async throws {
  await Task.yield()
  let action=hook;hook=nil;action?()
  if fail {throw URLError(.notConnectedToInternet)}
 }
 func fetchPeerPresence(userId:String) async throws -> RemotePeerPresence {try await step();return value}
 func fetchFriends() async throws -> [RemoteFriend] {try await step();return friends}
}
`;
const checks=String.raw`
@main struct Regression {
 @MainActor static func main() async {
  defer {fixtureDefaults.removePersistentDomain(forName:domain)}
  fixtureDefaults.set("owner",forKey:"current_user_id")
  let store=FriendPresenceStore(),api=APIClient.shared
  precondition(store.snapshot(for:"peer")==nil)
  await store.refresh("peer")
  precondition(store.snapshot(for:"peer")?.online==true)
  store.apply(.user("peer",online:false))
  precondition(store.snapshot(for:"peer")?.online==false)
  precondition(store.snapshot(for:"peer")?.lastSeen != nil)
  store.apply(.onlineList(["other"]))
  precondition(store.snapshot(for:"peer")?.online==false)
  precondition(store.snapshot(for:"other")==nil) // do not retain unrelated global user IDs
  api.value=RemotePeerPresence(userId:"other",online:true,lastSeen:nil)
  await store.refresh("other")
  store.apply(.onlineList(["other"]))
  precondition(store.snapshot(for:"other")?.online==true)
  api.value=RemotePeerPresence(userId:"peer",online:true,lastSeen:nil)
  precondition(store.snapshot(for:"absent")==nil)
  store.apply(.user("owner",online:true))
  precondition(store.snapshot(for:"owner")==nil)
  api.hook={store.apply(.user("peer",online:false))}
  await store.refresh("peer")
  precondition(store.snapshot(for:"peer")?.online==false) // old HTTP cannot replace live event
  api.fail=true
  await store.refresh("peer")
  precondition(store.snapshot(for:"peer")==nil) // transport error is unknown, NOT offline
  api.fail=false;api.hook={store.invalidate()}
  await store.refresh("peer")
  precondition(store.snapshot(for:"peer")==nil)
  api.hook={fixtureDefaults.set("new-owner",forKey:"current_user_id")}
  await store.refresh("peer")
  precondition(store.snapshot(for:"peer")==nil)
  store.invalidate()
  api.hook={AuthTokenStore.shared.token="new-token"}
  await store.refresh("peer")
  precondition(store.snapshot(for:"peer")==nil)
  await store.refresh("peer")
  precondition(store.snapshot(for:"peer")?.online==true)
  AuthTokenStore.shared.token="rotated-token"
  precondition(store.snapshot(for:"peer")==nil) // Same account, new login cannot reuse old observations.
  await store.refresh("peer")
  precondition(store.snapshot(for:"peer")?.online==true)
  api.friends=[.init(id:"peer",online:true,lastSeen:nil),.init(id:"unknown",online:nil,lastSeen:nil)]
  await store.refreshFriends()
  precondition(store.snapshot(for:"peer")?.online==true && store.snapshot(for:"unknown")==nil)
  api.hook={store.apply(.user("peer",online:false))}
  await store.refreshFriends()
  precondition(store.snapshot(for:"peer")?.online==false)
  api.hook={AuthTokenStore.shared.token=nil}
  await store.refreshFriends()
  precondition(store.snapshot(for:"peer")==nil)
  for text in ["{}", "{\"type\":\"private_message\"}", "{\"type\":\"friend_online\",\"payload\":{\"userId\":\"\"}}"] {
   precondition(PeerPresenceEvent(data:Data(text.utf8))==nil)
  }
  let online=PeerPresenceEvent(data:Data("{\"type\":\"friend_online\",\"payload\":{\"userId\":\"peer\"}}".utf8))
  if case .user("peer",online:true)=online {} else {preconditionFailure()}
  let offline=PeerPresenceEvent(data:Data("{\"type\":\"friend_offline\",\"payload\":{\"userId\":\"peer\"}}".utf8))
  if case .user("peer",online:false)=offline {} else {preconditionFailure()}
  let decoded=try! JSONDecoder().decode(RemotePeerPresence.self,from:Data("{\"userId\":\"peer\",\"online\":false,\"lastSeen\":null,\"devices\":[]}".utf8))
  precondition(!decoded.online && decoded.lastSeen==nil)
  print("PASS: production peer presence parser/store; real-state separation, live-event ordering, node-local snapshot absence, failure/unknown, account/token switch and disconnect invalidation")
 }
}
`;
const dir=mkdtempSync(path.join(tmpdir(),'imim-peer-presence-')),swift=path.join(dir,'Regression.swift'),binary=path.join(dir,'Regression');
writeFileSync(swift,fixture+'\n'+record+'\n'+production+'\n'+checks);
const build=spawnSync('xcrun',['swiftc','-swift-version','6','-strict-concurrency=complete','-parse-as-library',swift,'-o',binary],{stdio:'inherit'});
if(build.status!==0)process.exit(build.status??1);
const run=spawnSync(binary,[],{stdio:'inherit'});if(run.status!==0)process.exit(run.status??1);
const chat=readFileSync(path.join(root,'App/ChatDetailView.swift'),'utf8');
assert.ok(!chat.includes('PresenceDot(isOnline: socket.isConnected)'));
assert.ok(chat.includes('.task(id: presenceRefreshIdentity)'));
assert.ok(chat.includes('.ignoresSafeArea(.container, edges: .bottom)'));
assert.ok(!chat.includes('.ignoresSafeArea(.keyboard'));
const rows=readFileSync(path.join(root,'App/ChatsViewModel.swift'),'utf8');
assert.ok(!rows.includes('isOnline = chat.type == "private"'));
assert.ok(source.includes('FriendPresenceStore.shared.apply(event)'));
assert.ok(api.includes('"/users/\\(escaped)/presence"'));
console.log('PASS: native header/list use peer observations; no local-socket-as-friend flag, no forced keyboard safe-area bypass');
