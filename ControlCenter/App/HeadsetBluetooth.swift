struct HeadsetState: Identifiable, Equatable {
    let address: String
    let name: String
    let isConnected: Bool
    var id: String { address }
}

struct HeadsetBluetoothError: Error, LocalizedError {
    let code: String
    let detail: String
    var errorDescription: String? { detail }
}

enum HeadsetInventory {
    static func snapshot(_ devices: [HeadsetState], configuredName: String) throws -> [HeadsetState] {
        var unique: [String: HeadsetState] = [:]
        for device in devices where includes(device.name, configuredName: configuredName) {
            let normalized = HeadsetState(address: try normalize(device.address), name: device.name, isConnected: device.isConnected)
            guard unique[normalized.id] == nil || unique[normalized.id] == normalized else {
                throw HeadsetBluetoothError(code: "conflicting_device", detail: "Bluetooth returned conflicting headset information")
            }
            unique[normalized.id] = normalized
        }
        return unique.values.sorted { ($0.name.lowercased(), $0.id) < ($1.name.lowercased(), $1.id) }
    }

    static func includes(_ name: String, configuredName: String) -> Bool {
        if !configuredName.isEmpty, name == configuredName { return true }
        return name.range(of: #"(?:qc\s*35|quietcomfort\s*35)(?:\b|ii)"#,
            options: [.regularExpression, .caseInsensitive]) != nil
    }

    static func normalize(_ address: String) throws -> String {
        let parts = address.replacingOccurrences(of: "-", with: ":").split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 6, parts.allSatisfy({ $0.count == 2 && UInt8($0, radix: 16) != nil }) else {
            throw HeadsetBluetoothError(code: "invalid_address", detail: "Bluetooth returned an invalid headset address")
        }
        return parts.joined(separator: ":").uppercased()
    }

    static func requireAvailable(_ power: UInt32?) throws {
        guard let power else { throw HeadsetBluetoothError(code: "bluetooth_unavailable", detail: "Bluetooth is unavailable") }
        guard power != 0 else { throw HeadsetBluetoothError(code: "bluetooth_off", detail: "Bluetooth is off") }
        guard power == 1 else { throw HeadsetBluetoothError(code: "bluetooth_unavailable", detail: "Bluetooth is not ready") }
    }
}

// Each queued callback belongs to one active monitoring session, including cancelled work.
@MainActor
final class HeadsetEventDelivery {
    typealias Schedule = (@escaping () -> Void) -> DispatchWorkItem
    private let schedule: Schedule
    private var generation = 0
    private var callback: (() -> Void)?
    private var pending: DispatchWorkItem?

    init(schedule: @escaping Schedule = HeadsetEventDelivery.enqueue) { self.schedule = schedule }

    @discardableResult
    func start(_ callback: @escaping () -> Void) -> Int {
        stop()
        self.callback = callback
        return generation
    }

    func signal(_ token: Int) {
        guard token == generation, callback != nil, pending == nil else { return }
        pending = schedule { [weak self] in self?.deliver(token) }
    }

    private func deliver(_ token: Int) {
        guard token == generation, let callback else { return }
        pending = nil
        callback()
    }

    func stop() {
        generation += 1
        pending?.cancel()
        pending = nil
        callback = nil
    }

    nonisolated private static func enqueue(_ callback: @escaping () -> Void) -> DispatchWorkItem {
        let work = DispatchWorkItem(block: callback)
        DispatchQueue.main.async(execute: work)
        return work
    }

    deinit { pending?.cancel() }
}

@MainActor
final class HeadsetBluetooth: NSObject {
    var onChange: (() -> Void)?
    private var configuredName = ""
    private var running = false
    private var session = 0
    private let delivery = HeadsetEventDelivery()
    private var connection: IOBluetoothUserNotification?
    private var disconnections: [String: IOBluetoothUserNotification] = [:]
    private var notifications: [(NotificationCenter, NSObjectProtocol)] = []
    private let logger = Logger(subsystem: "com.vanja.qc35.control", category: "headset_inventory")

