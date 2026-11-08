// Runs extracted production CallKit audio-state methods with silent fixtures.
// Does not emulate CallKit, AVAudioSession hardware or the TRTC engine.
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import assert from 'node:assert/strict';
import {spawnSync} from 'node:child_process';
import {fileURLToPath} from 'node:url';
const app = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../App');
const trtc = fs.readFileSync(path.join(app, 'TRTCManager.swift'), 'utf8');
const call = fs.readFileSync(path.join(app, 'CallManager.swift'), 'utf8');
function method(source, signature) {
  const start = source.indexOf(signature);
  assert.ok(start >= 0, signature);
  const brace = source.indexOf('{', start);
  let depth = 1, end = brace + 1;
  while (depth && end < source.length) {
    if (source[end] === '{') depth++;
    if (source[end] === '}') depth--;
    end++;
  }
  assert.equal(depth, 0);
  return source.slice(start, end);
}
for (const action of ['CXAnswerCallAction', 'CXStartCallAction']) {
  const body = method(call, `func provider(_ provider: CXProvider, perform action: ${action})`);
  assert.ok(body.includes('prepareForCallKitAudioActivation'));
  assert.ok(body.indexOf('prepareForCallKitAudioActivation') < body.indexOf('action.fulfill()'));
  assert.ok(!body.includes('Task {'), `${action} must prepare synchronously`);
  assert.ok(body.includes('action.fail()'));
}
for (const callback of ['didActivate', 'didDeactivate']) {
  const body = method(call, `func provider(_ provider: CXProvider, ${callback} audioSession:`);
  assert.ok(!body.includes('Task {'), `${callback} must not reorder delegate delivery`);
}
assert.ok(call.includes('provider.setDelegate(self, queue: .main)'));
const activation = method(trtc, 'func handleCallKitAudioSessionActivated(');
assert.ok(!activation.includes('configureAudioSession') && !activation.includes('setActive'));
const start = method(trtc, 'private func startLocalMediaAfterRoomEntered()');
assert.ok(start.indexOf('callKitAudioSessionActive') < start.indexOf('cloud.startLocalAudio'));
assert.ok(start.includes('guard !localMediaStarted'));
const methods = [method(trtc, 'func prepareForCallKitAudioActivation('), activation,
  method(trtc, 'func handleCallKitAudioSessionDeactivated()')].join('\n');
const source = `
import Foundation
enum VideoCallType { case audio, video }
enum ConnectionState { case idle, connected }
final class AVAudioSession { static func sharedInstance() -> AVAudioSession { .init() } }
@MainActor final class Probe {
  var activeCallType: VideoCallType = .audio
  var callKitAudioActivationRequired = false, callKitAudioSessionActive = false
  var localMediaStarted = false, connectionState = ConnectionState.idle
  var audioStartRetryTask: Task<Void, Never>?
  var configurationSucceeds = true, configurationCount = 0, starts = 0
  var events: [String] = []
  func configureAudioSession(_ session: AVAudioSession, activate: Bool) -> Bool {
    precondition(!activate, "CallKit owns activation")
    configurationCount += 1; return configurationSucceeds
  }
  func logAudioState(_ event: String, session: AVAudioSession = .sharedInstance()) { events.append(event) }
  func startLocalMediaAfterRoomEntered() {
    guard !localMediaStarted else { return }; localMediaStarted = true; starts += 1
  }
  ${methods}
}
@main @MainActor struct Regression {
  static var checks = 0
  static func check(_ pass: Bool, _ note: String) { precondition(pass, note); checks += 1 }
  static func main() {
    let early = Probe()
    check(early.prepareForCallKitAudioActivation(callType: .video), "prepare succeeds")
    check(early.activeCallType == .video && early.configurationCount == 1, "correct mode prepared once")
    check(early.callKitAudioActivationRequired && !early.callKitAudioSessionActive, "await system activation")
    early.handleCallKitAudioSessionActivated(.sharedInstance())
    check(early.callKitAudioSessionActive && early.starts == 0, "activation before room does not start early")
    early.connectionState = .connected
    early.startLocalMediaAfterRoomEntered()
    check(early.starts == 1, "room after activation starts once")
    early.handleCallKitAudioSessionActivated(.sharedInstance())
    check(early.starts == 1 && early.configurationCount == 1, "activation does not reconfigure or duplicate media")
    early.handleCallKitAudioSessionDeactivated()
    check(!early.callKitAudioSessionActive && !early.localMediaStarted, "deactivation clears started state")
    early.handleCallKitAudioSessionActivated(.sharedInstance())
    check(early.starts == 2, "reactivation resumes connected call")
    let late = Probe(); late.connectionState = .connected
    _ = late.prepareForCallKitAudioActivation(callType: .audio)
    check(late.starts == 0, "connected room still waits for system activation")
    late.handleCallKitAudioSessionActivated(.sharedInstance())
    check(late.starts == 1, "activation after room starts audio")
    let direct = Probe(); direct.localMediaStarted = true
    direct.handleCallKitAudioSessionDeactivated()
    check(direct.localMediaStarted, "stale CallKit deactivation cannot stop App-owned audio")
    direct.handleCallKitAudioSessionActivated(.sharedInstance())
    check(!direct.callKitAudioSessionActive && direct.starts == 0, "unowned activation ignored")
    let failed = Probe(); failed.configurationSucceeds = false
    check(!failed.prepareForCallKitAudioActivation(callType: .audio), "configuration failure reported")
    check(!failed.callKitAudioActivationRequired, "failed preparation does not claim session")
    print("PASS: \\(checks) extracted production audio-state fixture checks; not physical call proof")
  }
}
`;
const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'imim-call-audio-'));
const binary = path.join(directory, 'regression');
const env = {...process.env, DEVELOPER_DIR: '/Applications/Xcode.app/Contents/Developer'};
const compile = spawnSync('xcrun', ['swiftc', '-swift-version', '5', '-parse-as-library', '-', '-o', binary],
  {input: source, encoding: 'utf8', env});
assert.equal(compile.status, 0, compile.stderr);
const run = spawnSync(binary, [], {encoding: 'utf8'});
process.stdout.write(run.stdout);
assert.equal(run.status, 0, run.stderr);
console.log('PASS: synchronous prepare-before-fulfill, delegate ordering and media-start source guards');
console.log('Fixture artifact: ' + directory);
