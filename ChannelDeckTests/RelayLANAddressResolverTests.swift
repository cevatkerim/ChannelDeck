import XCTest
@testable import ChannelDeck

final class RelayLANAddressResolverTests: XCTestCase {
    func testSelectsPrimaryEthernetOrWiFiPrivateAddress() {
        let selected = LANAddressSelection.select(from: [
            LANIPv4Candidate(interfaceName: "en4", address: "10.0.0.40"),
            LANIPv4Candidate(interfaceName: "en0", address: "192.168.1.50"),
            LANIPv4Candidate(interfaceName: "utun2", address: "10.8.0.2"),
        ])

        XCTAssertEqual(selected, LANIPv4Candidate(interfaceName: "en0", address: "192.168.1.50"))
    }

    func testRejectsPublicLoopbackLinkLocalAndVirtualAddresses() {
        let selected = LANAddressSelection.select(from: [
            LANIPv4Candidate(interfaceName: "en0", address: "203.0.113.5"),
            LANIPv4Candidate(interfaceName: "lo0", address: "127.0.0.1"),
            LANIPv4Candidate(interfaceName: "en1", address: "169.254.1.9"),
            LANIPv4Candidate(interfaceName: "utun1", address: "10.0.0.2"),
        ])

        XCTAssertNil(selected)
    }

    func testRecognizesAllRFC1918Ranges() {
        XCTAssertTrue(LANAddressSelection.isPrivateIPv4("10.255.0.1"))
        XCTAssertTrue(LANAddressSelection.isPrivateIPv4("172.16.0.1"))
        XCTAssertTrue(LANAddressSelection.isPrivateIPv4("172.31.255.254"))
        XCTAssertTrue(LANAddressSelection.isPrivateIPv4("192.168.0.1"))
        XCTAssertFalse(LANAddressSelection.isPrivateIPv4("172.32.0.1"))
        XCTAssertFalse(LANAddressSelection.isPrivateIPv4("192.167.1.1"))
        XCTAssertFalse(LANAddressSelection.isPrivateIPv4("not-an-address"))
    }
}
