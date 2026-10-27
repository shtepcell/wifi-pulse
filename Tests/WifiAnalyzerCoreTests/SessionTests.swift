import XCTest
@testable import WifiAnalyzerCore
final class SessionTests: XCTestCase {
    func testParsesOnlyIPv4GatewayAndRejectsMissingRoute() throws {
        let route = try RouteInfo.parse("gateway: 192.168.2.1\n interface: en0\n")
        XCTAssertEqual(route.gateway, "192.168.2.1")
        XCTAssertEqual(route.interface, "en0")
        XCTAssertThrowsError(try RouteInfo.parse("gateway: link#14\ninterface: en0"))
        XCTAssertThrowsError(try RouteInfo.parse("gateway: 999.1.1.1\ninterface: en0"))
    }
    func testRejectsUnsafeOrInvalidRecordingOptions() throws {
        XCTAssertEqual(try Options.parse([]).interval, 0.05)
        XCTAssertEqual(try Options.parse(["record", "--interval-ms", "100"]).interval, 0.1)
        for args in [["--interval-ms", "0"], ["--interval-ms", "nan"], ["--duration", "-1"], ["--gateway", "example.com"], ["--gateway", "8.8.8.8"], ["--interface", "-bad"], ["--typo"], ["report"]] {
            XCTAssertThrowsError(try Options.parse(args), "Accepted: \(args)")
        }
    }
    func testCounterResetDoesNotCreateNegativeRate() {
        var rates = ByteRate()
        XCTAssertNil(rates.update(bytes: 100, at: 0))
        XCTAssertEqual(rates.update(bytes: 300, at: 2), 100)
        XCTAssertNil(rates.update(bytes: 10, at: 3))
        XCTAssertEqual(rates.update(bytes: 110, at: 4), 100)
    }
    func testTruncatedTailRecoversButCorruptCompleteRecordFails() throws {
        let data = Data("{\"schemaVersion\":1,\"kind\":\"marker\",\"t\":2}\n{\"unfinished\"".utf8)
        XCTAssertEqual(try SessionIO.readEvents(data).count, 1)
        XCTAssertThrowsError(try SessionIO.readEvents(Data("garbage\n".utf8)))
        XCTAssertThrowsError(try SessionIO.readEvents(Data("{\"schemaVersion\":2}\n".utf8)))
    }
    func testEmbeddedJSONCannotTerminateScriptAndRoundTrips() throws {
        let original = "</script><script>alert('x')</script>\u{2028}&"
        let json = try SessionIO.safeJSON(["message": original])
        XCTAssertFalse(json.contains("<"))
        let decoded = try JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: String]
        XCTAssertEqual(decoded["message"], original)
    }
    func testParsesTimestampedRequestWithoutMistakingReplyForSend() {
        XCTAssertEqual(PingParser.sentSequence("16:49:35.473551 64 bytes to 192.168.2.1: icmp_seq=0"), 0)
        XCTAssertNil(PingParser.sentSequence("64 bytes from 192.168.2.1: icmp_seq=0 ttl=64 time=3 ms"))
    }
}
