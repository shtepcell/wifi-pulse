import XCTest
@testable import WifiAnalyzerCore
final class SubnetTests: XCTestCase {
    func testAcceptsOnlyOnLinkUnicastTargetOtherThanThisMac() {
        XCTAssertTrue(Subnet.containsRouter("192.168.2.1", address: "192.168.2.129", netmask: "255.255.255.0"))
        XCTAssertTrue(Subnet.containsRouter("192.168.3.1", address: "192.168.2.129", netmask: "255.255.254.0"))
        for target in ["10.0.0.1", "192.168.3.1", "192.168.2.0", "192.168.2.255", "192.168.2.129", "not-an-ip"] {
            XCTAssertFalse(Subnet.containsRouter(target, address: "192.168.2.129", netmask: "255.255.255.0"), target)
        }
    }
}
