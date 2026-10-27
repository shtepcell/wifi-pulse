import Foundation

public enum Report {
    @discardableResult public static func generate(directory: URL) throws -> URL {
        let metadataData = try Data(contentsOf: directory.appendingPathComponent("metadata.json"))
        guard let metadata = try JSONSerialization.jsonObject(with: metadataData) as? [String: Any], metadata["schemaVersion"] as? Int == 1 else { throw AnalyzerError("Unsupported metadata schema") }
        let data = try Data(contentsOf: directory.appendingPathComponent("events.jsonl"))
        let events = try SessionIO.readEvents(data)
        guard let templateURL = Bundle.module.url(forResource: "report", withExtension: "html") else { throw AnalyzerError("Report template missing from resource bundle") }
        let template = try String(contentsOf: templateURL, encoding: .utf8)
        var warnings: [String] = []
        if data.last != 10, !data.isEmpty { warnings.append("The final event line has no newline; a truncated tail may have been ignored.") }
        if !events.contains(where: { $0["kind"] as? String == "end" }) { warnings.append("No end event: recording may have been interrupted. Unanswered probes without a timeout remain pending.") }
        let payload = try SessionIO.safeJSON(["metadata": metadata, "events": events, "warnings": warnings])
        let html = template.replacingOccurrences(of: "__SESSION_DATA__", with: payload)
        let report = directory.appendingPathComponent("report.html")
        try html.write(to: report, atomically: true, encoding: .utf8)
        return report
    }
    public static func demo(output: String?) throws -> URL {
        let directory = try SessionIO.newDirectory(output, prefix: "demo")
        let writer = try SessionWriter(directory: directory, metadata: [
            "schemaVersion": 1, "synthetic": true, "appVersion": "0.1.0", "gateway": "192.168.2.1", "interface": "en0",
            "startedUTC": ISO8601DateFormatter().string(from: Date()), "requestedIntervalMS": 50, "timeoutSeconds": 1,
            "note": "Synthetic demonstration. These are not measurements of your network."
        ])
        var records: [(Double, String, [String: Any])] = []
        for id in 0..<3600 {
            let time = Double(id) * 0.05
            records.append((time, "send", ["id": id, "sequence": id]))
            let spike = (60..<62).contains(time) || (120..<121).contains(time)
            let latency = spike ? 110 + 170 * abs(sin(time * 7)) : 2 + 3 * abs(sin(time * 2))
            if (60.4..<60.7).contains(time) {
                records.append((time + 1, "timeout", ["id": id, "sent": time]))
            } else {
                records.append((time + latency / 1000, "reply", ["id": id, "sent": time, "latencyMS": latency, "late": false]))
            }
        }
        for second in 0..<180 {
            let weak = (59...63).contains(second)
            let values: [String: Any] = ["rssiDBm": weak ? -78 : -52, "noiseDBm": -94,
                "linkMbps": weak ? 144 : 866, "channel": 44, "awdlUp": false,
                "rxBytesPerSecond": 5_000_000 + 500_000 * abs(sin(Double(second))),
                "txBytesPerSecond": (119...122).contains(second) ? 8_000_000 : 90_000, "issues": []]
            records.append((Double(second), "metrics", ["values": values]))
        }
        records.append((61.1, "marker", ["message": "Lag — example with weaker signal"]))
        records.append((120.6, "marker", ["message": "Lag — example with more outgoing traffic"]))
        records.append((180, "end", ["message": "Synthetic session complete"]))
        for (time, kind, fields) in records.sorted(by: { $0.0 < $1.0 }) { try writer.append(kind, at: time, fields: fields) }
        try writer.close()
        return try generate(directory: directory)
    }
}
