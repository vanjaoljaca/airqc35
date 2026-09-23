struct Settings: Codable {
    var preferredInput = "MacBook Pro Microphone"
    var fallbackInput = "MacBook Pro Microphone"
    var headsetName = "Bose QC35 II"
    var releaseOnSleep = true
    var avoidHeadsetMic = true

    enum CodingKeys: String, CodingKey {
        case preferredInput, fallbackInput, headsetName, releaseOnSleep, avoidHeadsetMic
    }

    init() {}

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        preferredInput = try values.decode(String.self, forKey: .preferredInput)
        fallbackInput = try values.decode(String.self, forKey: .fallbackInput)
        headsetName = try values.decode(String.self, forKey: .headsetName)
        releaseOnSleep = try values.decodeIfPresent(Bool.self, forKey: .releaseOnSleep) ?? true
        avoidHeadsetMic = try values.decodeIfPresent(Bool.self, forKey: .avoidHeadsetMic) ?? true
    }
}

struct Device: Codable {
    let id: AudioDeviceID
    let name: String
    let input: Bool
    let alive: Bool
}

struct AudioFailure: Error, CustomStringConvertible {
    let description: String
}

let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/QC35InputGuard")
let configURL = root.appendingPathComponent("config.json")
let system = AudioObjectID(kAudioObjectSystemObject)

func address(_ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
}

func check(_ status: OSStatus, _ operation: String) throws {
    if status != noErr { throw AudioFailure(description: "\(operation): OSStatus \(status)") }
}

func number(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) throws -> UInt32 {
    var property = address(selector)
    var value: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    try check(AudioObjectGetPropertyData(object, &property, 0, nil, &size, &value), "read \(selector)")
    return value
}

func deviceName(_ id: AudioDeviceID) throws -> String {
    var property = address(kAudioObjectPropertyName)
    var value: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    try check(AudioObjectGetPropertyData(id, &property, 0, nil, &size, &value), "device name")
    guard let value else { throw AudioFailure(description: "Missing device name") }
    return value.takeRetainedValue() as String
}

func hasInput(_ id: AudioDeviceID) throws -> Bool {
    var property = address(kAudioDevicePropertyStreams, kAudioDevicePropertyScopeInput)
    var size: UInt32 = 0
    try check(AudioObjectGetPropertyDataSize(id, &property, 0, nil, &size), "input streams")
    return size > 0
}

func devices() throws -> [Device] {
    var property = address(kAudioHardwarePropertyDevices)
    var size: UInt32 = 0
    try check(AudioObjectGetPropertyDataSize(system, &property, 0, nil, &size), "device list size")
    var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
    try check(AudioObjectGetPropertyData(system, &property, 0, nil, &size, &ids), "device list")
    return try ids.map { Device(id: $0, name: try deviceName($0), input: try hasInput($0), alive: try number($0, kAudioDevicePropertyDeviceIsAlive) != 0) }
}

// This is the only audio write in the executable. No output property is ever written.
func setInput(_ id: AudioDeviceID) throws {
    var property = address(kAudioHardwarePropertyDefaultInputDevice)
    var value = id
    try check(AudioObjectSetPropertyData(system, &property, 0, nil, UInt32(MemoryLayout.size(ofValue: value)), &value), "set default input")
}

func settings() throws -> Settings {
    try JSONDecoder().decode(Settings.self, from: Data(contentsOf: configURL))
}

func save(_ value: Settings, to url: URL = configURL) throws {
    let data = try JSONEncoder().encode(value)
    guard let changes = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw AudioFailure(description: "Encoded settings must be an object")
    }
    try patchSettings(changes, at: url)
}

func patchSettings(_ changes: [String: Any], at url: URL = configURL) throws {
    let original = try Data(contentsOf: url)
    guard var values = try JSONSerialization.jsonObject(with: original) as? [String: Any] else {
        throw AudioFailure(description: "Configuration must be an object")
    }
    values.merge(changes) { _, new in new }
    let data = try JSONSerialization.data(withJSONObject: values, options: [.prettyPrinted, .sortedKeys])
    _ = try JSONDecoder().decode(Settings.self, from: data)
    try data.write(to: url, options: .atomic)
}

func log(_ event: String, _ fields: [String: String] = [:]) {
    var record = fields
    record.merge(["event": event, "time": ISO8601DateFormatter().string(from: Date()), "pid": String(getpid()), "service": "com.vanja.qc35.inputguard", "revision": "3", "runtimeRoot": root.path]) { _, new in new }
    do { try appendLog(JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]) + Data([10])) }
    catch { fputs("QC35InputGuard logging failed: \(error)\n", stderr); exit(1) }
}

