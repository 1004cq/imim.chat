import Foundation

// Concatenated with the production helper so private cache behavior can be
// tested without adding an App target or exporting formatter references.
@main
private struct ChatDateFormattingRegression {
    typealias Cache = ChatDateFormatterCache

    private final class ContextBox: @unchecked Sendable {
        // Test-only mutable context: all reads/writes use this lock. No async wait.
        private let lock = NSLock()
        private var value: Cache.Context
        init(_ value: Cache.Context) { self.value = value }
        func snapshot() -> Cache.Context {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
        func set(_ next: Cache.Context) {
            lock.lock()
            defer { lock.unlock() }
            value = next
        }
    }

    static func formatter(_ context: Cache.Context? = nil) -> DateFormatter {
        let result = DateFormatter()
        if let context {
            result.locale = context.locale
            result.calendar = context.calendar
            result.timeZone = context.timeZone
        }
        return result
    }

    @inline(never)
    static func legacy(_ date: Date, pattern: String? = nil, context: Cache.Context? = nil) -> String {
        let result = formatter(context)
        result.dateFormat = pattern ?? (Calendar.current.isDateInToday(date) ? "HH:mm" : "MM/dd")
        return result.string(from: date)
    }

    static func configuredContext(_ locale: String, _ calendar: Calendar.Identifier, _ zone: String) -> Cache.Context {
        let timeZone = TimeZone(identifier: zone)!
        var calendar = Calendar(identifier: calendar)
        calendar.locale = Locale(identifier: locale)
        calendar.timeZone = timeZone
        return Cache.Context(locale: Locale(identifier: locale), calendar: calendar, timeZone: timeZone)
    }

    static func samples() -> [Date] {
        let now = Date()
        let start = Calendar.current.startOfDay(for: now)
        return [now, start, start.addingTimeInterval(-1), start.addingTimeInterval(1),
                Calendar.current.date(byAdding: .day, value: 1, to: start)!,
                Calendar.current.date(byAdding: .year, value: -1, to: start)!,
                Date(timeIntervalSince1970: 0), Date(timeIntervalSince1970: -86400)]
            + [1709164800.0, 1710064740, 1710064800, 1730624340, 1730624400,
               1729987140, 1729987200, 1893456000].map(Date.init(timeIntervalSince1970:))
    }

