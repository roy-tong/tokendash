import XCTest
@testable import TokenDash

@MainActor
final class BadgeUpdaterModeTests: XCTestCase {

    // MARK: - dormant: badge 更新只拉 daily，不拉 blocks/projects/quota

    func testDormantPerformBadgeUpdateSkipsBlocksProjectsQuota() async throws {
        let state = AppState()
        let mock = MockAPIClient()
        let updater = BadgeUpdater(state: state, client: mock)

        await updater.performBadgeUpdate()

        let counts = await mock.snapshot()
        XCTAssertGreaterThan(counts.daily, 0, "dormant badge 更新必须拉 daily")
        XCTAssertEqual(counts.blocks, 0, "dormant 不得拉 blocks")
        XCTAssertEqual(counts.projects, 0, "dormant 不得拉 projects")
        XCTAssertEqual(counts.quota, 0, "dormant 不得拉 quota")
    }

    // MARK: - active: 打开瞬间全量拉详情，但 quota 走缓存（refresh=false）

    func testActivePerformFullUpdateFetchesDetailsButCachesQuota() async throws {
        let state = AppState()
        let mock = MockAPIClient()
        let updater = BadgeUpdater(state: state, client: mock)

        await updater.performFullUpdate(forceRefresh: true, forceQuota: false)
        // Detail state paints synchronously; quota refreshes async — give the
        // detached quota task a moment to run before asserting on it.
        try await Task.sleep(nanoseconds: 200_000_000)  // 0.2s

        let counts = await mock.snapshot()
        XCTAssertGreaterThan(counts.daily, 0)
        XCTAssertGreaterThan(counts.blocks, 0)
        XCTAssertGreaterThan(counts.projects, 0)
        XCTAssertGreaterThan(counts.quota, 0, "active 详情刷新最终要拉 quota（异步）")
        let lastQuotaRefresh = await mock.lastQuotaRefresh
        XCTAssertEqual(lastQuotaRefresh, false, "非手动刷新时 quota 必须走缓存")
    }

    // MARK: - 手动刷新：quota 强刷

    func testManualRefreshForceRefreshesQuota() async throws {
        let state = AppState()
        let mock = MockAPIClient()
        let updater = BadgeUpdater(state: state, client: mock)

        await updater.performFullUpdate(forceRefresh: true, forceQuota: true)

        let lastQuotaRefresh = await mock.lastQuotaRefresh
        XCTAssertEqual(lastQuotaRefresh, true, "手动刷新必须强刷 quota")
        XCTAssertNotNil(state.lastUpdatedAt, "手动刷新完成后必须记录最近刷新时间")
        XCTAssertFalse(state.isRefreshing, "手动刷新完成后必须退出 loading 状态")
    }

    func testManualRefreshShowsLatestCodingPlanFailureInsteadOfKeepingOldProgress() async throws {
        let state = AppState()
        state.quotas = [makeQuotaSnapshot(usedPercent: 9)]
        let unavailable = makeQuotaSnapshot(
            usedPercent: nil,
            freshness: "stale",
            status: QuotaProviderStatus(
                state: "upstream_unavailable",
                message: "Codex unavailable",
                category: nil
            )
        )
        let mock = MockAPIClient(quotaResponse: QuotaResponse(providers: [unavailable]))
        let updater = BadgeUpdater(state: state, client: mock)

        updater.refreshNow()
        try await waitUntil { await mock.snapshot().quota > 0 }
        try await waitUntil { !state.isRefreshing }

        XCTAssertEqual(state.quotas.first?.status.state, "upstream_unavailable")
        XCTAssertTrue(state.quotas.first?.windows.isEmpty == true)
    }

    func testManualRefreshShowsTransportFailureInsteadOfKeepingOldProgress() async throws {
        let state = AppState()
        state.quotas = [makeQuotaSnapshot(usedPercent: 9)]
        let mock = FailingQuotaAPIClient()
        let updater = BadgeUpdater(state: state, client: mock)

        updater.refreshNow()
        try await waitUntil { await mock.quotaCallCount > 0 }
        try await waitUntil { !state.isRefreshing }

        XCTAssertEqual(state.quotas.first?.status.state, "upstream_unavailable")
        XCTAssertTrue(state.quotas.first?.windows.isEmpty == true)
    }

