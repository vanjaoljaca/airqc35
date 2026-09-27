@MainActor
final class MacConnection: NSObject {
    private var completion: ((Result<Void, Error>) -> Void)?
    private var device: IOBluetoothDevice?
    private var deadline: DispatchWorkItem?
    private var poll: DispatchWorkItem?
    private var operationID: UUID?
    private var operationName: String?
    private var targetAddress: String?
    private var connectPending = false
    private var releasePending = false
    private var timedOut = false
    private var cancelled = false
    private var nativeOwner: MacConnection?
    private var selectedOutput: AudioDeviceID?
    private let releaseQueue = DispatchQueue(label: "com.vanja.qc35.control.release")
    private let logger = Logger(subsystem: "com.vanja.qc35.control", category: "mac_connection")

    func connect(address: String? = nil, completion: @escaping (Result<Void, Error>) -> Void) {
        start("connect", completion: completion) { try begin(address: address) }
    }

    private func begin(address: String?) throws {
        let target = try resolve(address: address)
        if target.isConnected() { finish(.success(())); return }
        device = target
        markConnectPending()
        let status = target.openConnection(self, withPageTimeout: 8192, authenticationRequired: true)
        guard status == kIOReturnSuccess else {
            connectPending = false; nativeOwner = nil
            throw failure("Connect QC35: \(status)")
        }
    }

    private func markConnectPending() {
        connectPending = true
        nativeOwner = self // The callback target must live until the issued native request drains.
    }

    func cancel() {
        guard completion != nil else { return }
        deadline?.cancel(); deadline = nil
        poll?.cancel(); poll = nil
        cancelled = true
        completion = { _ in }
        log("mac_operation_cancelled", ["operation": operationName ?? "unknown", "nativeCallPending": String(connectPending || releasePending)])
        if !connectPending && !releasePending { finish(.failure(CancellationError())) }
    }

    func release(address: String? = nil, completion: @escaping (Result<Void, Error>) -> Void) {
        start("release", completion: completion) { try beginRelease(address: address) }
    }

    private func beginRelease(address: String?) throws {
        let target = try resolve(address: address)
        device = target
        guard target.isConnected() else { finish(.success(())); return }
        guard let token = operationID else { return }
        releasePending = true
        releaseQueue.async { [self, target] in
            let status = target.closeConnection()
            DispatchQueue.main.async { self.released(status, token: token) }
        }
    }

    private func released(_ status: IOReturn, token: UUID) {
        guard operationID == token else { return }
        releasePending = false
        guard !cancelled else { finish(.failure(CancellationError())); return }
        guard !timedOut else { finish(.failure(operationFailure("Release timed out"))); return }
        if device?.isConnected() == false { finish(.success(())); return }
        guard status == kIOReturnSuccess else { finish(.failure(operationFailure("Release QC35: \(status)"))); return }
        verifyReleased(token)
    }

    private func verifyReleased(_ token: UUID) {
        guard operationID == token, !cancelled, let device else { return }
        guard device.isConnected() else { finish(.success(())); return }
        schedulePoll(token) { self.verifyReleased(token) }
    }

    func activateOutput(address: String? = nil, completion: @escaping (Result<Void, Error>) -> Void) {
        start("output", completion: completion) { try beginOutput(address: address) }
    }

    private func beginOutput(address: String?) throws {
        device = try resolve(address: address, requireUniqueName: true)
        guard let token = operationID else { return }
        verifyOutput(token)
    }

    private func verifyOutput(_ token: UUID) {
        guard operationID == token, !cancelled, let device else { return }
        do {
            guard device.isConnected(), let name = device.name else { throw operationFailure("QC35 is disconnected") }
            if try outputReady(named: name) { finish(.success(())); return }
            schedulePoll(token) { self.verifyOutput(token) }
        } catch { finish(.failure(error)) }
    }