    func snapshot(configuredName: String) throws -> [HeadsetState] {
        self.configuredName = configuredName
        try HeadsetInventory.requireAvailable(IOBluetoothHostController.default().map { UInt32($0.powerState.rawValue) })
        let paired = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] ?? []
        let states = try HeadsetInventory.snapshot(paired.map(Self.describe), configuredName: configuredName)
        if running { try ensureConnectionObserver(); try observeDisconnections(paired, states: states) }
        return states
    }

    func start() {
        guard !running else { return }
        running = true
        session = delivery.start { [weak self] in self?.onChange?() }
        observeSystemChanges()
        do { try ensureConnectionObserver() }
        catch { record("monitor_failed", ["error": error.localizedDescription]); delivery.signal(session) }
        record("monitor_started")
    }

    func stop() {
        running = false
        delivery.stop()
        connection?.unregister(); connection = nil
        disconnections.values.forEach { $0.unregister() }; disconnections.removeAll()
        notifications.forEach { $0.0.removeObserver($0.1) }; notifications.removeAll()
    }

    private static func describe(_ device: IOBluetoothDevice) -> HeadsetState {
        HeadsetState(address: device.addressString ?? "", name: device.name ?? "", isConnected: device.isConnected())
    }

    private func ensureConnectionObserver() throws {
        guard connection == nil else { return }
        connection = IOBluetoothDevice.register(forConnectNotifications: self, selector: #selector(didConnect(_:device:)))
        guard connection != nil else {
            throw HeadsetBluetoothError(code: "monitor_unavailable", detail: "Bluetooth connection monitoring is unavailable")
        }
    }

    private func observeDisconnections(_ paired: [IOBluetoothDevice], states: [HeadsetState]) throws {
        let connected = Set(states.filter(\.isConnected).map(\.id))
        for id in Array(disconnections.keys) where !connected.contains(id) { disconnections.removeValue(forKey: id)?.unregister() }
        for device in paired {
            guard let id = try? HeadsetInventory.normalize(device.addressString ?? ""), connected.contains(id), disconnections[id] == nil else { continue }
            try addDisconnectionObserver(device, id: id)
        }
    }

    private func addDisconnectionObserver(_ device: IOBluetoothDevice, id: String) throws {
        guard let notification = device.register(forDisconnectNotification: self, selector: #selector(didDisconnect(_:device:))) else {
            throw HeadsetBluetoothError(code: "monitor_unavailable", detail: "Bluetooth disconnection monitoring is unavailable")
        }
        disconnections[id] = notification
    }

    @objc nonisolated private func didConnect(_ notification: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        DispatchQueue.main.async { [weak self] in self?.connected(notification, device: device) }
    }

    private func connected(_ notification: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        guard running, notification === connection,
              HeadsetInventory.includes(device.name ?? "", configuredName: configuredName) else { return }
        delivery.signal(session)
    }

    @objc nonisolated private func didDisconnect(_ notification: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        DispatchQueue.main.async { [weak self] in self?.disconnected(notification, device: device) }
    }

    private func disconnected(_ notification: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        guard running, let id = try? HeadsetInventory.normalize(device.addressString ?? ""),
              notification === disconnections[id] else { return }
        disconnections.removeValue(forKey: id)?.unregister()
        delivery.signal(session)
    }

    private func observeSystemChanges() {
        observe(.IOBluetoothHostControllerPoweredOn, center: .default)
        observe(.IOBluetoothHostControllerPoweredOff, center: .default)
        observe(NSWorkspace.didWakeNotification, center: NSWorkspace.shared.notificationCenter)
    }

    private func observe(_ name: Notification.Name, center: NotificationCenter) {
        let token = session
        let observer = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            DispatchQueue.main.async { [weak self] in self?.delivery.signal(token) }
        }
        notifications.append((center, observer))
    }

    private func record(_ event: String, _ fields: [String: String] = [:]) {
        let record = fields.merging(["event": event]) { _, new in new }
        let data = try! JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
        logger.info("\(String(decoding: data, as: UTF8.self), privacy: .public)")
    }

    deinit {
        connection?.unregister()
        disconnections.values.forEach { $0.unregister() }
        notifications.forEach { $0.0.removeObserver($0.1) }
    }
}

import Foundation
import AppKit
@preconcurrency import IOBluetooth
import OSLog
