import Darwin
import Foundation
import MetricKit
import UIKit

/// Makes Myna's failures visible on the phone itself — TestFlight crash reports
/// were arriving late or not at all, so a crash just looked like "it quit".
///
/// Four sources, all written under Application Support/Diagnostics and shown
/// in Backstage → Diagnostics:
/// - Objective-C exceptions (e.g. an AVAudioEngine assertion) with their stack.
/// - Fatal signals (Swift traps, bad memory access) with a raw backtrace.
/// - Unclean exits: a launch marker plus a heartbeat, so a launch that finds
///   the previous run never ended cleanly records how it was last seen
///   (foreground / background, listening, memory). This is how an iOS memory
///   or watchdog kill — which is not a crash and never produces a report —
///   shows up.
/// - MetricKit: Apple's own crash diagnostics and app-exit reasons, delivered
///   on a later launch.
final class CrashReporter: NSObject, MXMetricManagerSubscriber {
    static let shared = CrashReporter()

    static let directory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Diagnostics", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private static let markerURL = directory.appendingPathComponent("running.json")
    private static let logURL = directory.appendingPathComponent("events.log")
    private static let signalURL = directory.appendingPathComponent("signal-crash.txt")
    private static let queue = DispatchQueue(label: "myna.crashreporter")

    private var heartbeat: Timer?
    private var started = false

