import AppKit
import BatteryCore
import CoreBluetooth
import OSLog
import ServiceManagement
import UserNotifications

@main
@MainActor
struct PeripheralBatteryApp {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = BatteryMenu()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor
private final class BatteryMenu: NSObject, NSApplicationDelegate, NSMenuDelegate, UNUserNotificationCenterDelegate {
    private static let logger = Logger(subsystem: "local.beimang.PeripheralBattery", category: "BatteryMenu")
    private static let thresholds = [10, 15, 20, 25, 30, 40, 50]
    private let defaults = UserDefaults.standard
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private let center = UNUserNotificationCenter.current()
    private let bluetooth = BLEBattery()
    private let loginItem = SMAppService.mainApp

    private var threshold = 20
    private var notificationStatus: UNAuthorizationStatus?
    private var alerts = LowBatteryAlerts()
    private var sendingAlert = false
    private var refreshing = false
    private var registry: [DeviceBattery] = []
    private var report: [DeviceBattery] = []
    private var systemAccessories = ""
    private var devices: [DeviceBattery] = []
    private var timer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        defaults.register(defaults: ["LowBatteryThreshold": 20, "BluetoothEnabled": false])
        let savedThreshold = defaults.integer(forKey: "LowBatteryThreshold")
        if Self.thresholds.contains(savedThreshold) { threshold = savedThreshold }
        alerts = LowBatteryAlerts(sent: Set(defaults.stringArray(forKey: "SentLowBatteryAlerts") ?? []))
        center.delegate = self
        menu.delegate = self
        statusItem.menu = menu
        bluetooth.onChange = { [weak self] in self?.updateDevices() }
        if defaults.bool(forKey: "BluetoothEnabled") { bluetooth.start() }
        updateDevices()
        refresh()

        let timer = Timer(timeInterval: 60, target: self, selector: #selector(refresh), userInfo: nil, repeats: true)
        timer.tolerance = 5
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(didWake), name: NSWorkspace.didWakeNotification, object: nil
        )
        Self.logger.info("Status item installed")
    }

    func applicationWillTerminate(_ notification: Notification) {
        timer?.invalidate()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuildMenu()
    }

    func menuWillOpen(_ menu: NSMenu) {
        Task { await updateNotificationStatus() }
    }

    @objc private func didWake(_ notification: Notification) { refresh() }

    @objc private func refresh() {
        guard !refreshing else { return }
        refreshing = true
        bluetooth.refresh()
        let readBluetoothReport = defaults.bool(forKey: "BluetoothEnabled") && bluetooth.authorization == .allowedAlways
        Task {
            await updateNotificationStatus()
            let snapshot = await Task.detached(priority: .utility) {
                let registry = RegistrySource.devices()
                let report = readBluetoothReport ? BluetoothReport.devices() : []
                let accessories = SystemBatteryCommand.read("/usr/bin/pmset", arguments: ["-g", "accps"])
                    .flatMap { String(data: $0, encoding: .utf8) } ?? ""
                return (registry, report, accessories)
            }.value
            registry = snapshot.0
            report = snapshot.1
            systemAccessories = snapshot.2
            refreshing = false
            updateDevices()
            let readings = MenuBarDisplay.readings(for: devices, threshold: threshold)
            let summary = readings.map { "\($0.device.kind.rawValue) \($0.percent)%" }.joined(separator: ", ")
            Self.logger.info("Refreshed \(self.devices.count, privacy: .public) peripherals, menu bar: \(summary, privacy: .public)")
        }
    }

