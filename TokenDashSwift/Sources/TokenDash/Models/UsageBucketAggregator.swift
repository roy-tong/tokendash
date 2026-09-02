import Foundation

/// Aggregates daemon blocks into a single 5-minute bucket base and derives
/// every chart range (Today / 3H / 1H) from it locally — one fetch serves all
/// tabs, so switching ranges is instant with no refetch gap.
/// Pure functions so they are directly unit-testable without the network layer.
enum UsageBucketAggregator {

    /// How far back the 5-minute base keeps buckets. The widest view needs
    /// today plus a 3-hour rolling window that can reach into yesterday
    /// (~27h); 48h leaves comfortable headroom at trivial memory cost.
    private static let baseWindowHours: TimeInterval = 48 * 3600

    struct Aggregation {
        /// 5-minute buckets over the trailing base window (or 60-minute
        /// buckets from `legacyHourBuckets` when the daemon is pre-1.9.0).
        let buckets: [TimeBucket]
        /// false when the response came back hour-aligned only (legacy
        /// daemon ignored the granularity parameter) — callers store the
        /// legacy buckets instead and the chart renders the Today view.
        let granularityMatched: Bool
    }

    /// Parses daemon blocks into the 5-minute base. The request always asks
    /// for `granularity=5m`; a legacy daemon silently returns hour blocks,
    /// which `granularityMatched` detects.
    static func aggregate(_ responses: [BlocksResponse], now: Date) -> Aggregation {
        let calendar = Calendar.current
        let alignedNow = align(now, to: 5, calendar: calendar)
        let windowStart = align(
            alignedNow.addingTimeInterval(-baseWindowHours), to: 5, calendar: calendar)

        var totals: [Date: Int] = [:]
        var sawSubHourBucket = false

        for response in responses {
            for block in response.blocks {
                guard let start = ISO8601LocalFormatter.date(from: block.startTime) else { continue }
                guard start >= windowStart, start <= alignedNow else { continue }
                let bucketStart = align(start, to: 5, calendar: calendar)
                totals[bucketStart, default: 0] += block.totalTokens
                // A start minute that is not hour-aligned proves the daemon
                // honored the fine-grained request (legacy data is :00 only).
                if calendar.component(.minute, from: start) % 60 != 0 {
                    sawSubHourBucket = true
                }
            }
        }

        let buckets = skeletonBuckets(
            from: windowStart, to: alignedNow.addingTimeInterval(300),
            minutes: 5, totals: totals, calendar: calendar)

        // An empty window cannot disprove granularity — treat it as matched
        // so the chart renders zero lines instead of falling back.
        let matched = sawSubHourBucket || buckets.allSatisfy { $0.tokens == 0 }
        return Aggregation(buckets: buckets, granularityMatched: matched)
    }

    /// Today buckets built from hour-aligned legacy blocks (pre-1.9.0 daemon).
    /// The chart detects the 60-minute buckets and renders the Today view.
    static func legacyHourBuckets(_ responses: [BlocksResponse], now: Date) -> [TimeBucket] {
        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: now)
        let dayEnd = dayStart.addingTimeInterval(24 * 3600)

        var totals: [Date: Int] = [:]
        for response in responses {
            for block in response.blocks {
                guard let start = ISO8601LocalFormatter.date(from: block.startTime) else { continue }
                guard start >= dayStart, start < dayEnd else { continue }
                totals[align(start, to: 60, calendar: calendar), default: 0] += block.totalTokens
            }
        }
        return skeletonBuckets(
            from: dayStart, to: dayEnd, minutes: 60, totals: totals, calendar: calendar)
    }

    /// Derives the buckets for any chart range from the shared 5-minute base.
    /// Always returns the full window skeleton (zero buckets included); the
    /// Today view additionally filters to elapsed hours at render time.
    /// 60-minute input (legacy fallback) only supports `.today`.
    static func reaggregate(
        _ base: [TimeBucket],
        to range: SettingsStore.HourlyRange,
        now: Date
    ) -> [TimeBucket] {
        let calendar = Calendar.current
        let bucketMinutes = range.bucketMinutes

        let windowStart: Date
        let windowEnd: Date
        switch range {
        case .today:
            windowStart = calendar.startOfDay(for: now)
            windowEnd = windowStart.addingTimeInterval(24 * 3600)
        case .threeHours, .oneHour:
            // Complete coverage: the first bucket fully contains now−window,
            // the last bucket is the in-progress one containing now. That is
            // 13 buckets for a 12×granularity-wide window — one extra beats
            // dropping the oldest bucket's usage on the floor.
            let windowSeconds: TimeInterval = range == .threeHours ? 3 * 3600 : 3600
            windowStart = align(now.addingTimeInterval(-windowSeconds), to: bucketMinutes, calendar: calendar)
            windowEnd = align(now, to: bucketMinutes, calendar: calendar)
                .addingTimeInterval(TimeInterval(bucketMinutes) * 60)
        }

        var totals: [Date: Int] = [:]
        for bucket in base {
            guard bucket.start >= windowStart, bucket.start < windowEnd else { continue }
            totals[align(bucket.start, to: bucketMinutes, calendar: calendar), default: 0] += bucket.tokens
        }
        return skeletonBuckets(
            from: windowStart, to: windowEnd, minutes: bucketMinutes,
            totals: totals, calendar: calendar)
    }

    /// Floors a date onto the local wall-clock minute grid (11:37 -> 11:30
    /// for 15-minute buckets), matching how the daemon coarsens its 5-minute
    /// base buckets. `Calendar.dateInterval(of:value:for:)` is unavailable in
    /// this SDK, so the floor is computed from the minute-of-day.
    /// Internal: shared with HourlyChartView so hover alignment and the
    /// aggregation use one identical floor.
    static func align(_ date: Date, to minutes: Int, calendar: Calendar) -> Date {
        let dayStart = calendar.startOfDay(for: date)
        let comps = calendar.dateComponents([.hour, .minute], from: date)
        let minuteOfDay = (comps.hour ?? 0) * 60 + (comps.minute ?? 0)
        let alignedMinute = minuteOfDay - minuteOfDay % minutes
        return dayStart.addingTimeInterval(TimeInterval(alignedMinute * 60))
    }

    private static func skeletonBuckets(
        from windowStart: Date,
        to windowEnd: Date,
        minutes: Int,
        totals: [Date: Int],
        calendar: Calendar
    ) -> [TimeBucket] {
        let maxTokens = totals.values.max() ?? 0
        var buckets: [TimeBucket] = []
        var cursor = windowStart
        while cursor < windowEnd {
            let tokens = totals[cursor] ?? 0
            buckets.append(TimeBucket(
                start: cursor,
                minutes: minutes,
                tokens: tokens,
                isPeak: tokens > 0 && tokens == maxTokens
            ))
            cursor = cursor.addingTimeInterval(TimeInterval(minutes) * 60)
        }
        return buckets
    }
}

/// daemon blocks startTime is "yyyy-MM-dd'T'HH:mm[:ss]" with no zone — parsed
/// in the local timezone, matching how the daemon aggregates at Asia/Shanghai.
enum ISO8601LocalFormatter {
    private static let withSeconds: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        f.timeZone = TimeZone.current
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private static let dateOnly: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone.current
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    static func date(from string: String) -> Date? {
        withSeconds.date(from: string) ?? dateOnly.date(from: string)
    }
}