func appendLog(_ data: Data) throws {
    let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/QC35InputGuard/events.jsonl")
    if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 1_048_576 {
        let previous = url.appendingPathExtension("previous")
        if FileManager.default.fileExists(atPath: previous.path) { try FileManager.default.removeItem(at: previous) }
        try FileManager.default.moveItem(at: url, to: previous)
    }
    if !FileManager.default.fileExists(atPath: url.path) { try Data().write(to: url) }
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    try handle.seekToEnd()
    try handle.write(contentsOf: data)
}

final class Guard {
    let availability = AvailabilityMonitor()
    var lastState = ""
    var failures = 0
    var retry: DispatchWorkItem?
    var configWatch: DispatchSourceFileSystemObject?
    var observed: [AudioDeviceID: AudioObjectPropertyListenerBlock] = [:]

    func start() throws {
        try listen(kAudioHardwarePropertyDevices)
        try listen(kAudioHardwarePropertyDefaultInputDevice)
        try listen(kAudioHardwarePropertyServiceRestarted)
        try watchConfig()
        availability.start()
        log("started")
        reconcile()
        RunLoop.main.run()
    }

    func listen(_ selector: AudioObjectPropertySelector) throws {
        var property = address(selector)
        try check(AudioObjectAddPropertyListenerBlock(system, &property, .main) { [self] _, _ in
            if selector == kAudioHardwarePropertyServiceRestarted { log("coreaudio_restarted"); exit(1) }
            reconcile()
        }, "register system listener")
    }

    func watchConfig() throws {
        let descriptor = open(root.path, O_EVTONLY)
        guard descriptor >= 0 else { throw AudioFailure(description: "Cannot watch configuration directory") }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write, .rename, .delete], queue: .main)
        source.setEventHandler { [self] in availability.configurationChanged(); reconcile() }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        configWatch = source
    }

    func reconcile() {
        retry?.cancel()
        do {
            let all = try devices()
            try observe(all)
            try restore(all, settings())
            failures = 0
        } catch { recover(error) }
    }

    func observe(_ all: [Device]) throws {
        let present = Set(all.map(\.id))
        for id in Array(observed.keys) where !present.contains(id) {
            var property = address(kAudioObjectPropertySelectorWildcard, kAudioObjectPropertyScopeWildcard)
            _ = AudioObjectRemovePropertyListenerBlock(id, &property, .main, observed.removeValue(forKey: id)!)
        }
        for id in present where observed[id] == nil {
            var property = address(kAudioObjectPropertySelectorWildcard, kAudioObjectPropertyScopeWildcard)
            let block: AudioObjectPropertyListenerBlock = { [self] _, _ in reconcile() }
            try check(AudioObjectAddPropertyListenerBlock(id, &property, .main, block), "register device listener")
            observed[id] = block
        }
    }

    func restore(_ all: [Device], _ config: Settings) throws {
        try restoreMicrophone(all, config, apply: apply, state: state)
    }

    func apply(_ target: Device, _ fallback: Bool) throws {
        let current = try number(system, kAudioHardwarePropertyDefaultInputDevice)
        if current != target.id {
            let output = try number(system, kAudioHardwarePropertyDefaultOutputDevice)
            try setInput(target.id)
            log("input_restored", ["input": target.name, "previousInputID": String(current), "outputBeforeID": String(output), "outputAfterID": String(try number(system, kAudioHardwarePropertyDefaultOutputDevice))])
        }
        state(fallback ? "fallback_active" : "preferred_active", target.name)
    }

    func state(_ value: String, _ input: String = "") {
        let key = value + input
        guard key != lastState else { return }
        lastState = key
        log(value, ["input": input])
    }

    func recover(_ error: Error) {
        failures += 1
        if failures == 1 { log("audio_error", ["error": String(describing: error)]) }
        if failures >= 5 { log("restart_required"); exit(1) }
        let work = DispatchWorkItem { [self] in reconcile() }
        retry = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }
}

func restoreMicrophone(_ all: [Device], _ config: Settings,
                       apply: (Device, Bool) throws -> Void, state: (String, String) -> Void) throws {
    guard config.avoidHeadsetMic else { state("mic_guard_disabled", ""); return }
    let connected = all.contains { $0.alive && $0.name == config.headsetName }
    guard connected else { state("headset_absent", ""); return }
    let safe = all.filter { $0.input && $0.alive && $0.name != config.headsetName }
    let preferred = safe.filter { $0.name == config.preferredInput }
    let candidates = preferred.isEmpty ? safe.filter { $0.name == config.fallbackInput } : preferred
    guard candidates.count == 1, let target = candidates.first else { state("no_unique_safe_input", ""); return }
    try apply(target, preferred.isEmpty)
}

