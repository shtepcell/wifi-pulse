import Foundation
import Darwin

public final class Recorder {
    private let options: Options
    private let writer: SessionWriter
    private let sampler: MetricsSampler
    private let initialRoute: RouteInfo?
    private let gateway: String
    private let interface: String
    private let child = Process()
    private var tracker = PingTracker()
    private var timers: [DispatchSourceTimer] = []
    private var signals: [DispatchSourceSignal] = []
    private var stdinSource: DispatchSourceRead?
    private var inputBuffer = Data()
    private var master: FileHandle?
    private var stopping = false, finished = false, metricsBusy = false
    private var worker = DispatchQueue(label: "wifi-analyzer.metrics", qos: .utility)
    private var completion: ((Result<URL, Error>) -> Void)?
    private var stoppedAt: Double?
    private var failure: Error?
    private var lastRouteCheck = -10.0, lastSync = 0.0
    private var lastIssues = ""

    public init(options: Options) throws {
        self.options = options
        let route = try? RouteInfo.current()
        guard let gateway = options.gateway ?? route?.gateway, let interface = options.interface ?? route?.interface else {
            throw AnalyzerError("Cannot discover router. Check Wi-Fi, or specify --gateway LOCAL_IP --interface en0.")
        }
        guard RouteInfo.isLocalIPv4(gateway) else {
            throw AnalyzerError("Default gateway is not a local IPv4 address. A VPN may own the route; specify your Wi-Fi router and interface explicitly.")
        }
        self.gateway = gateway; self.interface = interface; initialRoute = route
        sampler = try MetricsSampler(interface: interface)
        try Subnet.requireOnLink(gateway, interface: interface)
        let directory = try SessionIO.newDirectory(options.output)
        writer = try SessionWriter(directory: directory, metadata: [
            "schemaVersion": 1, "appVersion": "0.1.0", "synthetic": false,
            "startedUTC": ISO8601DateFormatter().string(from: Date()),
            "osVersion": ProcessInfo.processInfo.operatingSystemVersionString,
            "gateway": gateway, "interface": interface,
            "requestedIntervalMS": options.interval * 1000, "metricsIntervalSeconds": 1,
            "timeoutSeconds": 1, "trafficClass": "BE",
            "clock": "Event t uses monotonic system uptime at collection; ping.log retains ping source timestamps. RTT comes from ping, not pipe arrival time.",
            "counterNotes": "getifaddrs byte counters may wrap; a decrease resets the rate baseline.",
            "privacy": "Local-only router probes. No SSID/BSSID, packet contents, Wi-Fi scanning or remote uploads."
        ])
    }

    /// Hosted UI access. Assign and call control methods on the main queue.
    public var onEvent: (([String: Any]) -> Void)? {
        get { writer.onEvent }
        set { writer.onEvent = newValue }
    }
    public var sessionDirectory: URL { writer.directory }
    public var elapsed: Double { writer.elapsed }
    public var gatewayAddress: String { gateway }
    public var interfaceName: String { interface }