    private func updateDevices() {
        let system = DeviceBattery.merge(report, with: registry)
        let connected = DeviceBattery.merge(system, with: bluetooth.devices)
        devices = DeviceBattery.fillingSystemAccessoryLevels(connected, from: systemAccessories).sorted {
            if $0.transport != $1.transport { return $0.transport == .bluetooth }
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
        updateStatusItem()
        checkForLowBattery()
    }

    private func updateStatusItem() {
        guard let button = statusItem.button else { return }
        let readings = MenuBarDisplay.readings(for: devices, threshold: threshold)
        let descriptions = readings.map(\.description)
        button.image = MenuBarDisplay.image(for: readings)
        button.imagePosition = .imageOnly
        button.setAccessibilityLabel(descriptions.isEmpty ? "外设电量，暂无读数" : descriptions.joined(separator: "；"))
        button.toolTip = descriptions.isEmpty ? "外设电量，暂无读数" : descriptions.joined(separator: "\n")
    }

    private func rebuildMenu() {
        menu.removeAllItems()
        let known = devices.filter { $0.minimum != nil }.count
        menu.addItem(info(known == 0 ? "外设电量" : "外设电量 · \(known) 台有读数"))
        menu.addItem(.separator())

        if devices.isEmpty {
            menu.addItem(info(refreshing ? "正在读取设备…" : "暂无可显示的无线设备"))
        }
        for transport in [DeviceBattery.Transport.bluetooth, .usb] {
            let rows = devices.filter { $0.transport == transport }
            guard !rows.isEmpty else { continue }
            if #available(macOS 14.0, *) {
                menu.addItem(.sectionHeader(title: transport.rawValue))
            } else {
                menu.addItem(info(transport.rawValue))
            }
            for device in rows {
                let low = device.minimum.map { $0 <= threshold } ?? false
                let item = info("\(device.name)    \(device.displayText)\(low ? "  ·  低电量" : "")")
                item.image = device.kind.menuImage
                item.toolTip = [device.name, device.modelID, device.displayText].compactMap { $0 }.joined(separator: " · ")
                menu.addItem(item)
            }
        }

        menu.addItem(.separator())
        menu.addItem(action("立即刷新", #selector(refresh), key: "r"))
        if !defaults.bool(forKey: "BluetoothEnabled") || bluetooth.authorization == .notDetermined {
            menu.addItem(action("启用蓝牙电量读取…", #selector(enableBluetooth)))
        } else if [.denied, .restricted].contains(bluetooth.authorization) {
            menu.addItem(action("蓝牙访问设置…", #selector(openBluetoothSettings)))
        } else if bluetooth.state == .poweredOff {
            menu.addItem(info("蓝牙已关闭"))
        }

        let thresholdItem = NSMenuItem(title: "低电量阈值 · \(threshold)%", action: nil, keyEquivalent: "")
        let options = NSMenu()
        for percent in Self.thresholds {
            let item = action("\(percent)%", #selector(setThreshold(_:)))
            item.tag = percent
            item.state = percent == threshold ? .on : .off
            options.addItem(item)
        }
        thresholdItem.submenu = options
        menu.addItem(thresholdItem)
        if notificationStatus == .notDetermined {
            menu.addItem(action("启用低电量通知…", #selector(enableNotifications)))
        } else if notificationStatus == .denied {
            menu.addItem(action("打开通知设置…", #selector(openNotificationSettings)))
        }
        menu.addItem(action("发送测试通知", #selector(testNotification)))

        menu.addItem(.separator())
        let status = loginItem.status
        let startup = action("开机自启动", #selector(toggleLaunchAtLogin))
        switch status {
        case .enabled: startup.state = .on
        case .requiresApproval: startup.state = .mixed
        default: startup.state = .off
        }
        menu.addItem(startup)
        if status == .requiresApproval {
            menu.addItem(action("在系统设置中允许自启动…", #selector(openLoginItemSettings)))
        }
        menu.addItem(.separator())
        menu.addItem(action("退出外设电量", #selector(quit), key: "q"))
    }

    private func info(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func action(_ title: String, _ selector: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: key)
        item.target = self
        return item
    }

    @objc private func quit() { NSApp.terminate(nil) }

    @objc private func toggleLaunchAtLogin() {
        do {
            switch loginItem.status {
            case .enabled, .requiresApproval:
                try loginItem.unregister()
            default:
                try loginItem.register()
                if loginItem.status == .requiresApproval { openLoginItemSettings() }
            }
        } catch {
            Self.logger.error("Login item update failed: \(error.localizedDescription, privacy: .public)")
            let alert = NSAlert()
            alert.messageText = "无法更改开机自启动设置"
            alert.informativeText = error.localizedDescription
            alert.addButton(withTitle: "好")
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }

    @objc private func openLoginItemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    @objc private func setThreshold(_ item: NSMenuItem) {
        guard Self.thresholds.contains(item.tag), item.tag != threshold else { return }
        threshold = item.tag
        defaults.set(threshold, forKey: "LowBatteryThreshold")
        updateDevices()
    }

    @objc private func enableBluetooth() {
        defaults.set(true, forKey: "BluetoothEnabled")
        bluetooth.start()
        refresh()
    }

    @objc private func openBluetoothSettings() {
        openSettings("com.apple.preference.security?Privacy_Bluetooth")
    }

    @objc private func openNotificationSettings() {
        openSettings("com.apple.Notifications-Settings.extension")
    }

    private func openSettings(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:\(pane)") { NSWorkspace.shared.open(url) }
    }

    @objc private func enableNotifications() {
        Task { await requestNotifications() }
    }

    @objc private func testNotification() {
        Task {
            await requestNotifications()
            if notificationStatus == .denied {
                openNotificationSettings()
            } else if canSendNotifications {
                await post(title: "外设电量 · 测试通知", body: "设备电量降至 \(threshold)% 或以下时会提醒你。")
            }
        }
    }

    private func requestNotifications() async {
        await updateNotificationStatus()
        if notificationStatus == .notDetermined {
            do {
                _ = try await center.requestAuthorization(options: [.alert, .sound])
            } catch {
                Self.logger.error("Notification permission failed: \(error.localizedDescription, privacy: .public)")
            }
            await updateNotificationStatus()
        }
    }

    private var canSendNotifications: Bool {
        notificationStatus == .authorized || notificationStatus == .provisional
    }

    private func updateNotificationStatus() async {
        notificationStatus = await center.notificationSettings().authorizationStatus
        checkForLowBattery()
    }

    private func checkForLowBattery() {
        guard !sendingAlert else { return }
        let events = alerts.pending(in: devices, threshold: threshold)
        saveAlertState()
        guard canSendNotifications, !events.isEmpty else { return }
        sendingAlert = true
        Task {
            for event in events {
                if await post(title: "外设电量低", body: event.message) {
                    alerts.markSent(event)
                    saveAlertState()
                }
            }
            sendingAlert = false
        }
    }

    private func saveAlertState() {
        let keys = alerts.sent.sorted()
        if (defaults.stringArray(forKey: "SentLowBatteryAlerts") ?? []) != keys {
            defaults.set(keys, forKey: "SentLowBatteryAlerts")
        }
    }

    @discardableResult
    private func post(title: String, body: String) async -> Bool {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        do {
            try await center.add(request)
            return true
        } catch {
            Self.logger.error("Notification delivery failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
    }
}