    /// Call first thing at launch.
    func start() {
        guard !started else { return }
        started = true
        Self.collectPreviousRun()
        Self.installHandlers()
        MXMetricManager.shared.add(self)
        writeMarker(clean: false)
        heartbeat = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            self?.writeMarker(clean: false)
        }
        let center = NotificationCenter.default
        center.addObserver(forName: UIApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            self?.writeMarker(clean: true)
        }
        center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            Self.log("entered background")
            self?.writeMarker(clean: false)
        }
        center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { _ in
            Self.log("entering foreground")
        }
        center.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main) { _ in
            Self.log("MEMORY WARNING — footprint \(Self.memoryFootprintMB()) MB")
        }
        Self.log("launch — build \(Self.buildString)")
    }

    // MARK: - Event log

    /// Append a line to the rolling diagnostics log (kept to ~200 KB).
    static func log(_ message: String) {
        let line = "\(stamp()) \(message)\n"
        queue.async {
            let fm = FileManager.default
            if let attrs = try? fm.attributesOfItem(atPath: logURL.path),
               let size = attrs[.size] as? Int, size > 200_000,
               let data = try? Data(contentsOf: logURL) {
                try? data.suffix(100_000).write(to: logURL)
            }
            if let handle = try? FileHandle(forWritingTo: logURL) {
                handle.seekToEndOfFile()
                handle.write(Data(line.utf8))
                try? handle.close()
            } else {
                try? Data(line.utf8).write(to: logURL)
            }
        }
    }

    // MARK: - Reports

    struct Report: Identifiable {
        let id: String
        let date: Date
        let title: String
        let body: String
    }

    /// Every saved report, newest first.
    static func reports() -> [Report] {
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.creationDateKey])) ?? []
        return files.compactMap { url -> Report? in
            let name = url.lastPathComponent
            guard name.hasPrefix("report-"), let body = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            let date = (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            let title = body.split(separator: "\n").first.map(String.init) ?? name
            return Report(id: name, date: date, title: title, body: body)
        }
        .sorted { $0.date > $1.date }
    }

    static func eventLog() -> String {
        (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
    }

    static func clearReports() {
        let fm = FileManager.default
        for url in (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        where url.lastPathComponent.hasPrefix("report-") {
            try? fm.removeItem(at: url)
        }
    }

    /// Everything, as one block of text to paste into a bug report.
    static func fullText() -> String {
        var out = "Myna diagnostics — build \(buildString), iOS \(UIDevice.current.systemVersion)\n\n"
        for report in reports() {
            out += "===== \(report.id) =====\n\(report.body)\n\n"
        }
        out += "===== event log (tail) =====\n" + String(eventLog().suffix(30_000))
        return out
    }

    private static func save(_ title: String, _ body: String) {
        let name = "report-\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString.prefix(4)).txt"
        try? "\(title)\n\(body)".write(to: directory.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    // MARK: - Previous run

    private static func collectPreviousRun() {
        let fm = FileManager.default
        // A fatal signal from last time.
        if let text = try? String(contentsOf: signalURL, encoding: .utf8), !text.isEmpty {
            save("CRASH (signal)", text)
            try? fm.removeItem(at: signalURL)
        }
        // The previous run never reached a clean exit.
        if let data = try? Data(contentsOf: markerURL),
           let marker = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           (marker["clean"] as? Bool) == false {
            let last = (marker["time"] as? Double).map { Date(timeIntervalSince1970: $0) } ?? .distantPast
            let lines = marker.keys.sorted().map { "\($0): \(marker[$0] ?? "")" }.joined(separator: "\n")
            save("Myna ended unexpectedly (last seen \(stamp(last)))",
                 """
                 The previous run stopped without a clean exit. If no crash report \
                 accompanies this, iOS most likely terminated Myna (memory, CPU or \
                 watchdog limit) or it was swiped away.

                 Last heartbeat:
                 \(lines)
                 """)
        }
    }

    private func writeMarker(clean: Bool) {
        let state: String
        switch UIApplication.shared.applicationState {
        case .active: state = "foreground"
        case .inactive: state = "inactive"
        case .background: state = "background"
        @unknown default: state = "unknown"
        }
        var marker: [String: Any] = [
            "clean": clean,
            "time": Date().timeIntervalSince1970,
            "appState": state,
            "memoryMB": Self.memoryFootprintMB(),
            "build": Self.buildString,
        ]
        if Thread.isMainThread {
            MainActor.assumeIsolated {
                let services = AppServices.sharedIfReady
                marker["listening"] = services?.listener.isListening ?? false
                marker["wantsToListen"] = services?.listener.wantsToListen ?? false
                marker["pilotPhase"] = String(describing: services?.pilot.phase ?? .idle)
            }
        }
        if let data = try? JSONSerialization.data(withJSONObject: marker) {
            try? data.write(to: Self.markerURL, options: .atomic)
        }
    }

    // MARK: - Handlers

    private static func installHandlers() {
        NSSetUncaughtExceptionHandler { exception in
            let body = """
            \(exception.name.rawValue): \(exception.reason ?? "")
            \(exception.callStackSymbols.joined(separator: "\n"))
            """
            CrashReporter.save("CRASH (exception) \(exception.name.rawValue)", body)
        }
        // Open the signal file now: the handler may only use async-signal-safe calls.
        signalFD = open(signalURL.path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        for sig in [SIGABRT, SIGSEGV, SIGBUS, SIGILL, SIGTRAP, SIGFPE] {
            signal(sig, crashSignalHandler)
        }
    }

    // MARK: - MetricKit

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads {
            for crash in payload.crashDiagnostics ?? [] {
                let reason = crash.terminationReason ?? crash.exceptionType.map { "exception \($0)" } ?? "crash"
                Self.save("CRASH (Apple report) \(reason)", String(decoding: crash.jsonRepresentation(), as: UTF8.self))
            }
            for hang in payload.hangDiagnostics ?? [] {
                Self.save("HANG \(hang.hangDuration)", String(decoding: hang.jsonRepresentation(), as: UTF8.self))
            }
            for cpu in payload.cpuExceptionDiagnostics ?? [] {
                Self.save("CPU LIMIT", String(decoding: cpu.jsonRepresentation(), as: UTF8.self))
            }
        }
    }

    func didReceive(_ payloads: [MXMetricPayload]) {
        for payload in payloads {
            guard let exits = payload.applicationExitMetrics else { continue }
            let bg = exits.backgroundExitData
            let fg = exits.foregroundExitData
            let summary = """
            Background: memory limit \(bg.cumulativeMemoryResourceLimitExitCount), memory pressure \(bg.cumulativeMemoryPressureExitCount), \
            CPU \(bg.cumulativeCPUResourceLimitExitCount), watchdog \(bg.cumulativeAppWatchdogExitCount), \
            crash \(bg.cumulativeAbnormalExitCount + bg.cumulativeBadAccessExitCount + bg.cumulativeIllegalInstructionExitCount), \
            suspended w/ locked file \(bg.cumulativeSuspendedWithLockedFileExitCount), normal \(bg.cumulativeNormalAppExitCount)
            Foreground: memory limit \(fg.cumulativeMemoryResourceLimitExitCount), watchdog \(fg.cumulativeAppWatchdogExitCount), \
            crash \(fg.cumulativeAbnormalExitCount + fg.cumulativeBadAccessExitCount + fg.cumulativeIllegalInstructionExitCount), \
            normal \(fg.cumulativeNormalAppExitCount)
            """
            Self.save("App exits \(Self.stamp(payload.timeStampBegin))–\(Self.stamp(payload.timeStampEnd))", summary)
        }
    }

    // MARK: - Helpers

    static var buildString: String {
        let info = Bundle.main.infoDictionary
        return "\(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))"
    }

    static func memoryFootprintMB() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Int(info.phys_footprint / 1_048_576) : -1
    }

    private static func stamp(_ date: Date = Date()) -> String {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm:ss"
        return f.string(from: date)
    }
}

private nonisolated(unsafe) var signalFD: Int32 = -1
/// Preallocated so the handler never touches the heap.
private nonisolated(unsafe) let signalFrames = UnsafeMutablePointer<UnsafeMutableRawPointer?>.allocate(capacity: 64)

/// Async-signal-safe: write the signal number and a raw backtrace to the
/// pre-opened file, then re-raise so iOS still records the crash.
private func crashSignalHandler(_ sig: Int32) {
    if signalFD >= 0 {
        var header: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8) =
            (83, 73, 71, 78, 65, 76, 32, 48 + UInt8(truncatingIfNeeded: (sig / 10) % 10), 48 + UInt8(truncatingIfNeeded: sig % 10), 10) // "SIGNAL nn\n"
        withUnsafeBytes(of: &header) { _ = write(signalFD, $0.baseAddress, $0.count) }
        let count = backtrace(signalFrames, 64)
        backtrace_symbols_fd(signalFrames, count, signalFD)
        fsync(signalFD)
    }
    signal(sig, SIG_DFL)
    raise(sig)
}
