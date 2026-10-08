import Foundation

// Standalone synthetic microbenchmark. Not linked into App and not an FPS test.
private struct FixtureChat {
    let chatId: String
    let marker: Int
}

@main
private struct ConversationLookupBaseline {
    @inline(never)
    static func scan(_ chats: [FixtureChat], ids: [String]) -> Int {
        ids.reduce(0) { sum, id in sum + (chats.first { $0.chatId == id }?.marker ?? -1) }
    }

    @inline(never)
    static func indexed(_ chats: [FixtureChat], ids: [String]) -> Int {
        // Candidate only. Preserve current first-match behavior for duplicate IDs.
        var byId: [String: FixtureChat] = [:]
        byId.reserveCapacity(chats.count)
        for chat in chats where byId[chat.chatId] == nil { byId[chat.chatId] = chat }
        return ids.reduce(0) { $0 + (byId[$1]?.marker ?? -1) }
    }

    static func measure(_ operation: () -> Int, iterations: Int) -> Double {
        var checksum = 0
        let start = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<iterations { checksum &+= operation() }
        let elapsed = DispatchTime.now().uptimeNanoseconds - start
        precondition(checksum >= 0)
        return Double(elapsed) / Double(iterations) / 1_000_000
    }

    static func median(_ operation: () -> Int, iterations: Int) -> Double {
        _ = operation() // Warm code/data, not a cold-start measurement.
        return (0..<7).map { _ in measure(operation, iterations: iterations) }.sorted()[3]
    }

    static func main() throws {
        let duplicates = [FixtureChat(chatId: "same", marker: 1), FixtureChat(chatId: "same", marker: 2)]
        precondition(scan(duplicates, ids: ["same", "missing"]) == indexed(duplicates, ids: ["same", "missing"]))
        var rows: [[String: Any]] = []
        for count in [100, 500, 1000, 5000] {
            let chats = (0..<count).map { FixtureChat(chatId: "fixture-\($0)", marker: $0) }
            for scenario in ["full_traversal", "tail_visible_12"] {
                let ids = scenario == "full_traversal" ? chats.map(\.chatId) : chats.suffix(12).map(\.chatId)
                let expected = scan(chats, ids: ids)
                precondition(indexed(chats, ids: ids) == expected)
                var comparisons = 0
                for id in ids { _ = chats.first { chat in comparisons += 1; return chat.chatId == id } }
                rows.append([
                    "count": count, "scenario": scenario, "lookup_count": ids.count,
                    "linear_comparisons": comparisons,
                    "current_scan_median_ms": median({ scan(chats, ids: ids) }, iterations: 20),
                    "candidate_index_including_build_median_ms": median({ indexed(chats, ids: ids) }, iterations: 20),
                ])
            }
        }
        // Call the actual app extension without modifying it. This measures only
        // formatting, not SwiftData access, filtering, body updates or rendering.
        let today = Calendar.current.startOfDay(for: Date())
        let dates = (0..<500).map { today.addingTimeInterval(-Double($0 % 30) * 86400) }
        let formatterMs = median({ dates.reduce(0) { $0 + $1.chatListTimeText.utf8.count } }, iterations: 3)
        let output: [String: Any] = [
            "kind": "synthetic_mac_microbenchmark_not_device_ui",
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "lookup": rows,
            "actual_chat_list_time_format_500_dates_median_ms": formatterMs,
            "semantics_check": "duplicate IDs retain first match; missing IDs agree",
        ]
        let data = try JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys])
        print(String(decoding: data, as: UTF8.self))
    }
}
