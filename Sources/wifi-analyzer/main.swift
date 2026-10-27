import Foundation
import Darwin
import WifiAnalyzerCore

let help = """
Wi-Fi Pulse 0.1.0 — local macOS Wi-Fi recording and offline reports

Usage:
  wifi-analyzer record [options]
  wifi-analyzer report SESSION_FOLDER
  wifi-analyzer demo [--output NEW_FOLDER]

Record options:
  --interval-ms N   Router ping interval, 10–10000 ms (default \(Int(Options.defaultInterval * 1000)))
  --duration N      Stop automatically after N seconds (optional)
  --gateway IP      Override router, local IPv4 only
  --interface NAME  Override Wi-Fi interface, e.g. en0
  --output PATH     New session folder (must not already exist)

While recording: Enter marks lag (optional text + Enter adds a label).
Ctrl+C saves all data and generates report.html. No sudo required.
Wi-Fi/AWDL/traffic sampled every second. No scans or internet probes.
Open report.html in a browser. No server or network access required.
"""
var activeRecorder: Recorder?
func reportError(_ error: Error) -> Never {
    FileHandle.standardError.write(Data("Error: \(error)\n".utf8))
    exit(1)
}
do {
    let options = try Options.parse(Array(CommandLine.arguments.dropFirst()))
    switch options.command {
    case "help": print(help)
    case "report":
        let report = try Report.generate(directory: URL(fileURLWithPath: options.session!, isDirectory: true))
        print("Report: \(report.path)")
    case "demo":
        let report = try Report.demo(output: options.output)
        print("SYNTHETIC DEMO — not a measurement of your network\nReport: \(report.path)")
    default:
        let recorder = try Recorder(options: options)
        activeRecorder = recorder
        try recorder.start { result in
            switch result {
            case .success: exit(0)
            case .failure(let error): reportError(error)
            }
        }
        dispatchMain()
    }
} catch { reportError(error) }