    private func outputReady(named name: String) throws -> Bool {
        try requireOutputOperation()
        if selectedOutput == nil, let target = try MacAudioOutput.resolve(named: name) {
            selectedOutput = target
            if try MacAudioOutput.current() != target {
                try requireOutputOperation()
                try MacAudioOutput.select(target)
            }
        }
        guard let selectedOutput else { return false }
        guard try MacAudioOutput.isAlive(selectedOutput) else { throw operationFailure("QC35 audio output disappeared") }
        return try MacAudioOutput.current() == selectedOutput
    }

    private func requireOutputOperation() throws {
        guard operationName == "output", completion != nil, !cancelled else { throw CancellationError() }
    }

    private func start(_ name: String, completion: @escaping (Result<Void, Error>) -> Void, begin: () throws -> Void) {
        guard self.completion == nil else { completion(.failure(failure("QC35 action in progress"))); return }
        self.completion = completion
        operationName = name; operationID = UUID(); timedOut = false; cancelled = false
        log("mac_operation_started", ["operation": name])
        armOperationDeadline()
        do { try begin() }
        catch { finish(.failure(error)) }
    }

    private func armOperationDeadline() {
        guard let token = operationID else { return }
        let work = DispatchWorkItem { [weak self] in self?.operationExpired(token) }
        deadline = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (operationName == "connect" ? 10 : 5), execute: work)
    }

    private func operationExpired(_ token: UUID) {
        guard operationID == token, !cancelled, !timedOut else { return }
        let error = timeoutFailure()
        guard connectPending || releasePending else { finish(.failure(error)); return }
        timedOut = true; deadline = nil
        let callback = completion
        completion = { _ in } // Keep the busy guard until the already-issued native request returns.
        log("mac_operation_timed_out", ["operation": operationName ?? "unknown", "nativeCallPending": "true"])
        callback?(.failure(error))
    }

    private func timeoutFailure() -> BoseSourcesError {
        switch operationName {
        case "connect": return operationFailure("QC35 did not connect within 10 seconds")
        case "release": return operationFailure("QC35 did not release within 5 seconds")
        default: return operationFailure("QC35 audio output unavailable or not selected within 5 seconds")
        }
    }

    private func schedulePoll(_ token: UUID, check: @escaping () -> Void) {
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.operationID == token, !self.cancelled else { return }
            check()
        }
        poll = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: work)
    }

    private func resolve(address: String?, requireUniqueName: Bool = false) throws -> IOBluetoothDevice {
        let requested = try address.map(Self.validatedAddress)
        let name = try requested == nil ? configuredName() : nil
        let paired = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] ?? []
        let records = paired.map { (name: $0.name, address: $0.addressString) }
        let index = try Self.pairedIndex(address: requested, name: name, records: records, requireUniqueName: requireUniqueName)
        targetAddress = try Self.validatedAddress(paired[index].addressString ?? "")
        return paired[index]
    }

    private func configuredName() throws -> String {
        let path = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/QC35InputGuard/config.json")
        let config = try JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any]
        guard let name = config?["headsetName"] as? String else { throw failure("QC35 configuration unavailable") }
        return name
    }

    private static func pairedIndex(address: String?, name: String?, records: [(name: String?, address: String?)], requireUniqueName: Bool = false) throws -> Int {
        let requested = try address.map(validatedAddress)
        let matches = records.indices.filter { index in
            if let requested { return normalizedAddress(records[index].address) == requested }
            return name != nil && records[index].name == name
        }
        guard matches.count == 1 else { throw targetFailure("QC35 must match one already-paired device") }
        let index = matches[0]
        if requireUniqueName { try requireUniqueOutputName(records[index].name, records: records) }
        return index
    }

    private static func requireUniqueOutputName(_ name: String?, records: [(name: String?, address: String?)]) throws {
        guard let name, !name.isEmpty, records.filter({ $0.name == name }).count == 1 else {
            throw BoseSourcesError(code: "mac_output_failed", detail: "QC35 audio output requires a unique paired device name")
        }
    }

    private static func normalizedAddress(_ address: String?) -> String? {
        guard let value = address?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        let pattern = "^(?:[0-9a-fA-F]{12}|(?:[0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}|(?:[0-9a-fA-F]{2}-){5}[0-9a-fA-F]{2})$"
        guard value.range(of: pattern, options: .regularExpression) != nil else { return nil }
        return value.replacingOccurrences(of: ":", with: "").replacingOccurrences(of: "-", with: "").uppercased()
    }

    private static func validatedAddress(_ address: String) throws -> String {
        guard let normalized = normalizedAddress(address) else { throw targetFailure("Invalid headset Bluetooth address") }
        return normalized
    }

    private static func targetFailure(_ detail: String) -> BoseSourcesError { BoseSourcesError(code: "mac_target_failed", detail: detail) }

    @objc func connectionComplete(_ device: IOBluetoothDevice!, status: IOReturn) {
        guard let device else { return }
        receiveConnection(address: device.addressString, status: status) { device.isConnected() }
    }

    private func receiveConnection(address: String?, status: IOReturn, isConnected: () -> Bool) {
        guard connectPending, let targetAddress, Self.normalizedAddress(address) == targetAddress else { return }
        connected(status, isConnected: isConnected())
    }

    private func connected(_ status: IOReturn, isConnected: Bool) {
        guard connectPending, operationName == "connect", completion != nil else { return }
        connectPending = false; nativeOwner = nil
        guard !cancelled else { finish(.failure(CancellationError())); return }
        guard !timedOut else { finish(.failure(timeoutFailure())); return }
        guard status == kIOReturnSuccess, isConnected else { finish(.failure(failure("QC35 did not connect"))); return }
        finish(.success(()))
    }

    private func finish(_ result: Result<Void, Error>) {
        let callback = completion
        completion = nil
        deadline?.cancel(); deadline = nil
        poll?.cancel(); poll = nil
        if let name = operationName { logFinished(name, result) }
        operationID = nil; operationName = nil; selectedOutput = nil; targetAddress = nil
        connectPending = false; releasePending = false; timedOut = false; cancelled = false
        nativeOwner = nil
        device = nil
        callback?(result)
    }

    private func logFinished(_ name: String, _ result: Result<Void, Error>) {
        switch result {
        case .success: log("mac_operation_finished", ["operation": name, "success": "true"])
        case .failure(let error): log("mac_operation_finished", ["operation": name, "success": "false", "error": String(describing: error)])
        }
    }

    private func log(_ event: String, _ fields: [String: String]) {
        let record = fields.merging(["event": event]) { _, value in value }
        guard let data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]), let text = String(data: data, encoding: .utf8) else { return }
        logger.info("\(text, privacy: .public)")
    }

    private func operationFailure(_ detail: String) -> BoseSourcesError {
        BoseSourcesError(code: "mac_\(operationName ?? "operation")_failed", detail: detail)
    }

    private func failure(_ detail: String) -> BoseSourcesError { BoseSourcesError(code: "mac_connect_failed", detail: detail) }
}

