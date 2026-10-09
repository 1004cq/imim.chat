import Foundation

@main
private struct ChatBottomScrollRegression {
    static func main() {
        var checks = 0
        func check(_ condition: Bool, _ note: String) {
            precondition(condition, note)
            checks += 1
        }
        typealias Policy = ChatBottomScrollPolicy
        let reasons: [Policy.Reason] = [.initial, .outgoing, .incoming, .historyLoaded]

        // Exercise admission and delivery separately. Touch/geometry/motion may
        // change between message arrival and the deferred main-queue callback.
        for reason in reasons {
            for nearAtRequest in [false, true] {
                for scrollingAtRequest in [false, true] {
                    for scrollingAtDelivery in [false, true] {
                        for reduceMotion in [false, true] {
                            var policy = Policy()
                            let ticket = policy.request(reason, isNearBottom: nearAtRequest, isUserScrolling: scrollingAtRequest)
                            let admitted = !scrollingAtRequest && (!reason.requiresNearBottom || nearAtRequest)
                            check((ticket != nil) == admitted, "admission must respect current user intent")
                            if let ticket {
                                let delivered = !scrollingAtDelivery
                                let result = policy.consume(ticket,
                                                            isUserScrolling: scrollingAtDelivery, reduceMotion: reduceMotion)
                                check(result == (delivered ? reason.animated && !reduceMotion : nil), "delivery must recheck latest UI state")
                                check(policy.consume(ticket, isUserScrolling: false, reduceMotion: false) == nil,
                                      "callback must be one-shot, including rejected delivery")
                            }
                        }
                    }
                }
            }
        }

        var burst = Policy()
        var tickets: [UInt64] = []
        for _ in 0..<1000 {
            if let ticket = burst.request(.incoming, isNearBottom: true, isUserScrolling: false) { tickets.append(ticket) }
        }
        check(tickets.count == 1, "one callback is queued for a burst before layout")
        check(burst.consume(tickets[0], isUserScrolling: false, reduceMotion: false) == true,
              "coalesced incoming burst still follows bottom")

        // Cancel old work; a callback from the previous render/lifecycle must
        // neither scroll nor consume a newer pending request.
        var cancelled = Policy()
        let oldTicket = cancelled.request(.incoming, isNearBottom: true, isUserScrolling: false)!
        cancelled.cancel()
        let newTicket = cancelled.request(.outgoing, isNearBottom: false, isUserScrolling: false)!
        check(newTicket != oldTicket, "new work has independent identity")
        check(cancelled.consume(oldTicket, isUserScrolling: false, reduceMotion: false) == nil,
              "stale callback cannot override user scroll or a newer request")
        check(cancelled.consume(newTicket, isUserScrolling: false, reduceMotion: false) == true,
              "explicit outgoing message preserves prior jump-to-bottom behavior")

        // Stronger pending intent wins regardless of request order. Initial
        // positioning remains nonanimated, even if network messages also arrive.
        for first in reasons {
            for second in reasons {
                var policy = Policy()
                let ticket = policy.request(first, isNearBottom: true, isUserScrolling: false)!
                check(policy.request(second, isNearBottom: true, isUserScrolling: false) == nil, "pending work is coalesced")
                let winner = first.rawValue > second.rawValue ? first : second
                check(policy.consume(ticket, isUserScrolling: false, reduceMotion: false)
                      == winner.animated, "preserve strongest intent even if appended media moves bottom outside threshold")
            }
        }

        // No automatic replay after user scroll; a genuinely new request is
        // required after reaching bottom again. View disappearance uses cancel.
        var drag = Policy()
        let dragTicket = drag.request(.incoming, isNearBottom: true, isUserScrolling: false)!
        drag.cancel()
        check(drag.consume(dragTicket, isUserScrolling: false, reduceMotion: false) == nil,
              "cancelled drag request is not replayed at idle")
        let followTicket = drag.request(.incoming, isNearBottom: true, isUserScrolling: false)!
        check(drag.consume(followTicket, isUserScrolling: false, reduceMotion: true) == false,
              "Reduce Motion scroll is immediate")

        print("CHAT BOTTOM SCROLL REGRESSION: \(checks) checks passed")
        print("SYNTHETIC CALLBACK BURST: 1000 legacy queued actions -> \(tickets.count) admitted callback; NOT UI/FPS/anchor-offset evidence")
    }
}
