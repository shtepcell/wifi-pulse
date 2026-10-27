import Foundation
import CoreWLAN
import Darwin

final class MetricsSampler {
    private let interface: String
    private let wifi: CWInterface
    private var rx = ByteRate(), tx = ByteRate()
    init(interface: String) throws {
        self.interface = interface
        guard let wifi = CWWiFiClient.shared().interface(withName: interface) else {
            throw AnalyzerError("\(interface) is not an available Wi-Fi interface. If a VPN owns the default route, pass --interface en0 --gateway YOUR_LOCAL_ROUTER.")
        }
        self.wifi = wifi
    }
    func sample(at time: Double) -> [String: Any] {
        var values: [String: Any] = ["interface": interface]
        var issues: [String] = []
        let power = wifi.powerOn(), signal = wifi.rssiValue(), noise = wifi.noiseMeasurement()
        let rate = wifi.transmitRate(), channel = wifi.wlanChannel()
        values["wifiPowerOn"] = power
        values["rssiDBm"] = power && signal < 0 ? signal as Any : NSNull()
        values["noiseDBm"] = power && noise < 0 ? noise as Any : NSNull()
        values["linkMbps"] = power && rate > 0 && rate.isFinite ? rate as Any : NSNull()
        values["channel"] = channel.map { $0.channelNumber as Any } ?? NSNull()
        if let channel = channel {
            values["band"] = [1: "2.4 GHz", 2: "5 GHz", 3: "6 GHz"][channel.channelBand.rawValue] ?? "unknown"
            values["channelWidthMHz"] = [1: 20, 2: 40, 3: 80, 4: 160][channel.channelWidth.rawValue].map { $0 as Any } ?? NSNull()
        }
        if !power { issues.append("Wi-Fi is off") }
        if signal >= 0 { issues.append("RSSI unavailable: disconnected or macOS denied access") }
        if noise >= 0 { issues.append("Noise measurement unavailable") }
        var addresses: UnsafeMutablePointer<ifaddrs>?
        if getifaddrs(&addresses) == 0, let first = addresses {
            defer { freeifaddrs(addresses) }
            var cursor: UnsafeMutablePointer<ifaddrs>? = first
            var foundCounters = false, foundAWDL = false
            while let pointer = cursor {
                let item = pointer.pointee
                defer { cursor = item.ifa_next }
                guard let namePointer = item.ifa_name else { continue }
                let name = String(cString: namePointer)
                if name == "awdl0" {
                    values["awdlUp"] = (item.ifa_flags & UInt32(IFF_UP)) != 0
                    foundAWDL = true
                }
                if name == interface, item.ifa_addr?.pointee.sa_family == UInt8(AF_LINK), let raw = item.ifa_data {
                    let data = raw.assumingMemoryBound(to: if_data.self).pointee
                    let received = UInt64(data.ifi_ibytes), transmitted = UInt64(data.ifi_obytes)
                    values["rxBytes"] = received; values["txBytes"] = transmitted
                    values["rxBytesPerSecond"] = rx.update(bytes: received, at: time).map { $0 as Any } ?? NSNull()
                    values["txBytesPerSecond"] = tx.update(bytes: transmitted, at: time).map { $0 as Any } ?? NSNull()
                    foundCounters = true
                }
            }
            if !foundAWDL { values["awdlUp"] = NSNull(); issues.append("AWDL interface unavailable") }
            if !foundCounters { issues.append("Network byte counters unavailable") }
        } else { issues.append("Cannot read interface counters or AWDL state") }
        values["issues"] = issues
        return values
    }
}
