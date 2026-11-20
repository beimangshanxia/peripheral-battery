import BatteryCore
import Foundation

enum BluetoothReport {
    static func devices() -> [DeviceBattery] {
        guard let data = SystemBatteryCommand.read(
            "/usr/sbin/system_profiler", arguments: ["SPBluetoothDataType", "-json", "-detailLevel", "full", "-timeout", "8"]
        ),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let controllers = root["SPBluetoothDataType"] as? [[String: Any]] else { return [] }

        return controllers.flatMap { controller in
            let connected = controller["device_connected"] as? [[String: [String: Any]]] ?? []
            return connected.flatMap { entry in
                entry.map { name, properties in
                    let address = DeviceBattery.address(properties["device_address"] as? String)
                    let keys: [BatteryPart: String] = [
                        .main: "device_batteryLevelMain",
                        .left: "device_batteryLevelLeft",
                        .right: "device_batteryLevelRight",
                        .caseBattery: "device_batteryLevelCase",
                    ]
                    let levels = keys.compactMapValues { DeviceBattery.percent(properties[$0]) }
                    let kind = DeviceKind(description: properties["device_minorType"] as? String ?? "")
                    return DeviceBattery(
                        id: address.map { "bt:\($0)" } ?? "btprofiler:\(name)",
                        name: name, transport: .bluetooth, reportedKind: kind, levels: levels
                    )
                }
            }
        }
    }
}

enum SystemBatteryCommand {
    static func read(_ path: String, arguments: [String]) -> Data? {
        let command = Process()
        command.executableURL = URL(fileURLWithPath: path)
        command.arguments = arguments
        command.environment = ProcessInfo.processInfo.environment.merging(["LC_ALL": "C"]) { _, locale in locale }
        let output = Pipe()
        command.standardOutput = output
        command.standardError = FileHandle.nullDevice
        do {
            try command.run()
        } catch {
            return nil
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        command.waitUntilExit()
        return command.terminationStatus == 0 ? data : nil
    }
}