    func testCacheServedLaunchPrimeDoesNotThrottleFirstPopoverRefresh() async throws {
        let state = AppState()
        let mock = MockAPIClient()
        var now = Date(timeIntervalSinceReferenceDate: 1_000)
        let updater = BadgeUpdater(
            state: state,
            client: mock,
            now: { now },
            popoverRefreshInterval: 30 * 60
        )

        await updater.performFullUpdate(forceRefresh: false, forceQuota: false)
        let launchCounts = await mock.snapshot()
        let launchDailyRefresh = await mock.lastDailyRefresh
        XCTAssertEqual(launchDailyRefresh, false, "launch warm-up must stay cache-served")
        XCTAssertNil(state.lastUpdatedAt, "cache-served launch warm-up must not start the popover fresh-data throttle")

        now.addTimeInterval(60)
        let refreshedOnOpen = await updater.refreshOnPopoverOpenIfNeeded()

        XCTAssertTrue(refreshedOnOpen, "the first popover open after launch must still bypass stale daemon caches")
        let openedCounts = await mock.snapshot()
        XCTAssertGreaterThan(openedCounts.daily, launchCounts.daily)
        XCTAssertGreaterThan(openedCounts.blocks, launchCounts.blocks)
        XCTAssertGreaterThan(openedCounts.projects, launchCounts.projects)
        let openDailyRefresh = await mock.lastDailyRefresh
        XCTAssertEqual(openDailyRefresh, true, "popover open must force a fresh detail refresh after cache-served launch warm-up")
        XCTAssertNotNil(state.lastUpdatedAt, "fresh popover refresh should record the throttle timestamp")
    }

    func testPopoverOpenDuringLaunchWarmupQueuesFreshRefresh() async throws {
        let state = AppState()
        let mock = BlockingAPIClient()
        let updater = BadgeUpdater(
            state: state,
            client: mock,
            popoverRefreshInterval: 30 * 60
        )

        let launchTask = Task { await updater.performFullUpdate(forceRefresh: false, forceQuota: false) }
        await mock.waitUntilFirstDailyIsBlocked()
        updater.setMode(.active)

        let refreshedImmediately = await updater.refreshOnPopoverOpenIfNeeded()
        XCTAssertFalse(refreshedImmediately, "an in-flight launch warm-up cannot be interrupted synchronously")

        await mock.releaseFirstDaily()
        await launchTask.value
        try await waitUntil {
            await mock.dailyCallCount >= 2 && state.lastUpdatedAt != nil
        }

        let lastDailyRefresh = await mock.lastDailyRefresh
        XCTAssertEqual(lastDailyRefresh, true, "active popover open during cache-served launch warm-up must queue a fresh refresh")
        XCTAssertNotNil(state.lastUpdatedAt, "queued fresh refresh should record the throttle timestamp")
    }

    func testPopoverRefreshIsThrottledForThirtyMinutes() async throws {
        let state = AppState()
        let mock = MockAPIClient()
        var now = Date(timeIntervalSinceReferenceDate: 1_000)
        let updater = BadgeUpdater(
            state: state,
            client: mock,
            now: { now },
            popoverRefreshInterval: 30 * 60
        )

        let refreshedInitially = await updater.refreshOnPopoverOpenIfNeeded()
        XCTAssertTrue(refreshedInitially)
        let firstCounts = await mock.snapshot()
        XCTAssertGreaterThan(firstCounts.daily, 0)
        let firstDailyRefresh = await mock.lastDailyRefresh
        XCTAssertEqual(firstDailyRefresh, true)

        now.addTimeInterval(29 * 60 + 59)
        let refreshedBeforeInterval = await updater.refreshOnPopoverOpenIfNeeded()
        XCTAssertFalse(refreshedBeforeInterval)
        let throttledCounts = await mock.snapshot()
        XCTAssertEqual(throttledCounts.daily, firstCounts.daily)

        now.addTimeInterval(2)
        let refreshedAfterInterval = await updater.refreshOnPopoverOpenIfNeeded()
        XCTAssertTrue(refreshedAfterInterval)
        let finalCounts = await mock.snapshot()
        XCTAssertGreaterThan(finalCounts.daily, firstCounts.daily)
    }

