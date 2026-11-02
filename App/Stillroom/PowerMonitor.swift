import Foundation
import IOKit.ps
import PhotoIndex

final class MachineLimits: @unchecked Sendable {
    private let lock = NSLock()
    private var reason: BackgroundPauseReason?

    func update(_ snapshot: PowerSnapshot) {
        let next = BackgroundPause.reason(for: snapshot)
        lock.lock()
        reason = next
        lock.unlock()
    }

    func current() -> BackgroundPauseReason? {
        lock.lock()
        defer { lock.unlock() }
        return reason
    }
}

enum PowerMonitor {
    static func snapshot() -> PowerSnapshot {
        let thermal = ProcessInfo.processInfo.thermalState
        let battery = readBattery()
        return PowerSnapshot(
            lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled,
            onBattery: battery.onBattery,
            batteryPercent: battery.percent,
            thermalSeriousOrCritical: thermal == .serious || thermal == .critical
        )
    }

    private static func readBattery() -> (onBattery: Bool, percent: Int?) {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else {
            return (false, nil)
        }
        guard let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else {
            return (false, nil)
        }
        var onBattery = false
        var percent: Int?
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue() as? [String: Any] else {
                continue
            }
            let state = description[kIOPSPowerSourceStateKey as String] as? String
            if state == (kIOPSBatteryPowerValue as String) {
                onBattery = true
            }
            let current = integer(description[kIOPSCurrentCapacityKey as String])
            let max = integer(description[kIOPSMaxCapacityKey as String])
            if let current, let max, max > 0 {
                percent = Int((Double(current) / Double(max) * 100).rounded())
            }
        }
        return (onBattery, percent)
    }

    private static func integer(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        if let int = value as? Int { return int }
        return nil
    }
}