    static func runBehaviorChecks() -> Int {
        var checks = 0
        for date in samples() {
            precondition(date.chatListTimeText == legacy(date))
            precondition(date.messageTimeText == legacy(date, pattern: "HH:mm"))
            checks += 2
        }

        // Configured fixtures exercise the actual cache, including calendars,
        // non-Latin digits, DST boundaries and fractional-offset time zones.
        for locale in ["en_US", "en_GB", "zh_CN", "zh_Hant", "ar_SA", "fa_IR", "th_TH"] {
            for calendar in [Calendar.Identifier.gregorian, .buddhist, .islamicCivil] {
                for zone in ["UTC", "Asia/Shanghai", "America/Los_Angeles", "Europe/Berlin", "Asia/Kathmandu"] {
                    let context = configuredContext(locale, calendar, zone)
                    let cache = Cache(notificationCenter: NotificationCenter(), contextProvider: { context },
                                      makeFormatter: { formatter(context) })
                    for date in samples() {
                        for pattern in [Cache.Pattern.time, .monthDay] {
                            precondition(cache.string(from: date, pattern: pattern)
                                         == legacy(date, pattern: pattern.rawValue, context: context))
                            checks += 1
                        }
                    }
                    precondition(cache.diagnostics().cached == 2)
                    precondition(cache.diagnostics().constructed == 2)
                    checks += 2
                }
            }
        }

        let center = NotificationCenter()
        let box = ContextBox(configuredContext("en_US", .gregorian, "UTC"))
        let cache = Cache(notificationCenter: center, contextProvider: { box.snapshot() },
                          makeFormatter: { formatter(box.snapshot()) })
        let fixture = Date(timeIntervalSince1970: 1710064800)
        for context in [configuredContext("en_US", .gregorian, "UTC"),
                        configuredContext("zh_CN", .gregorian, "UTC"),
                        configuredContext("zh_CN", .buddhist, "UTC"),
                        configuredContext("zh_CN", .buddhist, "Asia/Kathmandu")] {
            box.set(context)
            for pattern in [Cache.Pattern.time, .monthDay] {
                precondition(cache.string(from: fixture, pattern: pattern)
                             == legacy(fixture, pattern: pattern.rawValue, context: context))
                checks += 1
            }
            precondition(cache.diagnostics().cached == 2)
            checks += 1
        }
        precondition(cache.diagnostics().constructed == 8)
        checks += 1
        for name in [NSLocale.currentLocaleDidChangeNotification, .NSSystemTimeZoneDidChange] {
            center.post(name: name, object: nil)
            precondition(cache.diagnostics().cached == 0)
            precondition(cache.string(from: fixture, pattern: .time)
                         == legacy(fixture, pattern: "HH:mm", context: box.snapshot()))
            checks += 2
        }

        weak var releasedCache: Cache?
        autoreleasepool {
            let temporaryCache = Cache(notificationCenter: center)
            releasedCache = temporaryCache
            _ = temporaryCache.string(from: fixture, pattern: .time)
        }
        precondition(releasedCache == nil, "Notification observers must not retain the cache")
        center.post(name: NSLocale.currentLocaleDidChangeNotification, object: nil)
        checks += 1

        // NSTimeZone.default changes only this standalone process, not macOS
        // settings. Test automatic context refresh even without notification.
        let originalZone = NSTimeZone.default
        for zone in ["UTC", "Asia/Shanghai", "America/Los_Angeles", "Asia/Kathmandu", originalZone.identifier] {
            NSTimeZone.default = TimeZone(identifier: zone)!
            for date in samples() {
                precondition(date.chatListTimeText == legacy(date))
                precondition(date.messageTimeText == legacy(date, pattern: "HH:mm"))
                checks += 2
            }
        }
        NSTimeZone.default = originalZone

        let concurrentContext = configuredContext("en_GB", .gregorian, "Europe/Berlin")
        let concurrentCenter = NotificationCenter()
        let concurrentCache = Cache(notificationCenter: concurrentCenter, contextProvider: { concurrentContext },
                                    makeFormatter: { formatter(concurrentContext) })
        let dates = samples()
        let expected = dates.map { legacy($0, pattern: "HH:mm", context: concurrentContext) }
        DispatchQueue.concurrentPerform(iterations: 2048) { index in
            if index.isMultiple(of: 17) {
                concurrentCenter.post(name: NSLocale.currentLocaleDidChangeNotification, object: nil)
            }
            let slot = index % dates.count
            precondition(concurrentCache.string(from: dates[slot], pattern: .time) == expected[slot])
        }
        checks += 2048
        precondition(concurrentCache.diagnostics().cached <= 2)
        return checks + 1
    }

    @inline(never)
    static func checksum(_ dates: [Date], cached: Bool) -> Int {
        dates.reduce(0) { $0 + (cached ? $1.chatListTimeText : legacy($1)).utf8.count }
    }

    static func median(_ operation: () -> Int) -> Double {
        let expected = operation()
        return (0..<7).map { _ in
            let start = DispatchTime.now().uptimeNanoseconds
            for _ in 0..<3 { precondition(operation() == expected) }
            return Double(DispatchTime.now().uptimeNanoseconds - start) / 3 / 1_000_000
        }.sorted()[3]
    }

    static func main() throws {
        let checks = runBehaviorChecks()
        let start = Calendar.current.startOfDay(for: Date())
        let dates = (0..<500).map { start.addingTimeInterval(-Double($0 % 30) * 86400) }
        precondition(checksum(dates, cached: true) == checksum(dates, cached: false))
        let legacyMS = median { checksum(dates, cached: false) }
        let cachedMS = median { checksum(dates, cached: true) }
        let before = Cache.shared.diagnostics().constructed
        for _ in 0..<20 { _ = checksum(dates, cached: true) }
        precondition(Cache.shared.diagnostics().constructed == before)
        precondition(Cache.shared.diagnostics().cached <= 2)
        let report: [String: Any] = [
            "kind": "synthetic_mac_formatter_microbenchmark_not_device_ui",
            "thread_sanitizer_enabled": ProcessInfo.processInfo.environment["CHAT_DATE_TSAN"] == "1",
            "behavior_checks": checks + 3,
            "system_locale": Locale.current.identifier,
            "system_time_zone": TimeZone.current.identifier,
            "fixture_count": dates.count,
            "legacy_500_dates_median_ms": legacyMS,
            "cached_500_dates_median_ms": cachedMS,
            "warm_20_batches_new_formatters": Cache.shared.diagnostics().constructed - before,
            "timestamp": ISO8601DateFormatter().string(from: Date()),
        ]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys, .prettyPrinted])
        print(String(decoding: data, as: UTF8.self))
    }
}
