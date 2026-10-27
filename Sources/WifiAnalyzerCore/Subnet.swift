import Foundation
import Darwin

public enum Subnet {
    private static func number(_ address: String) -> UInt32? {
        guard RouteInfo.isIPv4(address) else { return nil }
        return address.split(separator: ".").reduce(UInt32(0)) { ($0 << 8) | UInt32($1)! }
    }
    public static func containsRouter(_ gateway: String, address: String, netmask: String) -> Bool {
        guard let target = number(gateway), let local = number(address), let mask = number(netmask), mask != 0, target != local,
              target & mask == local & mask else { return false }
        let hosts = ~mask
        guard hosts & (hosts &+ 1) == 0 else { return false } // Contiguous subnet mask.
        if hosts <= 1 { return true } // /31 point-to-point networks have no broadcast address.
        return target & hosts != 0 && target & hosts != hosts
    }
    static func requireOnLink(_ gateway: String, interface: String) throws {
        var addresses: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addresses) == 0 else { throw AnalyzerError("Cannot validate local Wi-Fi subnet") }
        defer { freeifaddrs(addresses) }
        var cursor = addresses
        while let pointer = cursor {
            let item = pointer.pointee
            defer { cursor = item.ifa_next }
            guard String(cString: item.ifa_name) == interface,
                  let address = item.ifa_addr, let mask = item.ifa_netmask,
                  address.pointee.sa_family == UInt8(AF_INET) else { continue }
            let local = UnsafeRawPointer(address).assumingMemoryBound(to: sockaddr_in.self).pointee
            let netmask = UnsafeRawPointer(mask).assumingMemoryBound(to: sockaddr_in.self).pointee
            var ip = local.sin_addr, subnetMask = netmask.sin_addr
            var ipText = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            var maskText = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            guard inet_ntop(AF_INET, &ip, &ipText, socklen_t(INET_ADDRSTRLEN)) != nil,
                  inet_ntop(AF_INET, &subnetMask, &maskText, socklen_t(INET_ADDRSTRLEN)) != nil else { continue }
            if containsRouter(gateway, address: String(cString: ipText), netmask: String(cString: maskText)) { return }
        }
        throw AnalyzerError("\(gateway) is not an on-link unicast target on \(interface). Use the router address from this Wi-Fi network.")
    }
}
