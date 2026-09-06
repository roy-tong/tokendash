import XCTest
@testable import TokenDash

final class SettingsStoreHourlyRangeTests: XCTestCase {
    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: "settings.hourlyRange")
    }

    func testDefaultRangeIsOneDay() {
        XCTAssertEqual(SettingsStore.shared.hourlyRange, .oneDay, "升级用户默认保持 1D 视图")
    }

    func testRawValueRoundTrip() {
        XCTAssertEqual(SettingsStore.HourlyRange(rawValue: "threeHours"), .threeHours)
        XCTAssertEqual(SettingsStore.HourlyRange(rawValue: "fifteenMinutes"), .fifteenMinutes)
        XCTAssertNil(SettingsStore.HourlyRange(rawValue: "bogus"), "损坏的持久化值应返回 nil 走默认")
    }

    func testLegacyRawValuesMigrate() {
        XCTAssertEqual(SettingsStore.HourlyRange.migrate("today"), .oneDay)
        XCTAssertEqual(SettingsStore.HourlyRange.migrate("oneHour"), .fifteenMinutes, "旧 1H 档偏好迁移到新的实时 15M 档")
        XCTAssertEqual(SettingsStore.HourlyRange.migrate("fifteenMinutes"), .fifteenMinutes)
        XCTAssertNil(SettingsStore.HourlyRange.migrate("bogus"))
    }

    func testBucketMinutes() {
        XCTAssertEqual(SettingsStore.HourlyRange.oneDay.bucketMinutes, 60)
        XCTAssertEqual(SettingsStore.HourlyRange.threeHours.bucketMinutes, 15)
        XCTAssertEqual(SettingsStore.HourlyRange.fifteenMinutes.bucketMinutes, 1)
    }

    func testLabels() {
        XCTAssertEqual(SettingsStore.HourlyRange.fifteenMinutes.label, "Last 15 Minutes")
        XCTAssertEqual(SettingsStore.HourlyRange.threeHours.shortLabel, "3H")
        XCTAssertEqual(SettingsStore.HourlyRange.oneDay.shortLabel, "1D")
        XCTAssertEqual(SettingsStore.HourlyRange.fifteenMinutes.shortLabel, "15M")
    }
}
