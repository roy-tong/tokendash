import XCTest
@testable import TokenDash

final class UsageBucketAggregatorTests: XCTestCase {
    private var formatter: DateFormatter {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        f.timeZone = TimeZone.current
        return f
    }

    private func blocks(_ starts: [String], tokens: Int = 100) -> BlocksResponse {
        BlocksResponse(blocks: starts.map {
            BlockEntry(startTime: $0, totalTokens: tokens)
        })
    }

    private var now: Date { formatter.date(from: "2026-09-01T14:07:00")! }

    func testTodayBucketsFull24HourSkeleton() {
        let resp = blocks(["2026-09-01T09:30:00", "2026-09-01T10:45:00", "2026-08-31T23:00:00"])
        let result = UsageBucketAggregator.aggregate([resp], range: .today, now: now)
        // The aggregator returns the full 24-bucket skeleton (elapsed filtering
        // is done by the view's displayBuckets).
        XCTAssertEqual(result.buckets.count, 24)
        XCTAssertEqual(result.buckets[9].tokens, 100)
        XCTAssertEqual(result.buckets[10].tokens, 100)
        XCTAssertEqual(result.buckets[14].tokens, 0, "future hours are zero")
        XCTAssertTrue(result.granularityMatched, "today is always matched (no downgrade concept)")
    }

    func testThreeHoursProducesTwelveFifteenMinBuckets() {
        let resp = blocks(["2026-09-01T11:30:00", "2026-09-01T14:00:00", "2026-09-01T10:59:00"])
        let result = UsageBucketAggregator.aggregate([resp], range: .threeHours, now: now)
        // Window = floor(14:07, 15m) - 3h + 15m = [11:15, 14:15), 12 buckets.
        XCTAssertEqual(result.buckets.count, 12)
        let byStart = Dictionary(uniqueKeysWithValues: result.buckets.map { ($0.start, $0.tokens) })
        let t1130 = formatter.date(from: "2026-09-01T11:30:00")!
        let t1400 = formatter.date(from: "2026-09-01T14:00:00")!
        // Block starts floor onto the bucket grid (matching the daemon's own
        // coarsening), so 11:30 lands in the 11:30 bucket — not 11:15.
        XCTAssertEqual(byStart[t1130], 100, "11:30 floors into the 11:30 bucket")
        XCTAssertEqual(byStart[t1400], 100, "14:00 is the in-progress bucket")
        XCTAssertNil(byStart[formatter.date(from: "2026-09-01T10:59:00")!], "outside the window is dropped")
    }

    func testOneHourProducesTwelveFiveMinBuckets() {
        let resp = blocks(["2026-09-01T13:12:00", "2026-09-01T13:59:00"])
        let result = UsageBucketAggregator.aggregate([resp], range: .oneHour, now: now)
        XCTAssertEqual(result.buckets.count, 12)
        let starts = result.buckets.map { formatter.string(from: $0.start) }
        // Window start = floor(14:07, 5m) - 1h + 5m = 14:05 - 1h + 5m = 13:10.
        XCTAssertEqual(starts.first, "2026-09-01T13:10:00")
        XCTAssertEqual(starts.last, "2026-09-01T14:05:00")
    }

    func testMultipleAgentsSumIntoSameBuckets() {
        let a = blocks(["2026-09-01T13:12:00"], tokens: 100)
        let b = blocks(["2026-09-01T13:13:00"], tokens: 40)
        let result = UsageBucketAggregator.aggregate([a, b], range: .oneHour, now: now)
        let t1310 = formatter.date(from: "2026-09-01T13:10:00")!
        XCTAssertEqual(result.buckets.first { $0.start == t1310 }?.tokens, 140)
    }

    func testCrossDayWindowIncludesYesterdayBuckets() {
        // now = 00:07 early morning; the 3h window reaches back to 21:15
        // the previous day.
        let lateNight = formatter.date(from: "2026-09-02T00:07:00")!
        let resp = blocks(["2026-09-01T22:30:00"])
        let result = UsageBucketAggregator.aggregate([resp], range: .threeHours, now: lateNight)
        XCTAssertEqual(result.buckets.first.map { formatter.string(from: $0.start) }, "2026-09-01T21:15:00")
        XCTAssertTrue(result.buckets.contains { $0.tokens == 100 })
    }

    func testGranularityMismatchDetectedForLegacyDaemon() {
        // Fine-grained request but every returned start is hour-aligned (a
        // legacy daemon ignored the parameter) -> matched = false.
        let resp = blocks(["2026-09-01T14:00:00", "2026-09-01T13:00:00"])
        let result = UsageBucketAggregator.aggregate([resp], range: .oneHour, now: now)
        XCTAssertFalse(result.granularityMatched, "legacy hour data should trigger the fallback")
    }

    func testIsPeakFlagsMaxBucketOnly() {
        let resp = blocks(["2026-09-01T13:12:00", "2026-09-01T13:13:00", "2026-09-01T13:13:30"], tokens: 50)
        let result = UsageBucketAggregator.aggregate([resp], range: .oneHour, now: now)
        XCTAssertEqual(result.buckets.filter(\.isPeak).count, 1)
    }
}