    func testBackgroundRefreshForceRefreshesDetailsAndQuota() async throws {
        let state = AppState()
        let mock = MockAPIClient()
        let updater = BadgeUpdater(state: state, client: mock)

        await updater.performBackgroundRefresh()

        let lastDailyRefresh = await mock.lastDailyRefresh
        let lastQuotaRefresh = await mock.lastQuotaRefresh
        XCTAssertEqual(lastDailyRefresh, true, "每小时后台刷新必须绕过详情缓存")
        XCTAssertEqual(lastQuotaRefresh, true, "每小时后台刷新必须绕过 quota 缓存")
        XCTAssertNotNil(state.lastUpdatedAt)
        XCTAssertFalse(state.isRefreshing)
    }

    func testPopoverOpenAutoRefreshUsesMostRecentFullRefreshTime() async throws {
        let state = AppState()
        let mock = MockAPIClient()
        var now = Date(timeIntervalSinceReferenceDate: 1_000)
        let updater = BadgeUpdater(
            state: state,
            client: mock,
            now: { now },
            popoverRefreshInterval: 30 * 60
        )

        await updater.performBackgroundRefresh()
        let backgroundCounts = await mock.snapshot()
        XCTAssertNotNil(state.lastUpdatedAt)

        now.addTimeInterval(10 * 60)
        let refreshedOnOpen = await updater.refreshOnPopoverOpenIfNeeded()

        XCTAssertFalse(refreshedOnOpen, "打开菜单栏的自动刷新必须把最近一次后台/手动全量刷新也算进同一个节流周期")
        let openedCounts = await mock.snapshot()
        XCTAssertEqual(openedCounts.daily, backgroundCounts.daily)
        XCTAssertEqual(openedCounts.blocks, backgroundCounts.blocks)
        XCTAssertEqual(openedCounts.projects, backgroundCounts.projects)
    }

    func testRefreshIntervalSettingsExposeDetailRefreshCadences() {
        XCTAssertEqual(
            SettingsStore.RefreshInterval.allCases.map(\.rawValue),
            [10 * 60, 30 * 60, 60 * 60].map(Double.init)
        )
        XCTAssertEqual(SettingsStore.RefreshInterval.oneHour.label, "1 hour (Low Power)")
        XCTAssertNil(SettingsStore.RefreshInterval(rawValue: 30), "legacy badge cadence should fall back to the one-hour default")
    }
}

/// 计数型 mock — 记录每个端点被调用的次数与关键参数，供模式断言。
actor MockAPIClient: APIClientProtocol {
    private let quotaResponse: QuotaResponse
    private(set) var agents = 0
    private(set) var daily = 0
    private(set) var blocks = 0
    private(set) var projects = 0
    private(set) var quota = 0
    private(set) var lastQuotaRefresh: Bool? = nil
    private(set) var lastDailyRefresh: Bool? = nil
    private(set) var lastBlocksGranularity: BlocksGranularity? = nil

    struct Snapshot {
        let agents: Int; let daily: Int; let blocks: Int
        let projects: Int; let quota: Int
    }

    init(quotaResponse: QuotaResponse = QuotaResponse(providers: [])) {
        self.quotaResponse = quotaResponse
    }

    func snapshot() -> Snapshot {
        Snapshot(agents: agents, daily: daily, blocks: blocks, projects: projects, quota: quota)
    }

    func getAgents() async throws -> AgentsResponse {
        agents += 1
        return AgentsResponse(available: ["claude"], default: "claude")
    }
    func getDaily(agent: String, refresh: Bool) async throws -> DailyResponse {
        daily += 1
        lastDailyRefresh = refresh
        return DailyResponse(daily: [])
    }
    func getBlocks(agent: String, refresh: Bool, granularity: BlocksGranularity = .hour) async throws -> BlocksResponse {
        blocks += 1
        lastBlocksGranularity = granularity
        return BlocksResponse(blocks: [])
    }
    func getProjects(agent: String, refresh: Bool) async throws -> ProjectsResponse {
        projects += 1
        return ProjectsResponse(projects: [:])
    }
    func getQuota(refresh: Bool) async throws -> QuotaResponse {
        quota += 1
        lastQuotaRefresh = refresh
        return quotaResponse
    }
}

