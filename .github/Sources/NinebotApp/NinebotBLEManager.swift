//
//  NinebotBLEManager.swift
//  Basis CoreBluetooth-connector voor Segway-Ninebot steps (o.a. E2 Pro)
//
//  BELANGRIJK:
//  - Dit regelt scannen, verbinden en het ontdekken van de UART service/characteristics.
//  - Nieuwere Ninebot-modellen (incl. E2 Pro) gebruiken een versleuteld protocol
//    ("miauth"). Zonder die encryptielaag krijg je GEEN leesbare telemetrie terug,
//    enkel een ruwe (versleutelde) bytestream. Zie community-referenties onderaan.
//  - Voeg in je Xcode project aan Info.plist toe:
//      NSBluetoothAlwaysUsageDescription
//      (tekst, bv. "Nodig om met je step te verbinden via Bluetooth")
//
//  Referenties voor het protocol (community reverse-engineering, geen officiële Segway-bron):
//  - https://github.com/ownbee/ninebot-ble   (Python client incl. miauth crypto)
//  - https://codeberg.org/NootNooot/segway-ninebot-ble-cli
//  - https://github.com/CamiAlfa/M365-BLE-PROTOCOL
//

import Foundation
import CoreBluetooth

// MARK: - Ninebot UART Service/Characteristic UUIDs
// Deze UUID's komen uit community reverse-engineering van de Ninebot BLE UART service.
enum NinebotBLE {
    static let uartServiceUUID = CBUUID(string: "6E400001-B5A3-F393-E0A9-E50E24DCCA9E")
    static let writeCharUUID   = CBUUID(string: "6E400002-B5A3-F393-E0A9-E50E24DCCA9E") // phone -> scooter
    static let notifyCharUUID  = CBUUID(string: "6E400003-B5A3-F393-E0A9-E50E24DCCA9E") // scooter -> phone
}

protocol NinebotBLEManagerDelegate: AnyObject {
    func ninebotManager(_ manager: NinebotBLEManager, didDiscover peripheral: CBPeripheral, rssi: NSNumber)
    func ninebotManager(_ manager: NinebotBLEManager, didConnect peripheral: CBPeripheral)
    func ninebotManager(_ manager: NinebotBLEManager, didDisconnect peripheral: CBPeripheral, error: Error?)
    func ninebotManager(_ manager: NinebotBLEManager, didReceiveRawData data: Data)
    func ninebotManager(_ manager: NinebotBLEManager, didFailWithError error: Error)
}

final class NinebotBLEManager: NSObject {

    weak var delegate: NinebotBLEManagerDelegate?

    private var centralManager: CBCentralManager!
    private var scooterPeripheral: CBPeripheral?
    private var writeCharacteristic: CBCharacteristic?
    private var notifyCharacteristic: CBCharacteristic?

    /// Zet op true om alle BLE-toestellen te tonen ipv enkel toestellen met de Ninebot UART service.
    /// Handig bij eerste keer troubleshooten (sommige firmwares adverteren de service niet altijd).
    var scanForAllDevices = false

    /// Vuurt zodra zowel de write- als notify-characteristic effectief gevonden zijn —
    /// pas dan heeft sendRaw() zin. Gebruik dit i.p.v. te gokken met een vaste delay
    /// na didConnect (discovery is async en de duur ervan is niet gegarandeerd).
    var onCharacteristicsReady: (() -> Void)?

    override init() {
        super.init()
        centralManager = CBCentralManager(delegate: self, queue: nil)
    }

    // MARK: - Public API

    func startScanning() {
        guard centralManager.state == .poweredOn else {
            print("Bluetooth is niet aan of niet beschikbaar (state: \(centralManager.state.rawValue))")
            return
        }
        let services = scanForAllDevices ? nil : [NinebotBLE.uartServiceUUID]
        centralManager.scanForPeripherals(withServices: services, options: [
            CBCentralManagerScanOptionAllowDuplicatesKey: false
        ])
    }

    func stopScanning() {
        centralManager.stopScan()
    }

    func connect(to peripheral: CBPeripheral) {
        stopScanning()
        scooterPeripheral = peripheral
        peripheral.delegate = self
        centralManager.connect(peripheral, options: nil)
    }

