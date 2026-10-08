import Foundation

/// The existing synchronous Date API is also usable outside UI isolation.
/// Safety invariant: context, cache and every formatter use stay under `lock`;
/// formatter references never escape. Observer tokens change only in init/deinit.
/// Replace this manual Sendable assertion with Mutex ownership when the minimum
/// OS supports it. Do not turn this into a cache of message/display strings.
private final class ChatDateFormatterCache: @unchecked Sendable {
    enum Pattern: String {
        case time = "HH:mm"
        case monthDay = "MM/dd"
    }

    struct Context: Equatable, Sendable {
        let locale: Locale
        let calendar: Calendar
        let timeZone: TimeZone

        static var current: Context {
            Context(locale: .current, calendar: .current, timeZone: NSTimeZone.default)
        }
    }

    static let shared = ChatDateFormatterCache()

    private let lock = NSLock()
    private let notificationCenter: NotificationCenter
    private let contextProvider: @Sendable () -> Context
    private let makeFormatter: @Sendable () -> DateFormatter
    private var context: Context?
    private var formatters: [Pattern: DateFormatter] = [:]
    private var observers: [NSObjectProtocol] = []
    #if CHAT_DATE_FORMATTING_TESTS
    private var constructionCount = 0
    #endif

    init(
        notificationCenter: NotificationCenter = .default,
        contextProvider: @escaping @Sendable () -> Context = { .current },
        makeFormatter: @escaping @Sendable () -> DateFormatter = { DateFormatter() }
    ) {
        self.notificationCenter = notificationCenter
        self.contextProvider = contextProvider
        self.makeFormatter = makeFormatter
        for name in [NSLocale.currentLocaleDidChangeNotification, .NSSystemTimeZoneDidChange] {
            observers.append(notificationCenter.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
                self?.invalidate()
            })
        }
    }

    deinit {
        for observer in observers {
            notificationCenter.removeObserver(observer)
        }
    }

    func string(from date: Date, pattern: Pattern) -> String {
        lock.lock()
        defer { lock.unlock() }

        let currentContext = contextProvider()
        if context != currentContext {
            formatters.removeAll(keepingCapacity: true)
            context = currentContext
        }
        if let formatter = formatters[pattern] {
            return formatter.string(from: date)
        }

        // Preserve the old Foundation defaults, including user preferences.
        // Explicit en_US_POSIX locale/calendar overrides would change behavior.
        let formatter = makeFormatter()
        formatter.dateFormat = pattern.rawValue
        formatters[pattern] = formatter
        #if CHAT_DATE_FORMATTING_TESTS
        constructionCount += 1
        #endif
        return formatter.string(from: date)
    }

    private func invalidate() {
        lock.lock()
        defer { lock.unlock() }
        context = nil
        formatters.removeAll(keepingCapacity: true)
    }

    #if CHAT_DATE_FORMATTING_TESTS
    func diagnostics() -> (cached: Int, constructed: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (formatters.count, constructionCount)
    }
    #endif
}

extension Date {
    var chatListTimeText: String {
        // Select the pattern each time: a cached formatter must not freeze "today".
        ChatDateFormatterCache.shared.string(
            from: self,
            pattern: Calendar.current.isDateInToday(self) ? .time : .monthDay
        )
    }

    var messageTimeText: String {
        ChatDateFormatterCache.shared.string(from: self, pattern: .time)
    }
}
