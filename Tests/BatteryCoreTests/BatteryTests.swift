import BatteryCore
import Foundation
import Testing

struct BatteryTests {
    @Test func zeroIsAReadingAndInvalidValuesAreUnavailable() {
        #expect(DeviceBattery.percent("0%") == 0)
        #expect(DeviceBattery.percent(NSNumber(value: 62)) == 62)
        #expect(DeviceBattery.percent(" 97 % ") == 97)
        for invalid in [true, "-1", "101%", "nan", NSNumber(value: false)] as [Any] {
            #expect(DeviceBattery.percent(invalid) == nil)
        }
        #expect(DeviceBattery(id: "a", name: "Mouse", transport: .usb).minimum == nil)
    }

    @Test func systemAndBluetoothSourcesMergeWithoutCombiningDifferentKnownAddresses() {
        let report = DeviceBattery(id: "bt:001122aabbcc", name: "Earbuds", transport: .bluetooth, levels: [.left: 24, .right: 30])
        let sameName = DeviceBattery(id: "ble:peripheral", name: "Earbuds", transport: .bluetooth, levels: [.main: 28])
        let matched = DeviceBattery.merge([report], with: [sameName])
        #expect(matched.count == 1)
        #expect(matched.first?.displayedLevels == [.left: 24, .right: 30])
        #expect(matched.first?.minimum == 24)
        let differentAddress = DeviceBattery(id: "bt:001122aabbdd", name: "Earbuds", transport: .bluetooth)
        #expect(DeviceBattery.merge([report], with: [differentAddress]).count == 2)
        #expect(DeviceBattery.merge([report], with: [sameName, differentAddress]).count == 3)
    }

    @Test func lowBatteryAlertsRemainDeduplicatedUntilRecovery() throws {
        let device = DeviceBattery(id: "usb:mouse", name: "Mouse", transport: .usb, levels: [.main: 20])
        var alerts = LowBatteryAlerts()
        let event = try #require(alerts.pending(in: [device], threshold: 20).first)
        #expect(event.message == "Mouse · 20%")
        #expect(alerts.pending(in: [device], threshold: 20).count == 1)
        alerts.markSent(event)

        var restored = LowBatteryAlerts(sent: alerts.sent)
        #expect(restored.pending(in: [], threshold: 20).isEmpty)
        var rechargeable = device
        rechargeable.levels[.main] = 22
        #expect(restored.pending(in: [rechargeable], threshold: 20).isEmpty)
        #expect(restored.pending(in: [device], threshold: 20).isEmpty)
        rechargeable.levels[.main] = 23
        #expect(restored.pending(in: [rechargeable], threshold: 20).isEmpty)
        #expect(restored.pending(in: [device], threshold: 20).count == 1)
    }

    @Test func systemAccessoryReadingNeedsAnUnambiguousConnectedDevice() {
        let controller = DeviceBattery(id: "bt:controller", name: "Xbox Wireless Controller", transport: .bluetooth)
        let output = "Now drawing from 'AC Power'\n -Xbox Wireless Controller (id=24384397)\t66%; \n"
        #expect(DeviceBattery.fillingSystemAccessoryLevels([controller], from: output).first?.minimum == 66)
        let second = DeviceBattery(id: "bt:second", name: controller.name, transport: .bluetooth)
        #expect(DeviceBattery.fillingSystemAccessoryLevels([controller, second], from: output).allSatisfy { $0.minimum == nil })
        #expect(DeviceBattery.fillingSystemAccessoryLevels([controller], from: output + output).first?.minimum == nil)
    }

    @Test func identifiesEachDeviceAndKeepsTheKindWhenSourcesMerge() {
        let mouse = DeviceBattery(id: "bt:mouse", name: "My accessory", transport: .bluetooth)
        let hidMouse = DeviceBattery(
            id: mouse.id, name: mouse.name, transport: .bluetooth,
            reportedKind: DeviceKind(hidUsagePage: 1, usage: 2), levels: [.main: 87]
        )
        let controller = DeviceBattery(id: "bt:controller", name: "Xbox Wireless Controller", transport: .bluetooth)
        let keyboard = DeviceBattery(id: "ble:keyboard", name: "办公键盘", transport: .bluetooth)
        let merged = DeviceBattery.merge([mouse, controller, keyboard], with: [hidMouse])
        #expect(merged.map(\.kind) == [.mouse, .controller, .keyboard])
        #expect(merged.first?.minimum == 87)
    }

    @Test func aSharedKeyboardAndMouseReceiverHasOneDeviceKind() {
        let mouse = DeviceKind(hidUsagePage: 1, usage: 2)
        let keyboard = DeviceKind(hidUsagePage: 1, usage: 6)
        #expect(keyboard.includingInterface(mouse) == .keyboardAndMouse)
        #expect(mouse.includingInterface(keyboard) == .keyboardAndMouse)
        #expect(mouse.includingInterface(.other) == .mouse)
    }

    @Test func newlyLowEarbudCanAlertIndependently() throws {
        var earbuds = DeviceBattery(id: "bt:earbuds", name: "Earbuds", transport: .bluetooth, levels: [.left: 10, .right: 21])
        var alerts = LowBatteryAlerts()
        let left = try #require(alerts.pending(in: [earbuds], threshold: 20).first)
        alerts.markSent(left)
        earbuds.levels[.right] = 19
        let right = try #require(alerts.pending(in: [earbuds], threshold: 20).first)
        #expect(right.parts == [.right])
    }
}