private enum MacAudioOutput {
    private static let system = AudioObjectID(kAudioObjectSystemObject)

    static func resolve(named name: String) throws -> AudioDeviceID? {
        let candidates = try devices().filter { try deviceName($0) == name && isEligible($0) }
        guard candidates.count <= 1 else { throw failure("Configured QC35 matches multiple live Bluetooth audio outputs") }
        return candidates.first
    }

    private static func isEligible(_ id: AudioDeviceID) throws -> Bool {
        let transport = try number(id, kAudioDevicePropertyTransportType)
        guard [kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE].contains(transport), try isAlive(id) else { return false }
        var property = address(kAudioDevicePropertyStreams, scope: kAudioDevicePropertyScopeOutput)
        var size: UInt32 = 0
        try check(AudioObjectGetPropertyDataSize(id, &property, 0, nil, &size), "Read output streams")
        guard size > 0 else { return false }
        return try number(id, kAudioDevicePropertyDeviceCanBeDefaultDevice, scope: kAudioDevicePropertyScopeOutput) != 0
    }

    static func isAlive(_ id: AudioDeviceID) throws -> Bool { try number(id, kAudioDevicePropertyDeviceIsAlive) != 0 }
    static func current() throws -> AudioDeviceID { try number(system, kAudioHardwarePropertyDefaultOutputDevice) }

