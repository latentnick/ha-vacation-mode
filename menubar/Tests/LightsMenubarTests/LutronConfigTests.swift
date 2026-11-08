import XCTest
@testable import LightsMenubar

final class LutronConfigTests: XCTestCase {
    func testLutronConfigRoundTripsWithoutChangingScheduleIDs() throws {
        var config = AppConfig()
        config.entities = ["switch.office_main_lights"]
        config.lutron = .init(host: "hub.local", zones: ["switch.office_main_lights": "/zone/2"])
        let decoded = try JSONDecoder().decode(AppConfig.self, from: JSONEncoder().encode(config))
        XCTAssertEqual(decoded, config)
        XCTAssertEqual(try decoded.lutron?.zone(for: config.entities[0]), "/zone/2")
    }

    func testMappingsFailClosedForUnknownMalformedOrDuplicateTargets() throws {
        let config = AppConfig.Lutron(host: "hub.local", zones: ["a": "/zone/2", "b": "/zone/2", "c": "/zone/2/commandprocessor"])
        XCTAssertThrowsError(try config.zone(for: "unknown"))
        XCTAssertThrowsError(try config.zone(for: "c"))
        XCTAssertThrowsError(try config.validate(entities: ["a", "b"]))
        XCTAssertNoThrow(try config.validate(entities: ["a"]))
    }
}
