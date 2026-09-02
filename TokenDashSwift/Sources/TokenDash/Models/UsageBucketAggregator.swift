import Foundation

/// Aggregates daemon blocks into chart buckets for a given hourly range.
/// Pure function so it is directly unit-testable without the network layer.
enum UsageBucketAggregator {

    struct Aggregation {
        let buckets: [TimeBucket]
        /// false when a fine-grained request came back hour-aligned only
        /// (legacy daemon ignored the granularity parameter) — callers fall
        /// back to rendering the Today view instead.
        let granularityMatched: Bool
    }

    static func aggregate(_ responses: [BlocksResponse], range: SettingsStore.HourlyRange, now: Date) -> Aggregation {
        let calendar = Calendar.current
        let bucketMinutes = range.bucketMinutes

        let windowStart: Date
        let windowEnd: Date
        switch range {
        case .today:
            let dayStart = calendar.startOfDay(for: now)
            windowStart = dayStart
            windowEnd = dayStart.addingTimeInterval(24 * 3600)
        case .threeHours, .oneHour:
            let windowSeconds: TimeInterval = range == .threeHours ? 3 * 3600 : 3600
            let alignedNow = align(now, to: bucketMinutes, calendar: calendar)
            windowStart = alignedNow.addingTimeInterval(-windowSeconds + TimeInterval(bucketMinutes) * 60)
            windowEnd = windowStart.addingTimeInterval(windowSeconds)
        }

        var totals: [Date: Int] = [:]
        var sawSubHourBucket = false

        for response in responses {
            for block in response.blocks {
                guard let start = ISO8601LocalFormatter.date(from: block.startTime) else { continue }
                guard start >= windowStart, start < windowEnd else { continue }
                let bucketStart = align(start, to: bucketMinutes, calendar: calendar)
                totals[bucketStart, default: 0] += block.totalTokens
                // A start minute that is not hour-aligned proves the daemon
                // honored the fine-grained request (legacy data is :00 only).
                if bucketMinutes < 60, calendar.component(.minute, from: start) % 60 != 0 {
                    sawSubHourBucket = true
                }
            }
        }

        let maxTokens = totals.values.max() ?? 0
        var buckets: [TimeBucket] = []
        var cursor = windowStart
        while cursor < windowEnd {
            let tokens = totals[cursor] ?? 0
            buckets.append(TimeBucket(
                start: cursor,
                minutes: bucketMinutes,
                tokens: tokens,
                isPeak: tokens > 0 && tokens == maxTokens
            ))
            cursor = cursor.addingTimeInterval(TimeInterval(bucketMinutes) * 60)
        }

        // An empty window cannot disprove granularity — treat it as matched
        // so the chart renders zero lines instead of falling back.
        let matched = range == .today
            || sawSubHourBucket
            || buckets.allSatisfy { $0.tokens == 0 }
        return Aggregation(buckets: buckets, granularityMatched: matched)
    }

    /// Floors a date onto the local wall-clock minute grid (11:37 -> 11:30
    /// for 15-minute buckets), matching how the daemon coarsens its 5-minute
    /// base buckets. `Calendar.dateInterval(of:value:for:)` is unavailable in
    /// this SDK, so the floor is computed from the minute-of-day.
    private static func align(_ date: Date, to minutes: Int, calendar: Calendar) -> Date {
        let dayStart = calendar.startOfDay(for: date)
        let comps = calendar.dateComponents([.hour, .minute], from: date)
        let minuteOfDay = (comps.hour ?? 0) * 60 + (comps.minute ?? 0)
        let alignedMinute = minuteOfDay - minuteOfDay % minutes
        return dayStart.addingTimeInterval(TimeInterval(alignedMinute * 60))
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
