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

    private func date(_ s: String) -> Date { formatter.date(from: s)! }

    private var now: Date { date("2026-09-01T14:07:00") }

    // MARK: - aggregate (5-minute base)

    func testAggregateProducesFiveMinuteBucketsOnAlignedGrid() {
        let resp = blocks(["2026-09-01T09:31:00", "2026-09-01T09:34:00", "2026-09-01T09:59:00"])
        let result = UsageBucketAggregator.aggregate([resp], now: now)
        XCTAssertTrue(result.granularityMatched, "sub-hour start times prove fine-grained data")
        let byStart = Dictionary(uniqueKeysWithValues: result.buckets.map { ($0.start, $0.tokens) })
        XCTAssertEqual(byStart[date("2026-09-01T09:30:00")], 200, "09:31 与 09:34 落同一 5m 桶")
        XCTAssertEqual(byStart[date("2026-09-01T09:55:00")], 100, "09:59 落 09:55 桶")
        XCTAssertTrue(result.buckets.allSatisfy { $0.minutes == 5 })
    }

    func testAggregateKeepsCrossDayBuckets() {
        let lateNight = date("2026-09-02T00:07:00")
        let resp = blocks(["2026-09-01T22:33:00"])
        let result = UsageBucketAggregator.aggregate([resp], now: lateNight)
        XCTAssertTrue(result.buckets.contains {
            $0.start == date("2026-09-01T22:30:00") && $0.tokens == 100
        }, "48h 基座窗口保留昨天的 5m 桶（供跨天 3H 窗口派生）")
    }

    func testAggregateDetectsLegacyHourAlignedDaemon() {
        let resp = blocks(["2026-09-01T13:00:00", "2026-09-01T14:00:00"])
        let result = UsageBucketAggregator.aggregate([resp], now: now)
        XCTAssertFalse(result.granularityMatched, "全部整点对齐 = 旧 daemon 忽略了粒度参数")
    }

    func testAggregateEmptyWindowCountsAsMatched() {
        let result = UsageBucketAggregator.aggregate([blocks([])], now: now)
        XCTAssertTrue(result.granularityMatched, "空窗口无法证伪粒度，按 matched 处理渲染 0 线")
    }

    func testLegacyHourBucketsProducesTodaySkeleton() {
        let resp = blocks(["2026-09-01T09:00:00", "2026-08-31T23:00:00"])
        let buckets = UsageBucketAggregator.legacyHourBuckets([resp], now: now)
        XCTAssertEqual(buckets.count, 24)
        XCTAssertTrue(buckets.allSatisfy { $0.minutes == 60 })
        XCTAssertEqual(buckets[9].tokens, 100, "今天 9 点桶有值")
        XCTAssertFalse(buckets.contains { $0.start == date("2026-08-31T23:00:00") }, "昨天丢弃")
    }

    // MARK: - reaggregate (local range derivation)

    func testReaggregateTodayDerivesHourBucketsFromFiveMinuteBase() {
        let base = [
            TimeBucket(start: date("2026-09-01T09:05:00"), minutes: 5, tokens: 30, isPeak: false),
            TimeBucket(start: date("2026-09-01T09:25:00"), minutes: 5, tokens: 70, isPeak: false),
            TimeBucket(start: date("2026-09-01T10:45:00"), minutes: 5, tokens: 100, isPeak: false),
        ]
        let buckets = UsageBucketAggregator.reaggregate(base, to: .today, now: now)
        XCTAssertEqual(buckets.count, 24, "today 完整骨架")
        XCTAssertTrue(buckets.allSatisfy { $0.minutes == 60 })
        XCTAssertEqual(buckets[9].tokens, 100, "09:05+09:25 归并到 9 点桶")
        XCTAssertEqual(buckets[10].tokens, 100)
        XCTAssertEqual(buckets[14].tokens, 0, "未来小时为 0")
    }

    func testReaggregateThreeHoursProducesCompleteFifteenMinWindow() {
        // 窗口 = [align(14:07−3h)=11:00, align(14:07)+15m=14:15)，13 桶完整覆盖
        let base = [
            TimeBucket(start: date("2026-09-01T11:30:00"), minutes: 5, tokens: 60, isPeak: false),
            TimeBucket(start: date("2026-09-01T11:40:00"), minutes: 5, tokens: 40, isPeak: false),
            TimeBucket(start: date("2026-09-01T14:00:00"), minutes: 5, tokens: 100, isPeak: false),
            TimeBucket(start: date("2026-09-01T10:55:00"), minutes: 5, tokens: 999, isPeak: false),
        ]
        let buckets = UsageBucketAggregator.reaggregate(base, to: .threeHours, now: now)
        XCTAssertEqual(buckets.count, 13, "完整覆盖 3h（首桶含 now−3h、末桶进行中）")
        XCTAssertTrue(buckets.allSatisfy { $0.minutes == 15 })
        XCTAssertEqual(buckets.first?.start, date("2026-09-01T11:00:00"))
        XCTAssertEqual(buckets.last?.start, date("2026-09-01T14:00:00"))
        let byStart = Dictionary(uniqueKeysWithValues: buckets.map { ($0.start, $0.tokens) })
        XCTAssertEqual(byStart[date("2026-09-01T11:30:00")], 100, "11:30+11:40 归并到 11:30 桶（10:55 窗口外丢弃）")
        XCTAssertEqual(byStart[date("2026-09-01T14:00:00")], 100, "当前进行中桶")
    }

    func testReaggregateOneHourPassesThroughFiveMinuteBuckets() {
        // 窗口 = [align(14:07−1h)=13:05, 14:10)，13 桶
        let base = [
            TimeBucket(start: date("2026-09-01T13:07:00"), minutes: 5, tokens: 100, isPeak: false),
            TimeBucket(start: date("2026-09-01T13:05:00"), minutes: 5, tokens: 40, isPeak: false),
            TimeBucket(start: date("2026-09-01T14:30:00"), minutes: 5, tokens: 999, isPeak: false),
        ]
        let buckets = UsageBucketAggregator.reaggregate(base, to: .oneHour, now: now)
        XCTAssertEqual(buckets.count, 13, "完整覆盖 1h（首桶含 now−1h、末桶进行中）")
        let byStart = Dictionary(uniqueKeysWithValues: buckets.map { ($0.start, $0.tokens) })
        XCTAssertEqual(byStart[date("2026-09-01T13:05:00")], 140, "13:05 与 13:07 同桶求和；14:30 窗口外丢弃")
        XCTAssertEqual(buckets.first?.start, date("2026-09-01T13:05:00"))
        XCTAssertEqual(buckets.last?.start, date("2026-09-01T14:05:00"))
    }

    func testReaggregateCrossDayThreeHourWindow() {
        // now = 凌晨 00:07，窗口 = [align(21:07)=21:00, 00:15)，跨到昨天
        let lateNight = date("2026-09-02T00:07:00")
        let base = [
            TimeBucket(start: date("2026-09-01T22:33:00"), minutes: 5, tokens: 100, isPeak: false),
        ]
        let buckets = UsageBucketAggregator.reaggregate(base, to: .threeHours, now: lateNight)
        XCTAssertEqual(buckets.first?.start, date("2026-09-01T21:00:00"))
        XCTAssertEqual(buckets.first { $0.tokens == 100 }?.start, date("2026-09-01T22:30:00"))
    }
}