    func disconnect() {
        guard let peripheral = scooterPeripheral else { return }
        centralManager.cancelPeripheralConnection(peripheral)
    }

    /// Stuur ruwe bytes naar de step. Voor echte commando's moet dit een correct
    /// opgebouwd Ninebot-protocolframe zijn (headers, checksum, evt. encryptie).
    func sendRaw(_ data: Data) {
        guard let peripheral = scooterPeripheral,
              let characteristic = writeCharacteristic else {
            print("Nog niet verbonden of write characteristic niet gevonden")
            return
        }
        let type: CBCharacteristicWriteType = characteristic.properties.contains(.writeWithoutResponse)
            ? .withoutResponse : .withResponse
        peripheral.writeValue(data, for: characteristic, type: type)
    }
}

// MARK: - CBCentralManagerDelegate

extension NinebotBLEManager: CBCentralManagerDelegate {

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            print("Bluetooth staat aan")
        case .poweredOff:
            print("Bluetooth staat uit — zet het aan in Instellingen")
        case .unauthorized:
            print("App heeft geen Bluetooth-toestemming")
        default:
            print("Bluetooth state: \(central.state.rawValue)")
        }
    }

    func centralManager(_ central: CBCentralManager,
                         didDiscover peripheral: CBPeripheral,
                         advertisementData: [String: Any],
                         rssi RSSI: NSNumber) {
        delegate?.ninebotManager(self, didDiscover: peripheral, rssi: RSSI)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.discoverServices([NinebotBLE.uartServiceUUID])
        delegate?.ninebotManager(self, didConnect: peripheral)
    }

    func centralManager(_ central: CBCentralManager,
                         didFailToConnect peripheral: CBPeripheral,
                         error: Error?) {
        if let error = error {
            delegate?.ninebotManager(self, didFailWithError: error)
        }
    }

    func centralManager(_ central: CBCentralManager,
                         didDisconnectPeripheral peripheral: CBPeripheral,
                         error: Error?) {
        delegate?.ninebotManager(self, didDisconnect: peripheral, error: error)
    }
}

// MARK: - CBPeripheralDelegate

extension NinebotBLEManager: CBPeripheralDelegate {

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error = error {
            delegate?.ninebotManager(self, didFailWithError: error)
            return
        }
        guard let services = peripheral.services else { return }
        for service in services where service.uuid == NinebotBLE.uartServiceUUID {
            peripheral.discoverCharacteristics(
                [NinebotBLE.writeCharUUID, NinebotBLE.notifyCharUUID],
                for: service
            )
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                     didDiscoverCharacteristicsFor service: CBService,
                     error: Error?) {
        if let error = error {
            delegate?.ninebotManager(self, didFailWithError: error)
            return
        }
        guard let characteristics = service.characteristics else { return }
        for characteristic in characteristics {
            switch characteristic.uuid {
            case NinebotBLE.writeCharUUID:
                writeCharacteristic = characteristic
            case NinebotBLE.notifyCharUUID:
                notifyCharacteristic = characteristic
                peripheral.setNotifyValue(true, for: characteristic)
            default:
                break
            }
        }
        if writeCharacteristic != nil && notifyCharacteristic != nil {
            onCharacteristicsReady?()
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                     didUpdateValueFor characteristic: CBCharacteristic,
                     error: Error?) {
        if let error = error {
            delegate?.ninebotManager(self, didFailWithError: error)
            return
        }
        guard characteristic.uuid == NinebotBLE.notifyCharUUID,
              let data = characteristic.value else { return }
        // Ruwe (mogelijk versleutelde) bytes van de step — decoding/decryptie is
        // hier nog niet geïmplementeerd, zie opmerking bovenaan het bestand.
        delegate?.ninebotManager(self, didReceiveRawData: data)
    }

    func peripheral(_ peripheral: CBPeripheral,
                     didWriteValueFor characteristic: CBCharacteristic,
                     error: Error?) {
        if let error = error {
            delegate?.ninebotManager(self, didFailWithError: error)
        }
    }
}
