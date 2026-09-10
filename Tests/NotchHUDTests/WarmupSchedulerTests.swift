import XCTest
@testable import NotchHUD

final class WarmupSchedulerTests: XCTestCase {
    private var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Colombo")!
        return c
    }()

    private func date(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int) -> Date {
        cal.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
    }

    func testSlotIsDueFromItsTimeUntilTheGraceEnds() {
        // Thursday 2026-09-10.
        XCTAssertEqual(WarmupScheduler.dueSlots(times: ["07:00"], weekdaysOnly: true, graceMinutes: 120,
                                                now: date(2026, 9, 10, 6, 59), calendar: cal), [])
        XCTAssertEqual(WarmupScheduler.dueSlots(times: ["07:00"], weekdaysOnly: true, graceMinutes: 120,
                                                now: date(2026, 9, 10, 7, 0), calendar: cal), ["2026-09-10 07:00"])
        XCTAssertEqual(WarmupScheduler.dueSlots(times: ["07:00"], weekdaysOnly: true, graceMinutes: 120,
                                                now: date(2026, 9, 10, 8, 40), calendar: cal), ["2026-09-10 07:00"], "asleep at 07:00, awake at 08:40: still worth it")
        XCTAssertEqual(WarmupScheduler.dueSlots(times: ["07:00"], weekdaysOnly: true, graceMinutes: 120,
                                                now: date(2026, 9, 10, 9, 1), calendar: cal), [], "too late; the day has started anyway")
    }

    func testWeekendsSkippedOnlyWhenAsked() {
        let saturday = date(2026, 9, 12, 7, 30)
        XCTAssertEqual(WarmupScheduler.dueSlots(times: ["07:00"], weekdaysOnly: true, graceMinutes: 120, now: saturday, calendar: cal), [])
        XCTAssertEqual(WarmupScheduler.dueSlots(times: ["07:00"], weekdaysOnly: false, graceMinutes: 120, now: saturday, calendar: cal), ["2026-09-12 07:00"])
    }

    func testSeveralTimesAndBadEntries() {
        let due = WarmupScheduler.dueSlots(times: ["07:00", "12:00", "nope", "25:00"], weekdaysOnly: true, graceMinutes: 120,
                                           now: date(2026, 9, 10, 12, 30), calendar: cal)
        XCTAssertEqual(due, ["2026-09-10 12:00"])
        XCTAssertNil(WarmupScheduler.parseTime("7"))
        let parsed = WarmupScheduler.parseTime("07:05")
        XCTAssertEqual(parsed?.0, 7)
        XCTAssertEqual(parsed?.1, 5)
    }

    func testScheduleRoundTripsAndDefaults() throws {
        var cfg = HUDConfig()
        cfg.warmup.enabled = true
        cfg.warmup.times = ["06:45", "12:00"]
        cfg.warmup.weekdaysOnly = false
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("config.json")
        try cfg.save(to: url)
        XCTAssertEqual(HUDConfig.load(from: url).warmup, cfg.warmup)

        let parsed = HUDConfig.parseV2(["subscriptions": [], "warmup": ["enabled": true, "times": ["07:00", "junk"], "graceMinutes": 9999]])
        XCTAssertTrue(parsed.warmup.enabled)
        XCTAssertEqual(parsed.warmup.times, ["07:00"], "unparseable times are dropped")
        XCTAssertEqual(parsed.warmup.graceMinutes, 120, "absurd grace falls back")
        XCTAssertEqual(HUDConfig.parseV2(["subscriptions": []]).warmup, WarmupSchedule(), "off by default")
    }
}
