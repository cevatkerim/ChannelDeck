import Darwin
import Foundation

struct LANIPv4Candidate: Equatable, Sendable {
    let interfaceName: String
    let address: String
}

enum LANAddressResolverError: Error, Equatable, LocalizedError {
    case noPrivateIPv4Address
    case interfaceEnumerationFailed

    var errorDescription: String? {
        switch self {
        case .noPrivateIPv4Address:
            "No active private IPv4 address was found. Connect this Mac to the same LAN as the AirPlay receiver."
        case .interfaceEnumerationFailed:
            "ChannelDeck could not inspect this Mac's network interfaces."
        }
    }
}

protocol LANAddressResolving: Sendable {
    func privateIPv4Address() throws -> String
}

struct SystemLANAddressResolver: LANAddressResolving {
    func privateIPv4Address() throws -> String {
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0, let firstInterface = interfaces else {
            throw LANAddressResolverError.interfaceEnumerationFailed
        }
        defer { freeifaddrs(interfaces) }

        var candidates: [LANIPv4Candidate] = []
        var current: UnsafeMutablePointer<ifaddrs>? = firstInterface
        while let interface = current {
            defer { current = interface.pointee.ifa_next }
            guard let socketAddress = interface.pointee.ifa_addr,
                  socketAddress.pointee.sa_family == UInt8(AF_INET) else { continue }

            let flags = Int32(interface.pointee.ifa_flags)
            guard flags & IFF_UP != 0,
                  flags & IFF_RUNNING != 0,
                  flags & IFF_LOOPBACK == 0 else { continue }

            var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let result = getnameinfo(
                socketAddress,
                socklen_t(socketAddress.pointee.sa_len),
                &hostname,
                socklen_t(hostname.count),
                nil,
                0,
                NI_NUMERICHOST
            )
            guard result == 0 else { continue }

            let address = String(cString: hostname)
            let name = String(cString: interface.pointee.ifa_name)
            candidates.append(LANIPv4Candidate(interfaceName: name, address: address))
        }

        guard let selected = LANAddressSelection.select(from: candidates) else {
            throw LANAddressResolverError.noPrivateIPv4Address
        }
        return selected.address
    }
}

enum LANAddressSelection {
    static func select(from candidates: [LANIPv4Candidate]) -> LANIPv4Candidate? {
        candidates
            .filter { isPrivateIPv4($0.address) && !isVirtualInterface($0.interfaceName) }
            .sorted { lhs, rhs in
                let lhsRank = interfaceRank(lhs.interfaceName)
                let rhsRank = interfaceRank(rhs.interfaceName)
                if lhsRank != rhsRank { return lhsRank < rhsRank }
                if lhs.interfaceName != rhs.interfaceName {
                    return lhs.interfaceName.localizedStandardCompare(rhs.interfaceName) == .orderedAscending
                }
                return lhs.address < rhs.address
            }
            .first
    }

    static func isPrivateIPv4(_ value: String) -> Bool {
        let octets = value.split(separator: ".").compactMap { UInt8($0) }
        guard octets.count == 4 else { return false }
        switch (octets[0], octets[1]) {
        case (10, _), (192, 168):
            return true
        case (172, 16...31):
            return true
        default:
            return false
        }
    }

    private static func interfaceRank(_ name: String) -> Int {
        if name == "en0" { return 0 }
        if name == "en1" { return 1 }
        if name.hasPrefix("en") { return 2 }
        return 3
    }

    private static func isVirtualInterface(_ name: String) -> Bool {
        ["utun", "awdl", "llw", "bridge", "vmenet", "vmnet", "gif", "stf"]
            .contains { name.hasPrefix($0) }
    }
}
