import CoreFoundation
import Foundation

public enum BatteryPart: String, CaseIterable, Sendable {
    case main, left, right, caseBattery

    public var label: String {
        switch self {
        case .main: "整机"
        case .left: "左耳"
        case .right: "右耳"
        case .caseBattery: "充电盒"
        }
    }
}

public struct DeviceBattery: Sendable {
    public enum Transport: String, Sendable {
        case bluetooth = "蓝牙"
        case usb = "USB / 2.4 GHz"
    }

    public var id: String
    public var name: String
    public var modelID: String?
    public let transport: Transport
    public var reportedKind: DeviceKind
    public var levels: [BatteryPart: Int]

    public init(
        id: String, name: String, modelID: String? = nil, transport: Transport,
        reportedKind: DeviceKind = .other, levels: [BatteryPart: Int] = [:]
    ) {
        self.id = id
        self.name = name
        self.modelID = modelID
        self.transport = transport
        self.reportedKind = reportedKind
        self.levels = levels.filter { (0...100).contains($0.value) }
    }

    public var kind: DeviceKind {
        let named = DeviceKind(description: name)
        if named != .other { return named }
        if reportedKind == .other, levels.keys.contains(where: { $0 != .main }) { return .headphones }
        return reportedKind
    }

    public var minimum: Int? { displayedLevels.values.min() }

    public var displayedLevels: [BatteryPart: Int] {
        guard levels[.left] != nil || levels[.right] != nil else { return levels }
        return levels.filter { $0.key != .main }
    }

    public var displayText: String {
        let values = displayedLevels
        if values.count == 1, let percent = values[.main] { return "\(percent)%" }
        if values.isEmpty { return "未报告电量" }
        return BatteryPart.allCases.compactMap { part in
            values[part].map { "\(part.label) \($0)%" }
        }.joined(separator: "  ·  ")
    }

    public static func percent(_ value: Any?) -> Int? {
        let parsed: Double?
        switch value {
        case let number as NSNumber where CFGetTypeID(number) != CFBooleanGetTypeID():
            parsed = number.doubleValue
        case let string as String:
            var cleaned = string.trimmingCharacters(in: .whitespacesAndNewlines)
            if cleaned.hasSuffix("%") { cleaned.removeLast() }
            parsed = Double(cleaned.trimmingCharacters(in: .whitespaces))
        default:
            parsed = nil
        }
        guard let parsed, (0...100).contains(parsed) else { return nil }
        return Int(parsed.rounded())
    }

    public static func address(_ value: String?) -> String? {
        guard let value else { return nil }
        let hex = value.lowercased().filter { $0 != ":" && $0 != "-" }
        guard hex.utf8.count == 12, hex.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              hex != "000000000000" else { return nil }
        return hex
    }

    public static func merge(_ preferred: [Self], with fallback: [Self]) -> [Self] {
        var result = preferred
        for device in fallback {
            let sameID = result.firstIndex { $0.id == device.id }
            let sameName = result.indices.filter {
                result[$0].transport == .bluetooth && device.transport == .bluetooth
                    && result[$0].name.caseInsensitiveCompare(device.name) == .orderedSame
            }
            let fallbackNameIsUnique = fallback.lazy.filter {
                $0.transport == .bluetooth && $0.name.caseInsensitiveCompare(device.name) == .orderedSame
            }.prefix(2).count == 1
            let nameMatch = sameName.count == 1 && fallbackNameIsUnique ? sameName.first : nil
            let index = sameID ?? nameMatch.flatMap { index in
                // Two different known addresses identify separate devices, even with the same name.
                result[index].id.hasPrefix("bt:") && device.id.hasPrefix("bt:") ? nil : index
            }

            guard let index else {
                result.append(device)
                continue
            }
            if device.id.hasPrefix("bt:") { result[index].id = device.id }
            result[index].modelID = result[index].modelID ?? device.modelID
            if result[index].reportedKind == .other { result[index].reportedKind = device.kind }
            result[index].levels.merge(device.levels) { preferred, _ in preferred }
        }
        return result
    }

    public static func fillingSystemAccessoryLevels(_ devices: [Self], from output: String) -> [Self] {
        let pattern = #/\s*-(.+) \(id=[0-9]+\)\t([0-9]+)%;.*/#
        let rows = output.split(separator: "\n").compactMap { line -> (String, Int)? in
            guard let match = try? pattern.wholeMatch(in: line), let percent = DeviceBattery.percent(String(match.2)) else {
                return nil
            }
            return (String(match.1), percent)
        }
        return devices.map { device in
            guard device.levels[.main] == nil else { return device }
            let matchingDevices = devices.filter { $0.name.caseInsensitiveCompare(device.name) == .orderedSame }
            let matchingRows = rows.filter { $0.0.caseInsensitiveCompare(device.name) == .orderedSame }
            guard matchingDevices.count == 1, matchingRows.count == 1, let reading = matchingRows.first else {
                return device
            }
            var filled = device
            filled.levels[.main] = reading.1
            return filled
        }
    }
}

public struct LowBatteryAlerts {
    public struct Event {
        public let device: DeviceBattery
        public let parts: [BatteryPart]

        public var message: String {
            let values = parts.compactMap { part in
                device.displayedLevels[part].map { part == .main ? "\($0)%" : "\(part.label) \($0)%" }
            }
            return "\(device.name) · \(values.joined(separator: "，"))"
        }

        fileprivate var keys: [String] { parts.map { "\(device.id)/\($0.rawValue)" } }
    }

    public private(set) var sent: Set<String>

    public init(sent: Set<String> = []) { self.sent = sent }

    public mutating func pending(in devices: [DeviceBattery], threshold: Int) -> [Event] {
        let recovery = min(threshold + 3, 100)
        return devices.compactMap { device in
            let levels = device.displayedLevels
            let low = BatteryPart.allCases.filter { part in
                guard let level = levels[part] else { return false }
                let key = "\(device.id)/\(part.rawValue)"
                if level >= recovery { sent.remove(key) }
                return level <= threshold && !sent.contains(key)
            }
            return low.isEmpty ? nil : Event(device: device, parts: low)
        }
    }

    public mutating func markSent(_ event: Event) { sent.formUnion(event.keys) }
}