    static func select(_ id: AudioDeviceID) throws {
        var property = address(kAudioHardwarePropertyDefaultOutputDevice)
        var value = id
        try check(AudioObjectSetPropertyData(system, &property, 0, nil, UInt32(MemoryLayout.size(ofValue: value)), &value), "Select QC35 audio output")
    }

    private static func devices() throws -> [AudioDeviceID] {
        var property = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        try check(AudioObjectGetPropertyDataSize(system, &property, 0, nil, &size), "Read audio device list size")
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard !ids.isEmpty else { return [] }
        let status = ids.withUnsafeMutableBytes { AudioObjectGetPropertyData(system, &property, 0, nil, &size, $0.baseAddress!) }
        try check(status, "Read audio device list")
        return Array(ids.prefix(Int(size) / MemoryLayout<AudioDeviceID>.size))
    }

    private static func deviceName(_ id: AudioDeviceID) throws -> String {
        var property = address(kAudioObjectPropertyName)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        try check(AudioObjectGetPropertyData(id, &property, 0, nil, &size, &value), "Read audio device name")
        guard let value else { throw failure("Audio device name unavailable") }
        return value.takeRetainedValue() as String
    }

    private static func number(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) throws -> UInt32 {
        var property = address(selector, scope: scope)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        try check(AudioObjectGetPropertyData(id, &property, 0, nil, &size, &value), "Read audio property \(selector)")
        return value
    }

    private static func address(_ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private static func check(_ status: OSStatus, _ operation: String) throws {
        guard status == noErr else { throw failure("\(operation): OSStatus \(status)") }
    }

    private static func failure(_ detail: String) -> BoseSourcesError { BoseSourcesError(code: "mac_output_failed", detail: detail) }
}

#if QC35_HANDOFF_TEST
// Inject lifecycle events into the real operation gate; no device resolution or native I/O runs.
extension MacConnection {
    static func runOfflineTests() throws -> Int {
        try testConnectTimeout() + testConnectCancellation() + testReleaseCancellation() + testOutputCancellation()
            + testPairedTargetSelection() + testExplicitAddressValidation() + testTargetCallbacks()
    }

    private static func testPairedTargetSelection() throws -> Int {
        let records: [(name: String?, address: String?)] = [("QC35", "AA-bb-CC-dd-EE-01"), ("QC35", "11-22-33-44-55-66"), ("Travel QC35", "22-33-44-55-66-77")]
        try require(try pairedIndex(address: "aa:bb:cc:dd:ee:01", name: nil, records: records) == 0, "Explicit address must normalize the paired hyphen format")
        try require(try pairedIndex(address: "112233445566", name: nil, records: records) == 1, "Explicit address must select the intended device despite duplicate names")
        try require(try pairedIndex(address: nil, name: "Travel QC35", records: records) == 2, "Default selection must preserve exact configured-name matching")
        try require((try? pairedIndex(address: nil, name: "QC35", records: records)) == nil, "Ambiguous default names must remain rejected")
        try require((try? pairedIndex(address: "99:88:77:66:55:44", name: "QC35", records: records)) == nil, "Unpaired explicit address must never fall back to a configured name")
        try require((try? pairedIndex(address: "AA:BB:CC:DD:EE:01", name: nil, records: records + [("Duplicate", "aabbccddee01")])) == nil, "Duplicate paired addresses must fail closed")
        try require((try? pairedIndex(address: "AA:BB:CC:DD:EE:01", name: nil, records: records, requireUniqueName: true)) == nil, "Address-selected output must reject an ambiguous paired name")
        try require(try pairedIndex(address: "22:33:44:55:66:77", name: nil, records: records, requireUniqueName: true) == 2, "Unique paired output name remains eligible")
        return 8
    }