struct MacAvailability: Equatable {
    var lidClosed: Bool?
    var displaysAsleep: Bool?
    var systemSleeping = false
    var unavailable: Bool { lidClosed == true || displaysAsleep == true || systemSleeping }

    var fields: [String: String] {
        ["lidClosed": lidClosed.map(String.init) ?? "unknown",
         "displaysAsleep": displaysAsleep.map(String.init) ?? "unknown",
         "systemSleeping": String(systemSleeping), "unavailable": String(unavailable)]
    }
}

protocol HeadsetConnection: AnyObject {
    var identifier: String { get }
    var connected: Bool { get }
    func disconnect() -> IOReturn
}

final class NativeHeadset: HeadsetConnection {
    let device: IOBluetoothDevice
    init(_ device: IOBluetoothDevice) { self.device = device }
    var identifier: String { device.addressString }
    var connected: Bool { device.isConnected() }
    func disconnect() -> IOReturn { device.closeConnection() }
}

func resolveHeadset() throws -> HeadsetConnection? {
    let name = try settings().headsetName
    let paired = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] ?? []
    let matches = paired.filter { $0.name == name }
    guard matches.count <= 1 else { throw AudioFailure(description: "Ambiguous paired headset: \(name)") }
    return matches.first.map(NativeHeadset.init)
}

// All state is owned by the main run loop. There is deliberately no connect API.
final class ConnectionRelease {
    var availability = MacAvailability()
    var refreshBeforeRetry: () -> Void = {}
    let resolve: () throws -> HeadsetConnection?
    let schedule: (@escaping () -> Void) -> DispatchWorkItem
    let emit: (String, [String: String]) -> Void
    private var generation = 0
    private var pending: DispatchWorkItem?
    private var releasing = false
    private var enabled = true
    private var headsetName = Settings().headsetName

    init(resolve: @escaping () throws -> HeadsetConnection? = resolveHeadset,
         schedule: @escaping (@escaping () -> Void) -> DispatchWorkItem = scheduleReleaseRetry,
         emit: @escaping (String, [String: String]) -> Void = log) {
        self.resolve = resolve
        self.schedule = schedule
        self.emit = emit
    }

    func update(_ state: MacAvailability, reason: String) {
        let wasUnavailable = availability.unavailable
        guard state != availability else { return }
        availability = state
        emit("availability_changed", state.fields.merging(["reason": reason]) { _, new in new })
        if !state.unavailable || !enabled { cancel(); return }
        if !wasUnavailable { begin(reason: reason) }
    }

    func connected(_ identifier: String) {
        guard enabled, availability.unavailable, !releasing, pending == nil else { return }
        do {
            guard let target = try resolve(), target.identifier == identifier else { return }
            begin(reason: "incoming_connection")
        } catch { emit("release_resolution_failed", ["error": String(describing: error)]) }
    }

    func configurationChanged(_ config: Settings) {
        guard enabled != config.releaseOnSleep || headsetName != config.headsetName else { return }
        enabled = config.releaseOnSleep
        headsetName = config.headsetName
        emit("release_options_changed", ["enabled": String(enabled), "headsetName": headsetName])
        cancel()
        if enabled && availability.unavailable { begin(reason: "configuration_changed") }
    }

    private func begin(reason: String) {
        cancel()
        attempt(reason: reason, expectedAddress: nil, attemptNumber: 1, token: generation)
    }

    private func cancel() {
        generation += 1
        pending?.cancel()
        pending = nil
    }

    private func attempt(reason: String, expectedAddress: String?, attemptNumber: Int, token: Int) {
        guard token == generation, enabled, availability.unavailable else { return }
        do {
            guard let target = try resolve() else { emit("release_headset_not_paired", [:]); return }
            guard expectedAddress == nil || expectedAddress == target.identifier else { return }
            guard target.connected else { emit("release_already_disconnected", ["address": target.identifier]); return }
            close(target, reason: reason, attemptNumber: attemptNumber, token: token)
        } catch { emit("release_resolution_failed", ["error": String(describing: error)]) }
    }

    private func close(_ target: HeadsetConnection, reason: String, attemptNumber: Int, token: Int) {
        releasing = true
        let status = target.disconnect()
        let stillConnected = target.connected
        releasing = false
        emit(stillConnected ? "release_not_confirmed" : "release_verified", [
            "address": target.identifier, "reason": reason, "attempt": String(attemptNumber),
            "status": String(status), "connectedAfter": String(stillConnected)])
        guard stillConnected, token == generation else { return }
        retry(target.identifier, reason: reason, attemptNumber: attemptNumber, token: token)
    }

