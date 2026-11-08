import Foundation
import CoreGraphics

@main @MainActor struct StickerPlaybackRegression {
    static var checks = 0
    static func check(_ condition: Bool, _ label: String) {
        if !condition { FileHandle.standardError.write(Data("FAILED after \(checks) checks: \(label)\n".utf8)) }
        precondition(condition, label)
        checks += 1
    }
    static func rejects(_ operation: () throws -> Void) {
        do {
            try operation()
            FileHandle.standardError.write(Data("FAILED expected rejection after \(checks) checks\n".utf8))
            preconditionFailure("Expected rejection")
        }
        catch { checks += 1 }
    }
    static func main() throws {
        var budget = StickerPlaybackBudget(capacity: 3)
        let ids = (0..<8).map { _ in UUID() }
        for id in ids.prefix(3) { check(budget.request(id), "first visible leases admitted") }
        check(!budget.request(ids[3]), "budget does not exceed cap")
        check(!budget.request(ids[3]) && budget.waiting == [ids[3]], "pending request deduplicated")
        _ = budget.request(ids[4])
        budget.release(ids[0])
        check(budget.active == [ids[1], ids[2], ids[3]], "release promotes FIFO waiter")
        budget.release(ids[4])
        check(budget.waiting.isEmpty, "offscreen waiter removed")
        check(budget.request(ids[1]) && budget.active.count == 3, "same lease request is idempotent")
        _ = budget.request(ids[5])
        budget.prioritize(ids[5])
        check(budget.active.contains(ids[5]) && budget.active.count == 3, "tap replay promotes selected lease")
        check(budget.waiting.count == 1, "displaced visible lease queued")
        budget.prioritize(UUID())
        check(budget.active.count == 3, "unknown replay cannot acquire a slot")
        for step in 0..<1000 {
            let id = ids[step % ids.count]
            if step % 3 == 0 { budget.release(id) }
            else if step % 5 == 0 { budget.prioritize(id) }
            else { _ = budget.request(id) }
            check(budget.active.count <= 3, "bounded capacity under churn")
            check(Set(budget.active).count == budget.active.count, "no duplicate active lease")
            check(Set(budget.waiting).count == budget.waiting.count && Set(budget.waiting).isDisjoint(with: budget.active), "waiting lease invariants")
        }
        for id in ids { budget.release(id) }
        check(budget.active.isEmpty && budget.waiting.isEmpty, "all rows disappear releases every lease")
        let viewport = CGSize(width: 390, height: 600)
        check(StickerPlaybackEligibility.isVisible(frame: CGRect(x: 10, y: 10, width: 176, height: 176), viewport: viewport), "viewport admits visible sticker")
        check(StickerPlaybackEligibility.isVisible(frame: CGRect(x: 10, y: -175, width: 176, height: 176), viewport: viewport), "partial intersection visible")
        for frame in [CGRect(x: 0, y: -176, width: 176, height: 176), CGRect(x: 0, y: 600, width: 176, height: 176), CGRect(x: 390, y: 0, width: 10, height: 10), .zero, .null] {
            check(!StickerPlaybackEligibility.isVisible(frame: frame, viewport: viewport), "offscreen/invalid frames rejected")
        }
        check(!StickerPlaybackEligibility.isVisible(frame: .infinite, viewport: viewport), "infinite frame rejected")
        check(!StickerPlaybackEligibility.isVisible(frame: CGRect(x: 0, y: 0, width: 1, height: 1), viewport: .zero), "zero viewport rejected")
        for visible in [false, true] { for active in [false, true] { for reduced in [false, true] { for power in [false, true] { for failed in [false, true] {
            check(StickerPlaybackEligibility.mayAnimate(visible: visible, activeScene: active, reduceMotion: reduced, lowPower: power, failed: failed) == (visible && active && !reduced && !power && !failed), "motion/scene/power policy")
        } } } } }
        // Reproduce the phone trace: a geometry event arrived after activation,
        // carrying an older inactive closure. Reconciliation must receive the new
        // request value rather than consult that closure's environment snapshot.
        let inactiveRequest = StickerPlaybackRequest(visible: true, activeScene: false,
            reduceMotion: false, lowPower: false, failed: false, animated: true, generation: 0)
        let resumedRequest = StickerPlaybackRequest(visible: true, activeScene: true,
            reduceMotion: false, lowPower: false, failed: false, animated: true, generation: 0)
        check(!inactiveRequest.eligible && resumedRequest.eligible && inactiveRequest != resumedRequest,
              "activation invalidates stale paused request without another geometry change")
        var lifecycleBudget = StickerPlaybackBudget(capacity: 1)
        let lifecycleID = UUID()
        func reconcile(_ request: StickerPlaybackRequest) -> Bool {
            if request.eligible { return lifecycleBudget.request(lifecycleID) }
            lifecycleBudget.release(lifecycleID); return false
        }
        check(!reconcile(inactiveRequest), "inactive view pauses")
        check(reconcile(resumedRequest), "fresh activation grants lease")
        check(reconcile(resumedRequest), "unchanged reconciliation keeps one lease")
        check(!reconcile(inactiveRequest) && lifecycleBudget.active.isEmpty, "background releases lease")
        check(reconcile(resumedRequest), "returning to foreground resumes")
        for gate in 0..<5 {
            let paused = StickerPlaybackRequest(visible: gate != 0, activeScene: true,
                reduceMotion: gate == 1, lowPower: gate == 2, failed: gate == 3,
                animated: gate != 4, generation: 1)
            check(!reconcile(paused), "offscreen, motion, power, failure and static asset remain paused")
            check(reconcile(resumedRequest), "clearing each pause condition resumes")
        }
        let promoted = StickerPlaybackRequest(visible: true, activeScene: true,
            reduceMotion: false, lowPower: false, failed: false, animated: true, generation: 1)
        check(promoted != resumedRequest && promoted.eligible, "lease promotion causes fresh reconciliation")
        let returnedRequest = StickerPlaybackRequest(visible: true, activeScene: true,
            reduceMotion: false, lowPower: false, failed: false, animated: true, generation: 0,
            appearanceGeneration: 1)
        check(returnedRequest.eligible == resumedRequest.eligible && returnedRequest != resumedRequest,
              "retained row remount invalidates request even when no false body was observed")
        check(!reconcile(inactiveRequest), "leaving chat releases its animation lease")
        check(reconcile(returnedRequest), "retained chat return reacquires its released lease")
        for visit in 2...15 {
            _ = reconcile(inactiveRequest)
            let request = StickerPlaybackRequest(visible: true, activeScene: true,
                reduceMotion: false, lowPower: false, failed: false, animated: true, generation: 0,
                appearanceGeneration: visit)
            check(request != returnedRequest && reconcile(request) && lifecycleBudget.active.count == 1,
                  "repeated chat exits and returns do not leak or lose leases")
        }
        let fixture = URL(fileURLWithPath: CommandLine.arguments[1])
        let json = try Data(contentsOf: fixture.appendingPathComponent("fixture.json"))
        let compressed = try Data(contentsOf: fixture.appendingPathComponent("fixture.tgs"))
        check(try StickerAnimationDecode.jsonData(compressed, isTGS: true) == json, "actual gzip roundtrip")
        check(try StickerAnimationDecode.jsonData(json, isTGS: false) == json, "plain JSON preserved")
        rejects { _ = try StickerAnimationDecode.jsonData(Data(), isTGS: true) }
        rejects { _ = try StickerAnimationDecode.jsonData(Data([1, 2, 3]), isTGS: true) }
        rejects { _ = try StickerAnimationDecode.jsonData(compressed.dropLast(4), isTGS: true) }
        rejects { _ = try StickerAnimationDecode.jsonData(compressed + compressed, isTGS: true) }
        rejects { _ = try StickerAnimationDecode.jsonData(Data(repeating: 1, count: StickerAnimationDecode.maximumDownloadedBytes + 1), isTGS: false) }
        rejects { _ = try StickerAnimationDecode.jsonData(Data(contentsOf: fixture.appendingPathComponent("oversized.tgs")), isTGS: true) }
        check(try StickerPackLink.shortName(" https://t.me/addstickers/Fixture_Pack ") == "Fixture_Pack", "Telegram link normalized")
        check(try StickerPackLink.shortName("tg://addstickers?set=Fixture_Pack") == "Fixture_Pack", "Telegram scheme normalized")
        check(try StickerPackLink.shortName("Fixture_Pack") == "Fixture_Pack", "short name preserved")
        for link in ["", "bad-name", "https://evil.test/addstickers/Fixture_Pack", "https://t.me:443/addstickers/Fixture_Pack", "https://x@t.me/addstickers/Fixture_Pack", "https://t.me/addstickers/Fixture_Pack#x", "https://t.me/addstickers/Fixture_Pack?token=x", "tg://addstickers?set=Fixture_Pack&set=Other", "file:///Fixture_Pack", String(repeating: "x", count: 65)] {
            rejects { _ = try StickerPackLink.shortName(link) }
        }
        print("PASS: \(checks) actual playback budget, viewport/motion, bounded gzip and strict pack-link checks. Value/fixture evidence, not device animation FPS.")
    }
}