    private static func testExplicitAddressValidation() throws -> Int {
        let invalid = ["", "1:22:33:44:55:66", "11:22:33:44:55", "11:22:33:44:55:66:77", "GG:22:33:44:55:66", "11:22-33:44:55:66", "112233445566junk"]
        for address in invalid { try require(normalizedAddress(address) == nil, "Malformed address must not normalize: \(address)") }
        try require(normalizedAddress(" \naA-Bb-cC-dD-eE-fF\t") == "AABBCCDDEEFF", "Case and outer whitespace must normalize")
        let subject = MacConnection()
        var rejected = 0
        let complete: (Result<Void, Error>) -> Void = { if case .failure(let error as BoseSourcesError) = $0, error.code == "mac_target_failed" { rejected += 1 } }
        subject.connect(address: "not an address", completion: complete)
        subject.release(address: "not an address", completion: complete)
        subject.activateOutput(address: "not an address", completion: complete)
        try require(rejected == 3 && subject.completion == nil && subject.targetAddress == nil, "Invalid explicit targets must fail before paired-device discovery or native actions")
        return invalid.count + 2
    }

    private static func testTargetCallbacks() throws -> Int {
        let subject = MacConnection()
        var callbacks = 0; var probes = 0; var attemptedStarts = 0
        let beginA = { subject.targetAddress = "AABBCCDDEE01"; subject.markConnectPending() }
        let beginB = { subject.targetAddress = "112233445566"; subject.markConnectPending() }
        subject.start("connect", completion: { _ in callbacks += 1 }, begin: beginA)
        let tokenA = subject.operationID!
        subject.receiveConnection(address: "11-22-33-44-55-66", status: kIOReturnSuccess) { probes += 1; return true }
        try require(probes == 0 && callbacks == 0 && subject.connectPending, "Another device's callback must not even probe or finish the current target")
        subject.cancel()
        subject.start("connect", completion: { _ in }, begin: { attemptedStarts += 1; beginB() })
        try require(attemptedStarts == 0 && subject.targetAddress == "AABBCCDDEE01", "Cancellation must keep the pending target's busy ownership")
        subject.receiveConnection(address: "aa:bb:cc:dd:ee:01", status: kIOReturnSuccess) { probes += 1; return true }
        try require(callbacks == 0 && subject.completion == nil && subject.targetAddress == nil, "Cancelled target's normalized callback must only drain its own operation")
        subject.start("connect", completion: { _ in callbacks += 1 }, begin: beginB)
        subject.receiveConnection(address: "AA-BB-CC-DD-EE-01", status: kIOReturnSuccess) { probes += 1; return true }
        subject.operationExpired(tokenA)
        try require(probes == 1 && callbacks == 0 && subject.connectPending, "Old target callback or deadline must not complete the new target")
        subject.receiveConnection(address: "11:22:33:44:55:66", status: kIOReturnSuccess) { probes += 1; return true }
        try require(probes == 2 && callbacks == 1 && subject.completion == nil, "New target must complete only with its own normalized callback")
        return 5
    }

