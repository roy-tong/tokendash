import XCTest
@testable import TokenDash

final class SettingsStoreHourlyRangeTests: XCTestCase {
    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: "settings.hourlyRange")
    }

    func testDefaultRangeIsToday() {
        XCTAssertEqual(SettingsStore.shared.hourlyRange, .today, "升级用户默认保持 Today 视图")
    }

    func testRawValueRoundTrip() {
        XCTAssertEqual(SettingsStore.HourlyRange(rawValue: "threeHours"), .threeHours)
        XCTAssertEqual(SettingsStore.HourlyRange(rawValue: "oneHour"), .oneHour)
        XCTAssertNil(SettingsStore.HourlyRange(rawValue: "bogus"), "损坏的持久化值应返回 nil 走默认")
    }

    func testBucketMinutes() {
        XCTAssertEqual(SettingsStore.HourlyRange.today.bucketMinutes, 60)
        XCTAssertEqual(SettingsStore.HourlyRange.threeHours.bucketMinutes, 15)
        XCTAssertEqual(SettingsStore.HourlyRange.oneHour.bucketMinutes, 5)
    }

    func testLabels() {
        XCTAssertEqual(SettingsStore.HourlyRange.threeHours.label, "Last 3 Hours")
        XCTAssertEqual(SettingsStore.HourlyRange.oneHour.shortLabel, "1H")
    }
}
