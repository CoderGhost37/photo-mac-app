import Foundation

public enum BackgroundPauseReason: String, Equatable, Sendable {
    case lowPower
    case lowBattery
    case thermal
}

/// What the Mac reported. IOKit and ProcessInfo stay in the app; this is the decision.
public struct PowerSnapshot: Equatable, Sendable {
    public var lowPowerMode: Bool
    public var onBattery: Bool
    /// 0...100 when a battery is present. Nil on a desktop, or when the reading is missing.
    public var batteryPercent: Int?
    public var thermalSeriousOrCritical: Bool

    public init(lowPowerMode: Bool, onBattery: Bool, batteryPercent: Int?, thermalSeriousOrCritical: Bool) {
        self.lowPowerMode = lowPowerMode
        self.onBattery = onBattery
        self.batteryPercent = batteryPercent
        self.thermalSeriousOrCritical = thermalSeriousOrCritical
    }
}

public enum BackgroundPause {
    /// On battery at or below this percent, indexing pauses. A Mac on power, or a desktop with no battery, does not.
    public static let lowBatteryPercent = 20

    /// Thermal state wins, then Low Power Mode, then a low battery.
    public static func reason(for snapshot: PowerSnapshot) -> BackgroundPauseReason? {
        if snapshot.thermalSeriousOrCritical { return .thermal }
        if snapshot.lowPowerMode { return .lowPower }
        if snapshot.onBattery, let percent = snapshot.batteryPercent, percent <= lowBatteryPercent {
            return .lowBattery
        }
        return nil
    }

    public static func message(_ reason: BackgroundPauseReason) -> String {
        switch reason {
        case .lowPower:
            return "Indexing paused · Low Power Mode"
        case .lowBattery:
            return "Indexing paused · battery is low"
        case .thermal:
            return "Indexing paused · this Mac is too warm"
        }
    }
}