    private static func testConnectTimeout() throws -> Int {
        let subject = MacConnection()
        var callbacks = 0; var failures = 0; var attemptedStarts = 0
        subject.start("connect", completion: { callbacks += 1; if case .failure = $0 { failures += 1 } }) { subject.markConnectPending() }
        let token = subject.operationID!
        subject.operationExpired(token)
        try require(callbacks == 1 && failures == 1 && subject.connectPending, "Connect timeout must report once and retain native ownership")
        subject.start("connect", completion: { if case .failure = $0 { failures += 1 } }) { attemptedStarts += 1 }
        try require(attemptedStarts == 0 && failures == 2, "Connect B must not start while timed-out A is pending")
        subject.connected(kIOReturnSuccess, isConnected: true)
        try require(callbacks == 1 && subject.completion == nil && subject.nativeOwner == nil, "A's late callback must only drain A")
        subject.start("connect", completion: { _ in callbacks += 1 }) { subject.markConnectPending() }
        subject.operationExpired(token)
        try require(callbacks == 1 && subject.connectPending, "A's stale timeout must not finish B")
        subject.connected(kIOReturnSuccess, isConnected: true)
        try require(callbacks == 2 && subject.completion == nil, "B must finish only on its own callback")
        return 5
    }

    private static func testConnectCancellation() throws -> Int {
        let subject = MacConnection()
        var callbacks = 0; var attemptedStarts = 0
        subject.start("connect", completion: { _ in callbacks += 1 }) { subject.markConnectPending() }
        let token = subject.operationID!
        subject.cancel()
        subject.start("release", completion: { _ in }) { attemptedStarts += 1 }
        subject.operationExpired(token)
        try require(subject.connectPending && attemptedStarts == 0 && callbacks == 0, "Cancelled open must remain busy and suppress callbacks")
        subject.connected(kIOReturnSuccess, isConnected: true)
        try require(callbacks == 0 && subject.completion == nil && subject.nativeOwner == nil, "Cancelled open callback must only drain ownership")
        return 2
    }

    private static func testReleaseCancellation() throws -> Int {
        let subject = MacConnection()
        var callbacks = 0; var attemptedStarts = 0
        subject.start("release", completion: { _ in callbacks += 1 }) { subject.releasePending = true }
        let token = subject.operationID!
        subject.cancel()
        subject.start("output", completion: { _ in }) { attemptedStarts += 1 }
        try require(subject.releasePending && callbacks == 0 && attemptedStarts == 0, "Cancelled close must fence new output work")
        subject.released(kIOReturnSuccess, token: token)
        try require(callbacks == 0 && subject.completion == nil, "Cancelled close callback must not resume old work")
        return 2
    }

    private static func testOutputCancellation() throws -> Int {
        let subject = MacConnection()
        var callbacks = 0; var outputAttempts = 0
        subject.start("output", completion: { _ in callbacks += 1 }) {}
        let token = subject.operationID!
        subject.schedulePoll(token) { outputAttempts += 1 }
        let stalePoll = subject.poll!
        subject.cancel()
        stalePoll.perform(); subject.operationExpired(token)
        try require(callbacks == 0 && outputAttempts == 0 && subject.completion == nil, "Cancelled output work must not run or complete")
        do {
            _ = try subject.outputReady(named: "Must not resolve any native device")
            throw testFailure("Cancelled output must reject before native resolution")
        } catch is CancellationError {}
        subject.start("output", completion: { _ in callbacks += 1 }) {}
        stalePoll.perform(); subject.operationExpired(token)
        try require(outputAttempts == 0 && callbacks == 0 && subject.completion != nil, "Old output work must not affect a new operation")
        subject.finish(.success(()))
        try require(callbacks == 1, "New output lifecycle must remain usable after cancellation")
        return 4
    }

    private static func require(_ condition: Bool, _ message: String) throws {
        guard condition else { throw testFailure(message) }
    }

    private static func testFailure(_ message: String) -> NSError {
        NSError(domain: "QC35HandoffTests", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

@main
enum QC35HandoffTests {
    @MainActor static func main() throws {
        let checks = try MacConnection.runOfflineTests()
        print("{\"event\":\"qc35_handoff_tests_passed\",\"checks\":\(checks),\"nativeIO\":false}")
    }
}
#endif

import Foundation
@preconcurrency import IOBluetooth
import CoreAudio
import OSLog