    private func retry(_ identifier: String, reason: String, attemptNumber: Int, token: Int) {
        guard attemptNumber < 3 else {
            emit("release_exhausted", ["address": identifier, "attempts": String(attemptNumber)])
            return
        }
        pending = schedule { [weak self] in
            guard let self, token == self.generation else { return }
            self.pending = nil
            self.refreshBeforeRetry()
            self.attempt(reason: reason, expectedAddress: identifier, attemptNumber: attemptNumber + 1, token: token)
        }
    }
}

func scheduleReleaseRetry(_ action: @escaping () -> Void) -> DispatchWorkItem {
    let work = DispatchWorkItem(block: action)
    DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    return work
}

func readLidClosed() throws -> Bool? {
    let entry = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
    guard entry != 0 else { throw AudioFailure(description: "IOPMrootDomain unavailable") }
    defer { IOObjectRelease(entry) }
    return IORegistryEntryCreateCFProperty(entry, kAppleClamshellStateKey as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Bool
}

func readDisplaysAsleep() throws -> Bool? {
    var count: UInt32 = 0
    guard CGGetOnlineDisplayList(0, nil, &count) == .success else { throw AudioFailure(description: "Display count unavailable") }
    guard count > 0 else { return nil }
    var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
    guard CGGetOnlineDisplayList(count, &displays, &count) == .success else { throw AudioFailure(description: "Display list unavailable") }
    guard count > 0 else { return nil }
    return displays.prefix(Int(count)).allSatisfy { CGDisplayIsAsleep($0) != 0 }
}

final class AvailabilityMonitor: NSObject {
    let release = ConnectionRelease()
    private var state = MacAvailability()
    private var workspaceObservers: [NSObjectProtocol] = []
    private var bluetoothObserver: IOBluetoothUserNotification?
    private var lidPort: IONotificationPortRef?
    private var lidObserver: io_object_t = 0

    func start() {
        registerWorkspace()
        registerLid()
        bluetoothObserver = IOBluetoothDevice.register(forConnectNotifications: self, selector: #selector(didConnect(_:device:)))
        if bluetoothObserver == nil { log("connection_listener_failed") }
        release.refreshBeforeRetry = { [weak self] in self?.refresh(reason: "retry_snapshot") }
        configurationChanged()
        refresh(reason: "startup")
        log("release_started", state.fields)
    }

    private func registerWorkspace() {
        let center = NSWorkspace.shared.notificationCenter
        let names = [NSWorkspace.screensDidSleepNotification, NSWorkspace.screensDidWakeNotification,
                     NSWorkspace.willSleepNotification, NSWorkspace.didWakeNotification]
        workspaceObservers = names.map { name in
            center.addObserver(forName: name, object: nil, queue: nil) { [weak self] notification in
                if Thread.isMainThread { self?.workspaceChanged(notification.name) }
                else { DispatchQueue.main.sync { self?.workspaceChanged(notification.name) } }
            }
        }
    }

    private func registerLid() {
        let entry = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard entry != 0 else { log("lid_listener_failed"); return }
        defer { IOObjectRelease(entry) }
        guard let port = IONotificationPortCreate(kIOMainPortDefault) else { log("lid_listener_failed"); return }
        lidPort = port
        IONotificationPortSetDispatchQueue(port, .main)
        let status = IOServiceAddInterestNotification(port, entry, kIOGeneralInterest, lidChanged,
            Unmanaged.passUnretained(self).toOpaque(), &lidObserver)
        if status != KERN_SUCCESS { log("lid_listener_failed", ["status": String(status)]) }
    }

    func acceptLid(_ closed: Bool) {
        state.lidClosed = closed
        release.update(state, reason: "lid_changed")
    }

    private func workspaceChanged(_ name: Notification.Name) {
        switch name {
        case NSWorkspace.screensDidSleepNotification: state.displaysAsleep = true
        case NSWorkspace.screensDidWakeNotification: state.displaysAsleep = false
        case NSWorkspace.willSleepNotification: state.systemSleeping = true
        case NSWorkspace.didWakeNotification: state.systemSleeping = false; refresh(reason: "system_wake"); return
        default: return
        }
        sampleLid()
        release.update(state, reason: name.rawValue)
    }

    @objc private func didConnect(_ notification: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        let identifier = device.addressString ?? ""
        if Thread.isMainThread { incoming(identifier) }
        else { DispatchQueue.main.async { [weak self] in self?.incoming(identifier) } }
    }

    private func incoming(_ identifier: String) {
        // Refresh the lid without erasing an authoritative screensDidSleep event.
        sampleLid()
        release.update(state, reason: "connection_snapshot")
        release.connected(identifier)
    }

    func configurationChanged() {
        do {
            release.configurationChanged(try settings())
        } catch { log("release_config_failed", ["error": String(describing: error)]) }
    }

    private func refresh(reason: String) {
        sampleLid()
        do { state.displaysAsleep = try readDisplaysAsleep() }
        catch { log("display_snapshot_failed", ["error": String(describing: error)]) }
        release.update(state, reason: reason)
    }

    private func sampleLid() {
        do { state.lidClosed = try readLidClosed() }
        catch { log("lid_snapshot_failed", ["error": String(describing: error)]) }
    }

    deinit {
        workspaceObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        bluetoothObserver?.unregister()
        if lidObserver != 0 { IOObjectRelease(lidObserver) }
        if let lidPort { IONotificationPortDestroy(lidPort) }
    }
}

func lidChanged(_ context: UnsafeMutableRawPointer?, _ service: io_service_t, _ message: UInt32, _ argument: UnsafeMutableRawPointer?) {
    // IOPM.h's C macro is not imported by Swift: sys_iokit | err_sub(13) | 0x100.
    let clamshellStateChange: UInt32 = 0xe0000000 | (13 << 14) | 0x100
    guard message == clamshellStateChange, let context else { return }
    let monitor = Unmanaged<AvailabilityMonitor>.fromOpaque(context).takeUnretainedValue()
    monitor.acceptLid(UInt(bitPattern: argument) & UInt(kClamshellStateBit) != 0)
}


func runCommand() throws {
    let args = Array(CommandLine.arguments.dropFirst())
    switch args.first ?? "watch" {
    case "watch": try Guard().start()
    case "status": try printStatus()
    case "prefer": try changePreference(Array(args.dropFirst()))
    case "option": try changeOption(Array(args.dropFirst()))
    default: throw AudioFailure(description: "Usage: QC35InputGuard [watch|status|prefer \"Microphone name\"|option releaseOnSleep|avoidHeadsetMic true|false]")
    }
}

func printStatus() throws {
    let config = try settings()
    let data: [String: Any] = ["preferredInput": config.preferredInput, "releaseOnSleep": config.releaseOnSleep, "avoidHeadsetMic": config.avoidHeadsetMic, "defaultInput": try deviceName(number(system, kAudioHardwarePropertyDefaultInputDevice)), "defaultOutput": try deviceName(number(system, kAudioHardwarePropertyDefaultOutputDevice)), "inputs": try devices().filter { $0.input && $0.alive }.map(\.name), "releaseSnapshot": try releaseSnapshot()]
    print(String(decoding: try JSONSerialization.data(withJSONObject: data, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self))
}

func releaseSnapshot() throws -> [String: String] {
    let target = try resolveHeadset()
    var fields = MacAvailability(lidClosed: try readLidClosed(), displaysAsleep: try readDisplaysAsleep()).fields
    fields["address"] = target?.identifier ?? "not_paired"
    fields["connected"] = target.map { String($0.connected) } ?? "false"
    fields["automaticReconnect"] = "false"
    return fields
}

func changePreference(_ args: [String]) throws {
    guard args.count == 1, !args[0].isEmpty else { throw AudioFailure(description: "Supply one exact input device name") }
    let config = try settings()
    guard args[0] != config.headsetName else { throw AudioFailure(description: "The Bose microphone cannot be the preferred input") }
    try patchSettings(["preferredInput": args[0]])
    print("Preferred input saved: \(args[0])")
}

func optionChange(_ args: [String]) throws -> [String: Any] {
    guard args.count == 2, ["releaseOnSleep", "avoidHeadsetMic"].contains(args[0]),
          args[1] == "true" || args[1] == "false" else {
        throw AudioFailure(description: "Supply option releaseOnSleep|avoidHeadsetMic true|false")
    }
    return [args[0]: args[1] == "true"]
}

func changeOption(_ args: [String], at url: URL = configURL) throws {
    try patchSettings(optionChange(args), at: url)
    print("Option saved: \(args[0])=\(args[1])")
}

#if QC35_TEST
runReleaseTests()
#else
do { try runCommand() }
catch { fputs("QC35InputGuard: \(error)\n", stderr); exit(1) }
#endif

import Foundation
import CoreAudio
import Darwin
import AppKit
import IOBluetooth
import IOKit.pwr_mgt
import CoreGraphics