private func makeQuotaSnapshot(
    usedPercent: Double?,
    freshness: String = "live",
    status: QuotaProviderStatus = QuotaProviderStatus(state: "ok", message: nil, category: nil)
) -> QuotaSnapshot {
    let windows: [QuotaWindow]
    if let usedPercent {
        windows = [QuotaWindow(
            id: "codex_weekly",
            label: "Codex · Weekly",
            usedPercent: usedPercent,
            remainingPercent: 100 - usedPercent,
            used: nil,
            limit: nil,
            durationMins: 10_080,
            resetsAt: nil,
            isUnlimited: nil,
            modelName: nil
        )]
    } else {
        windows = []
    }
    return QuotaSnapshot(
        provider: "codex",
        displayName: "OpenAI Codex",
        planName: "Plus",
        fetchedAt: "2026-08-03T00:00:00.000Z",
        freshness: freshness,
        windows: windows,
        status: status
    )
}

private func waitUntil(
    timeoutNanoseconds: UInt64 = 1_000_000_000,
    condition: @escaping () async -> Bool
) async throws {
    let start = DispatchTime.now().uptimeNanoseconds
    while DispatchTime.now().uptimeNanoseconds - start < timeoutNanoseconds {
        if await condition() { return }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    XCTFail("Timed out waiting for async condition")
}

actor BlockingAPIClient: APIClientProtocol {
    private(set) var dailyCallCount = 0
    private(set) var lastDailyRefresh: Bool? = nil
    private var shouldBlockFirstDaily = true
    private var firstDailyContinuation: CheckedContinuation<Void, Never>?
    private var blockedWaiters: [CheckedContinuation<Void, Never>] = []

    func waitUntilFirstDailyIsBlocked() async {
        if firstDailyContinuation != nil { return }
        await withCheckedContinuation { continuation in
            blockedWaiters.append(continuation)
        }
    }

    func releaseFirstDaily() {
        firstDailyContinuation?.resume()
        firstDailyContinuation = nil
    }

    func getAgents() async throws -> AgentsResponse {
        AgentsResponse(available: ["claude"], default: "claude")
    }

    func getDaily(agent: String, refresh: Bool) async throws -> DailyResponse {
        dailyCallCount += 1
        lastDailyRefresh = refresh
        if shouldBlockFirstDaily {
            shouldBlockFirstDaily = false
            await withCheckedContinuation { continuation in
                firstDailyContinuation = continuation
                let waiters = blockedWaiters
                blockedWaiters.removeAll()
                waiters.forEach { $0.resume() }
            }
        }
        return DailyResponse(daily: [])
    }

    func getBlocks(agent: String, refresh: Bool, granularity: BlocksGranularity = .hour) async throws -> BlocksResponse {
        BlocksResponse(blocks: [])
    }

    func getProjects(agent: String, refresh: Bool) async throws -> ProjectsResponse {
        ProjectsResponse(projects: [:])
    }

    func getQuota(refresh: Bool) async throws -> QuotaResponse {
        QuotaResponse(providers: [])
    }
}

actor FailingQuotaAPIClient: APIClientProtocol {
    private(set) var quotaCallCount = 0

    func getAgents() async throws -> AgentsResponse {
        AgentsResponse(available: ["claude"], default: "claude")
    }

    func getDaily(agent: String, refresh: Bool) async throws -> DailyResponse {
        DailyResponse(daily: [])
    }

    func getBlocks(agent: String, refresh: Bool, granularity: BlocksGranularity = .hour) async throws -> BlocksResponse {
        BlocksResponse(blocks: [])
    }

    func getProjects(agent: String, refresh: Bool) async throws -> ProjectsResponse {
        ProjectsResponse(projects: [:])
    }

    func getQuota(refresh: Bool) async throws -> QuotaResponse {
        quotaCallCount += 1
        throw APIClientError.httpError(500)
    }
}