    public func start(interactive: Bool = true, completion: @escaping (Result<URL, Error>) -> Void) throws {
        self.completion = completion
        var masterFD: Int32 = -1, slaveFD: Int32 = -1
        guard openpty(&masterFD, &slaveFD, nil, nil, nil) == 0 else { throw AnalyzerError("Cannot allocate ping terminal: \(String(cString: strerror(errno)))") }
        let output = FileHandle(fileDescriptor: slaveFD, closeOnDealloc: true)
        let reader = FileHandle(fileDescriptor: masterFD, closeOnDealloc: true)
        child.executableURL = URL(fileURLWithPath: "/sbin/ping")
        child.arguments = ["-n", "--apple-print-req", "--apple-time", "-b", interface, "-k", "BE", "-i", String(format: "%.4f", options.interval), gateway]
        child.environment = ProcessInfo.processInfo.environment.merging(["LC_ALL": "C"]) { _, new in new }
        child.standardOutput = output; child.standardError = output
        child.standardInput = FileHandle.nullDevice
        try writer.append("start", fields: ["message": "Recording started"])
        do { try child.run() } catch { try? output.close(); try? reader.close(); throw error }
        try output.close()
        master = reader
        print("Recording Wi-Fi \(interface) → router \(gateway), requested interval \(Int(options.interval * 1000)) ms")
        print("Session: \(writer.directory.path)\nEnter = lag marker · Ctrl+C = stop and generate report")
        fflush(stdout)
        readPing(reader)
        for number in interactive ? [SIGINT, SIGTERM] : [] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler { [weak self] in self?.stop() }; source.resume(); signals.append(source)
        }
        if interactive && (isatty(STDIN_FILENO) == 1 || options.duration != nil) {
            let source = DispatchSource.makeReadSource(fileDescriptor: STDIN_FILENO, queue: .main)
            source.setEventHandler { [weak self] in self?.readInput() }
            source.resume(); stdinSource = source
        }
        schedule(every: 0.25) { [weak self] in self?.tick() }
        schedule(every: 1) { [weak self] in self?.sampleMetrics() }
        sampleMetrics()
        if let duration = options.duration {
            DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in self?.stop() }
        }
    }

    private func schedule(every seconds: Double, _ action: @escaping () -> Void) {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + seconds, repeating: seconds, leeway: .milliseconds(10))
        timer.setEventHandler(handler: action); timer.resume(); timers.append(timer)
    }
    private func readPing(_ handle: FileHandle) {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var buffer = Data()
            do {
                var bytes = [UInt8](repeating: 0, count: 8192)
                while true {
                    let count = Darwin.read(handle.fileDescriptor, &bytes, bytes.count)
                    if count == 0 { break }
                    if count < 0 {
                        if errno == EINTR { continue }
                        if errno == EIO { break } // PTY slave closed after ping exits.
                        throw AnalyzerError("Cannot read ping output: \(String(cString: strerror(errno)))")
                    }
                    buffer.append(contentsOf: bytes.prefix(count))
                    while let index = buffer.firstIndex(of: 10) {
                        let line = String(decoding: buffer[..<index], as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                        buffer.removeSubrange(...index)
                        let time = ProcessInfo.processInfo.systemUptime
                        DispatchQueue.main.async { self?.consume(line, collectedAt: time) }
                    }
                }
            } catch {
                // macOS PTYs report EIO after the slave closes; queued lines remain valid.
                DispatchQueue.main.async { self?.ioEnded(error) }
                return
            }
            if !buffer.isEmpty {
                let line = String(decoding: buffer, as: UTF8.self)
                DispatchQueue.main.async { self?.consume(line, collectedAt: ProcessInfo.processInfo.systemUptime) }
            }
            DispatchQueue.main.async { self?.ioEnded(nil) }
        }
    }
    private func consume(_ line: String, collectedAt: Double) {
        guard !finished else { return }
        // Capture reader arrival before queueing so a busy main queue does not distort collection time.
        let time = max(0, writer.elapsed - (ProcessInfo.processInfo.systemUptime - collectedAt))
        do {
            try writer.rawLine(line)
            if let seq = PingParser.sentSequence(line) {
                tracker.sent(sequence: seq, at: time)
                try writer.append("send", at: time, fields: ["id": tracker.probes.count - 1, "sequence": seq, "sourceTime": String(line.prefix(15))])
            } else if let reply = PingParser.reply(line) {
                if let probe = tracker.reply(sequence: reply.sequence, latencyMS: reply.latencyMS, at: time) {
                    try writer.append("reply", at: time, fields: ["id": probe.id, "sequence": reply.sequence, "sent": probe.sent, "latencyMS": reply.latencyMS, "late": probe.timedOut])
                } else {
                    try writer.append("diagnostic", at: time, fields: ["message": "Duplicate/unmatched reply: \(line)"])
                }
            } else if !line.isEmpty && !line.hasPrefix("PING ") && !line.contains("statistics") && !line.contains("packets transmitted") && !line.hasPrefix("round-trip") && !line.hasPrefix("Request timeout") {
                try writer.append("diagnostic", at: time, fields: ["message": line])
            }
        } catch { fail(error) }
    }
    private func tick() {
        guard !finished else { return }
        do {
            for probe in tracker.expire(at: stoppedAt ?? writer.elapsed, timeout: 1) {
                try writer.append("timeout", fields: ["id": probe.id, "sent": probe.sent])
            }
            if writer.elapsed - lastSync >= 10 { try writer.sync(); lastSync = writer.elapsed }
        } catch { fail(error) }
    }
    private func sampleMetrics() {
        guard !stopping, !metricsBusy else { return }
        metricsBusy = true
        let time = writer.elapsed
        let checkRoute = time - lastRouteCheck >= 5
        if checkRoute { lastRouteCheck = time }
        worker.async { [self] in
            let began = ProcessInfo.processInfo.systemUptime
            var metrics = sampler.sample(at: time)
            let route = checkRoute ? try? RouteInfo.current() : nil
            metrics["sampleDurationMS"] = (ProcessInfo.processInfo.systemUptime - began) * 1000
            DispatchQueue.main.async { [self] in
                metricsBusy = false
                guard !finished else { return }
                do {
                    try writer.append("metrics", at: time, fields: ["values": metrics])
                    let issues = (metrics["issues"] as? [String] ?? []).joined(separator: "; ")
                    if issues != lastIssues, !issues.isEmpty { print("Metrics: \(issues)") }
                    lastIssues = issues
                    if checkRoute, let initialRoute, route != initialRoute {
                        try writer.append("diagnostic", fields: ["message": "Default route changed or became unavailable. Recording stopped to avoid mixing network paths."])
                        stop()
                    }
                } catch { fail(error) }
            }
        }
    }
    private func readInput() {
        var buffer = [UInt8](repeating: 0, count: 4096)
        let count = Darwin.read(STDIN_FILENO, &buffer, buffer.count)
        guard count > 0 else { stdinSource?.cancel(); stdinSource = nil; return }
        inputBuffer.append(contentsOf: buffer.prefix(count))
        while let index = inputBuffer.firstIndex(of: 10) {
            let label = String(decoding: inputBuffer[..<index], as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            inputBuffer.removeSubrange(...index)
            if markLag(label.isEmpty ? "Lag" : label) {
                print(String(format: "Marked lag at %.2f s", writer.elapsed))
            }
        }
    }
    @discardableResult public func markLag(_ label: String = "Lag") -> Bool {
        guard !stopping, !finished, child.isRunning else { return false }
        do { try writer.append("marker", fields: ["message": label]); return true }
        catch { fail(error); return false }
    }
    public func stop() {
        guard !stopping, !finished else { return }
        stopping = true
        stoppedAt = writer.elapsed
        do { try writer.append("stopping", at: stoppedAt, fields: ["message": "Observation cutoff; unresolved recent probes stay pending"]) }
        catch { failure = error }
        stdinSource?.cancel(); stdinSource = nil
        print("Stopping…")
        if child.isRunning { child.interrupt() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, !self.finished else { return }
            if self.child.isRunning { self.child.terminate() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            guard let self, !self.finished else { return }
            if self.child.isRunning { kill(self.child.processIdentifier, SIGKILL) }
            self.finalize()
        }
    }
    private func ioEnded(_ error: Error?) {
        guard !finished else { return }
        if !stopping {
            failure = AnalyzerError("ping exited unexpectedly. Inspect ping.log for the system error.")
            stopping = true
            stoppedAt = writer.elapsed
            do { try writer.append("stopping", at: stoppedAt, fields: ["message": "Ping ended unexpectedly"]) }
            catch { failure = error }
        }
        // The child can no longer receive packets. Do not turn censored probes into losses.
        finalize()
    }
    private func fail(_ error: Error) { failure = error; stop() }
    private func finalize() {
        guard !finished else { return }
        if metricsBusy && writer.elapsed - (stoppedAt ?? writer.elapsed) < 2 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in self?.finalize() }
            return
        }
        if metricsBusy {
            do { try writer.append("diagnostic", fields: ["message": "Metrics request did not complete within shutdown deadline; the final sample is omitted."]) }
            catch { failure = error }
        }
        tick()
        finished = true
        timers.forEach { $0.cancel() }; signals.forEach { $0.cancel() }
        stdinSource?.cancel(); try? master?.close()
        do {
            let missing = tracker.probes.filter { $0.latencyMS == nil && $0.timedOut }.count
            let late = tracker.probes.filter { $0.latencyMS != nil && $0.timedOut }.count
            let pending = tracker.probes.filter { $0.latencyMS == nil && !$0.timedOut }.count
            try writer.append("end", fields: ["sent": tracker.probes.count, "missing": missing, "late": late, "pending": pending, "message": failure.map { String(describing: $0) } ?? "Stopped normally"])
            try writer.close()
            let report = try Report.generate(directory: writer.directory)
            print("Saved \(tracker.probes.count) probes · missing \(missing) · late \(late) · pending at stop \(pending)\nReport: \(report.path)")
            if let failure { completion?(.failure(failure)) } else { completion?(.success(report)) }
        } catch { completion?(.failure(error)) }
    }
}
