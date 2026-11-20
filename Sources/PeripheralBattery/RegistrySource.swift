import BatteryCore
import Foundation
import IOKit
import IOKit.hid

enum RegistrySource {
    private static let batteryUsages: [(UInt32, UInt32)] = [(0x06, 0x20), (0x0D, 0x3B), (0x85, 0x64), (0x85, 0x65)]

    static func devices() -> [DeviceBattery] {
        var devices: [String: DeviceBattery] = [:]

        for className in ["IOHIDDevice", "IOHIDEventService", "AppleDeviceManagementHIDEventService"] {
            var iterator: io_iterator_t = 0
            guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(className), &iterator) == KERN_SUCCESS else {
                continue
            }
            defer { IOObjectRelease(iterator) }

            while case let service = IOIteratorNext(iterator), service != 0 {
                defer { IOObjectRelease(service) }
                guard let device = read(service, isHIDDevice: className == "IOHIDDevice") else { continue }
                if var existing = devices[device.id] {
                    existing.reportedKind = existing.reportedKind.includingInterface(device.reportedKind)
                    existing.levels.merge(device.levels) { old, _ in old }
                    devices[device.id] = existing
                } else {
                    devices[device.id] = device
                }
            }
        }
        return Array(devices.values)
    }

    private static func read(_ service: io_service_t, isHIDDevice: Bool) -> DeviceBattery? {
        var dictionary: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &dictionary, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let properties = dictionary?.takeRetainedValue() as? [String: Any],
              let transportName = (properties["Transport"] as? String)?.lowercased(),
              (properties["Built-In"] as? NSNumber)?.boolValue != true else { return nil }

        let transport: DeviceBattery.Transport
        switch transportName {
        case let name where name.contains("bluetooth"): transport = .bluetooth
        case "usb": transport = .usb
        default: return nil
        }

        let name = (properties["Product"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let vendor = (properties["VendorID"] as? NSNumber)?.uint32Value ?? 0
        let product = (properties["ProductID"] as? NSNumber)?.uint32Value ?? 0
        let location = (properties["LocationID"] as? NSNumber)?.uint32Value ?? 0
        let modelID = vendor != 0 && product != 0 ? String(format: "%04x:%04x", vendor, product) : nil
        let kind = DeviceKind(
            hidUsagePage: (properties["PrimaryUsagePage"] as? NSNumber)?.intValue ?? 0,
            usage: (properties["PrimaryUsage"] as? NSNumber)?.intValue ?? 0
        )
        let address = ["DeviceAddress", "Address", "SerialNumber"].lazy.compactMap {
            DeviceBattery.address(properties[$0] as? String)
        }.first

        var levels: [BatteryPart: Int] = [:]
        let batteryKeys: [(BatteryPart, [String])] = [
            (.main, ["BatteryPercent", "BatteryLevel", "BatteryPercentage"]),
            (.left, ["BatteryPercentLeft", "BatteryLevelLeft"]),
            (.right, ["BatteryPercentRight", "BatteryLevelRight"]),
            (.caseBattery, ["BatteryPercentCase", "BatteryLevelCase"]),
        ]
        for (part, keys) in batteryKeys {
            levels[part] = keys.lazy.compactMap { DeviceBattery.percent(properties[$0]) }.first
        }
        if levels[.main] == nil, isHIDDevice, let percent = readStandardBattery(service) {
            levels[.main] = percent
        }

        let isReceiver = ["receiver", "2.4g", "dongle", "接收器"].contains {
            name?.localizedCaseInsensitiveContains($0) == true
        }
        if levels.isEmpty {
            guard isHIDDevice, transport == .bluetooth || isReceiver else { return nil }
        }

        let id: String
        if transport == .bluetooth, let address {
            id = "bt:\(address)"
        } else if transport == .usb, location != 0 {
            id = "usb:\(modelID ?? "unknown")@\(location)"
        } else {
            id = "\(transport == .bluetooth ? "bthid" : "usbhid"):\(hidParentID(of: service))"
        }

        return DeviceBattery(
            id: id, name: name.flatMap { $0.isEmpty ? nil : $0 } ?? "无线外设",
            modelID: modelID, transport: transport, reportedKind: kind, levels: levels
        )
    }

    private static func hidParentID(of service: io_service_t) -> UInt64 {
        var id: UInt64 = 0
        IORegistryEntryGetRegistryEntryID(service, &id)
        var entry = service
        IOObjectRetain(entry)
        defer { IOObjectRelease(entry) }
        // The HID device and its event-service child should share an identity.
        while IOObjectConformsTo(entry, "IOHIDDevice") == 0 {
            var parent: io_registry_entry_t = 0
            guard IORegistryEntryGetParentEntry(entry, kIOServicePlane, &parent) == KERN_SUCCESS else { return id }
            IOObjectRelease(entry)
            entry = parent
        }
        IORegistryEntryGetRegistryEntryID(entry, &id)
        return id
    }

    private static func readStandardBattery(_ service: io_service_t) -> Int? {
        guard let device = IOHIDDeviceCreate(kCFAllocatorDefault, service) else { return nil }
        for (page, usage) in batteryUsages {
            let matching = ["UsagePage": page, "Usage": usage] as CFDictionary
            guard let elements = IOHIDDeviceCopyMatchingElements(device, matching, 0) as? [IOHIDElement], !elements.isEmpty else {
                continue
            }
            let batteryElements = elements.filter {
                let type = IOHIDElementGetType($0)
                return type == kIOHIDElementTypeFeature || type == kIOHIDElementTypeInput_Misc
            }
            guard !batteryElements.isEmpty, IOHIDDeviceOpen(device, 0) == kIOReturnSuccess else { continue }
            defer { IOHIDDeviceClose(device, 0) }
            for element in batteryElements {
                let reading = withUnsafeTemporaryAllocation(of: Unmanaged<IOHIDValue>.self, capacity: 1) { buffer -> Int? in
                    guard let value = buffer.baseAddress,
                          IOHIDDeviceGetValue(device, element, value) == kIOReturnSuccess else { return nil }
                    return IOHIDValueGetIntegerValue(value.pointee.takeUnretainedValue())
                }
                guard let reading else { continue }
                let min = IOHIDElementGetLogicalMin(element)
                let max = IOHIDElementGetLogicalMax(element)
                guard max > min, (min...max).contains(reading) else { continue }
                if page == 0x85 {
                    if (0...100).contains(reading) { return reading }
                } else {
                    return DeviceBattery.percent((Double(reading) - Double(min)) * 100 / (Double(max) - Double(min)))
                }
            }
        }
        return nil
    }
}
