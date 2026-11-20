import BatteryCore
import CoreBluetooth
import Foundation

@MainActor
final class BLEBattery: NSObject, @preconcurrency CBCentralManagerDelegate, @preconcurrency CBPeripheralDelegate {
    private struct Connection {
        let peripheral: CBPeripheral
        let started = Date()
        var characteristic: CBCharacteristic?
        var percent: Int?
        var updated: Date?
    }

    private let batteryService = CBUUID(string: "180F")
    private let batteryLevel = CBUUID(string: "2A19")
    private var central: CBCentralManager?
    private var connections: [UUID: Connection] = [:]
    var onChange: (() -> Void)?

    var authorization: CBManagerAuthorization { CBManager.authorization }
    var state: CBManagerState? { central?.state }

    var devices: [DeviceBattery] {
        connections.values.compactMap { connection in
            guard let percent = connection.percent, let updated = connection.updated,
                  Date().timeIntervalSince(updated) <= 150 else { return nil }
            return DeviceBattery(
                id: "ble:\(connection.peripheral.identifier.uuidString)",
                name: connection.peripheral.name ?? "蓝牙外设", transport: .bluetooth, levels: [.main: percent]
            )
        }
    }

    func start() {
        guard central == nil else { return }
        central = CBCentralManager(delegate: self, queue: nil, options: [CBCentralManagerOptionShowPowerAlertKey: false])
    }

    func refresh() {
        guard let central, central.state == .poweredOn else { return }
        let peripherals = central.retrieveConnectedPeripherals(withServices: [batteryService])
        let connected = Set(peripherals.map(\.identifier))
        for id in Array(connections.keys) {
            guard let connection = connections[id] else { continue }
            let expired = connection.characteristic == nil && Date().timeIntervalSince(connection.started) > 25
            if !connected.contains(id) || expired {
                connections.removeValue(forKey: id)
                central.cancelPeripheralConnection(connection.peripheral)
            }
        }
        for peripheral in peripherals {
            let id = peripheral.identifier
            if let connection = connections[id] {
                if let characteristic = connection.characteristic {
                    connection.peripheral.readValue(for: characteristic)
                }
            } else if peripheral.state != .disconnecting {
                peripheral.delegate = self
                connections[id] = Connection(peripheral: peripheral)
                central.connect(peripheral)
            }
        }
        onChange?()
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state == .poweredOn {
            refresh()
        } else {
            connections.removeAll()
            onChange?()
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard connections[peripheral.identifier]?.peripheral === peripheral else { return }
        peripheral.discoverServices([batteryService])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        connections.removeValue(forKey: peripheral.identifier)
        onChange?()
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        connections.removeValue(forKey: peripheral.identifier)
        onChange?()
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard error == nil, let service = peripheral.services?.first(where: { $0.uuid == batteryService }) else { return }
        peripheral.discoverCharacteristics([batteryLevel], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard error == nil,
              let characteristic = service.characteristics?.first(where: { $0.uuid == batteryLevel }),
              connections[peripheral.identifier] != nil else { return }
        connections[peripheral.identifier]?.characteristic = characteristic
        peripheral.readValue(for: characteristic)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard error == nil, characteristic.uuid == batteryLevel,
              let bytes = characteristic.value, bytes.count == 1, let percent = bytes.first, percent <= 100,
              connections[peripheral.identifier] != nil else { return }
        connections[peripheral.identifier]?.percent = Int(percent)
        connections[peripheral.identifier]?.updated = Date()
        onChange?()
    }
}
