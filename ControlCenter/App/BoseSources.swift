struct BoseSource: Codable, Equatable {
    let address: String
    let name: String
    let status: Int

    static func exclusiveAddress(in sources: [BoseSource]) -> String? {
        let connected = sources.filter { $0.status == 1 || $0.status == 3 }
        return connected.count == 1 ? connected[0].address : nil
    }
}

struct BoseSourcesError: Error, Codable, LocalizedError {
    let code: String
    let detail: String
    var errorDescription: String? { detail }
}

// Wire facts: BoseConnect-Linux_based-connect/based.c (GET 4.4 and GET 4.5).
@MainActor
final class BoseSources: NSObject, @preconcurrency IOBluetoothRFCOMMChannelDelegate {
    private var completion: ((Result<[BoseSource], Error>) -> Void)?
    private var channel: IOBluetoothRFCOMMChannel?
    private var deadline: DispatchWorkItem?
    private var framer = BoseFrameBuffer()
    private var expected: (block: UInt8, function: UInt8) = (0, 1)
    private var addresses: [[UInt8]] = []
    private var sources: [BoseSource] = []
    private var writes: [Int: NSData] = [:]
    private var writeID = 0
    private var target: [UInt8]?
    private var selection: [UInt8]?
    private var disconnecting = false
    private var connectStarted = false
    private var refresh: DispatchWorkItem?
    private var stage = "idle"
    private var operationID = UUID().uuidString
    func load(completion: @escaping (Result<[BoseSource], Error>) -> Void) {
        start(target: nil, completion: completion)
    }
    func prepareHandoff(_ source: BoseSource, completion: @escaping (Result<[BoseSource], Error>) -> Void) {
        do { start(target: try BoseFrameBuffer.parseAddress(source.address), completion: completion) }
        catch { completion(.failure(error)) }
    }
    private func start(target: [UInt8]?, completion: @escaping (Result<[BoseSource], Error>) -> Void) {
        guard self.completion == nil else {
            completion(.failure(BoseSourcesError(code: "busy", detail: "Source query already running")))
            return
        }
        self.completion = completion
        self.target = target
        selection = target
        disconnecting = false
        connectStarted = false
        stage = "opening"
        operationID = UUID().uuidString
        trace("operation_started", [:])
        do { try openConfiguredHeadset() }
        catch { finish(.failure(error)) }
    }
    private func openConfiguredHeadset() throws {
        let device = try resolveHeadset()
        let identifier = try resolveChannel(device)
        guard device.isConnected() else { throw failure("disconnected", "Connect QC35 first") }
        trace("resolved_channel", ["channel": identifier, "connected": device.isConnected()])
        armDeadline()
        let result = device.openRFCOMMChannelAsync(&channel, withChannelID: identifier, delegate: self)
        guard result == kIOReturnSuccess else { throw failure("open_failed", "RFCOMM open: \(result)") }
    }
    private func resolveHeadset() throws -> IOBluetoothDevice {
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/QC35InputGuard/config.json")
        let config = try JSONDecoder().decode(HeadsetConfiguration.self, from: Data(contentsOf: path))
        let matches = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] ?? [])
            .filter { $0.name == config.headsetName }
        guard matches.count == 1 else { throw failure("headset_not_unique", "Configured headset must match one paired device") }
        return matches[0]
    }
    private func resolveChannel(_ device: IOBluetoothDevice) throws -> BluetoothRFCOMMChannelID {
        let matches = (device.services as? [IOBluetoothSDPServiceRecord] ?? []).filter { $0.matchesUUID16(0x1101) }
        guard matches.count == 1 else { throw failure("service_not_unique", "Configured QC35 must advertise one cached Serial Port service") }
        var identifier: BluetoothRFCOMMChannelID = 0
        guard matches[0].getRFCOMMChannelID(&identifier) == kIOReturnSuccess, (1...30).contains(identifier) else {
            throw failure("channel_missing", "Cached Bose RFCOMM channel unavailable")
        }
        return identifier
    }
    private func armDeadline() {
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let detail = self.stage == "awaiting_ack" ? "QC35 did not accept the device request" : self.stage == "verifying_connection" ? (self.disconnecting ? "QC35 did not release the other device" : "Device did not connect. Check its Bluetooth is on.") : "QC35 source query timed out at \(self.stage)"
            self.finish(.failure(BoseSourcesError(code: "timeout", detail: detail)))
        }
        deadline = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: work)
    }
    func rfcommChannelOpenComplete(_ sender: IOBluetoothRFCOMMChannel!, status: IOReturn) {
        trace("open_callback", ["status": status, "channelAssigned": channel != nil, "channelMatches": sender === channel])
        guard sender === channel, completion != nil else { return }
        guard status == kIOReturnSuccess else { finish(.failure(failure("open_failed", "RFCOMM open: \(status)"))); return }
        send(block: 0, function: 1)
    }
    private func send(block: UInt8, function: UInt8, payload: [UInt8] = [], operation: UInt8 = 1) {
        guard let channel, channel.getDevice().isConnected() else {
            finish(.failure(failure("disconnected", "QC35 disconnected during query"))); return
        }
        expected = (block, function)
        stage = operation == 5 ? "awaiting_ack" : connectStarted ? "verifying_connection" : "query_\(block)_\(function)"
        writeID += 1
        let bytes = NSData(data: Data([block, function, operation, UInt8(payload.count)] + payload))
        writes[writeID] = bytes
        let status = channel.writeAsync(UnsafeMutableRawPointer(mutating: bytes.bytes), length: UInt16(bytes.length), refcon: UnsafeMutableRawPointer(bitPattern: writeID))
        trace(operation == 5 ? "request" : "query", ["status": status, "block": block, "function": function, "operator": operation, "hex": ([block, function, operation, UInt8(payload.count)] + payload).map { String(format: "%02X", $0) }.joined(separator: " ")])
        if status != kIOReturnSuccess { finish(.failure(failure("write_failed", "RFCOMM write: \(status)"))) }
    }
    func rfcommChannelWriteComplete(_ sender: IOBluetoothRFCOMMChannel!, refcon: UnsafeMutableRawPointer!, status: IOReturn) {
        guard sender === channel, completion != nil else { return }
        writes.removeValue(forKey: Int(bitPattern: refcon))
        if status != kIOReturnSuccess { finish(.failure(failure("write_failed", "RFCOMM write completion: \(status)"))) }
    }
    func rfcommChannelData(_ sender: IOBluetoothRFCOMMChannel!, data pointer: UnsafeMutableRawPointer!, length: Int) {
        guard sender === channel, completion != nil, let pointer else { return }
        let token = operationID
        trace("raw_received", ["hex": Data(bytes: pointer, count: length).map { String(format: "%02X", $0) }.joined(separator: " ")])
        do {
            let frames = try framer.append(Data(bytes: pointer, count: length))
            try BoseFrameBuffer.dispatch(frames, isCurrent: { self.operationID == token && sender === self.channel && self.completion != nil }, receive: receive)
        } catch {
            if operationID == token, sender === channel, completion != nil { finish(.failure(error)) }
        }
    }
    private func receive(_ frame: BoseFrame) throws {
        trace("response", ["block": frame.block, "function": frame.function, "operator": frame.operation, "payloadLength": frame.payload.count])
        if try receiveOperation(frame) { return }
        guard frame.block == expected.block, frame.function == expected.function else { return }
        guard frame.operation != 4 else { throw failure("device_error", "BMAP \(frame.block).\(frame.function): \(frame.payload)") }
        guard frame.operation == 3 else { return }
        switch (frame.block, frame.function) {
        case (0, 1): guard !frame.payload.isEmpty else { throw failure("invalid_init", "Empty Bose initialization") }; send(block: 4, function: 4)
        case (4, 4): addresses = try BoseFrameBuffer.parseAddresses(frame.payload); try receiveList()
        case (4, 5): try receiveSource(frame.payload)
        default: break
        }
    }
    private func receiveOperation(_ frame: BoseFrame) throws -> Bool {
        guard connectStarted, let target, frame.block == 4, frame.function == (disconnecting ? 2 : 1) else { return false }
        guard frame.operation != 4 else { throw failure("device_error", "QC35 rejected the device request: \(frame.payload)") }
        guard [6, 7].contains(frame.operation) else { return true }
        // This QC35 returns a seven-byte disconnect PROCESSING payload; it is not completion.
        // Only a fresh source status of zero confirms release, independently of that opaque payload.
        if frame.operation == 7 && !disconnecting { try BoseFrameBuffer.validateAcknowledgement(frame.payload, target: target) }
        trace(frame.operation == 7 ? "processing" : "result", ["operator": frame.operation])
        // A late operation response must not interrupt the status GET already in flight.
        if stage == "awaiting_ack" { send(block: 4, function: 4) }
        return true
    }
    private func queryNextSource() {
        guard sources.count < addresses.count else { completeSourceRead(); return }
        send(block: 4, function: 5, payload: addresses[sources.count])
    }
    private func receiveList() throws {
        queryNextSource()
    }
    private func completeSourceRead() {
        if let selection, !connectStarted {
            do { try beginHandoff(selection) }
            catch { finish(.failure(error)) }
            return
        }
        let selectedStatus = target.flatMap { selected in sources.first { (try? BoseFrameBuffer.parseAddress($0.address)) == selected }?.status }
        let confirmed = target == nil || (disconnecting ? selectedStatus == 0 : selectedStatus == 1 || selectedStatus == 3)
        trace("confirm", ["connected": selectedStatus == 1 || selectedStatus == 3, "selectedStatus": selectedStatus ?? -1, "sourceCount": sources.count])
        guard !confirmed else { finish(.success(sources)); return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.completion != nil else { return }
            self.sources.removeAll()
            self.send(block: 4, function: 4)
        }
        refresh = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }
    private func beginHandoff(_ selection: [UInt8]) throws {
        guard let selected = sources.first(where: { (try? BoseFrameBuffer.parseAddress($0.address)) == selection }) else {
            throw failure("source_missing", "Selected device is no longer paired")
        }
        if selected.status == 3, let other = sources.first(where: { $0.status == 1 }) {
            target = try BoseFrameBuffer.parseAddress(other.address)
            disconnecting = true
        } else if selected.status == 1 || selected.status == 3 { finish(.success(sources)); return }
        try requestHandoff()
    }
    private func requestHandoff() throws {
        guard let target else { throw failure("source_missing", "Handoff target unavailable") }
        let payload = try disconnecting ? BoseFrameBuffer.disconnectPayload(target, saved: addresses) : BoseFrameBuffer.connectPayload(target, saved: addresses)
        sources.removeAll()
        connectStarted = true
        send(block: 4, function: disconnecting ? 2 : 1, payload: payload, operation: 5)
    }
    private func receiveSource(_ payload: [UInt8]) throws {
        guard sources.count < addresses.count else { throw failure("unexpected_info", "Unrequested source details") }
        sources.append(try BoseFrameBuffer.parseSource(payload, expected: addresses[sources.count]))
        queryNextSource()
    }
    func rfcommChannelClosed(_ sender: IOBluetoothRFCOMMChannel!) {
        trace("closed_callback", ["channelAssigned": channel != nil, "channelMatches": sender === channel, "operationActive": completion != nil])
        guard sender === channel, completion != nil else { return }
        finish(.failure(failure("channel_closed", "QC35 closed the control channel")))
    }
    func cancel() {
        guard completion != nil else { return }
        finish(.failure(failure("cancelled", "Source query cancelled")))
    }
    private func finish(_ result: Result<[BoseSource], Error>) {
        switch result {
        case .success: trace("complete", ["sourceCount": sources.count])
        case .failure(let error): trace("error", ["code": (error as? BoseSourcesError)?.code ?? "system_error", "status": (error as NSError).code])
        }
        let callback = completion
        completion = nil
        deadline?.cancel(); deadline = nil
        refresh?.cancel(); refresh = nil; target = nil; selection = nil
        let closing = channel
        channel = nil
        _ = closing?.setDelegate(nil)
        _ = closing?.close()
        writes.removeAll(); addresses.removeAll(); sources.removeAll(); framer = BoseFrameBuffer()
        callback?(result)
    }
    private func failure(_ code: String, _ detail: String) -> BoseSourcesError {
        BoseSourcesError(code: code, detail: detail)
    }
    private func trace(_ event: String, _ fields: [String: Any]) {
        #if BOSE_SOURCE_PROBE
        var object = fields
        #else
        guard event != "raw_received" else { return }
        let allowed = ["status", "channel", "connected", "channelAssigned", "channelMatches", "operationActive", "block", "function", "operator", "payloadLength", "code", "selectedStatus", "sourceCount"]
        var object = fields.filter { allowed.contains($0.key) }
        #endif
        object.merge(["event": event, "time": ISO8601DateFormatter().string(from: Date()), "operation": target == nil ? "load" : disconnecting ? "disconnect" : "connect", "operationID": operationID, "stage": stage]) { _, value in value }
        do {
            let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) + Data([10])
            #if BOSE_SOURCE_PROBE
            FileHandle.standardError.write(data)
            #else
            try appendTelemetry(data)
            #endif
        } catch {
            FileHandle.standardError.write(Data("{\"event\":\"control_telemetry_error\",\"code\":\((error as NSError).code)}\n".utf8))
        }
    }
    private func appendTelemetry(_ data: Data) throws {
        let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/QC35InputGuard")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("control-events.jsonl")
        try rotateTelemetry(path, incoming: data.count)
        if !FileManager.default.fileExists(atPath: path.path) { try Data().write(to: path) }
        let file = try FileHandle(forWritingTo: path)
        defer { try? file.close() }
        try file.seekToEnd(); try file.write(contentsOf: data)
    }
    private func rotateTelemetry(_ path: URL, incoming: Int) throws {
        guard FileManager.default.fileExists(atPath: path.path) else { return }
        let size = try FileManager.default.attributesOfItem(atPath: path.path)[.size] as? Int ?? 0
        guard size + incoming > 1_048_576 else { return }
        let previous = path.appendingPathExtension("1")
        if FileManager.default.fileExists(atPath: previous.path) { try FileManager.default.removeItem(at: previous) }
        try FileManager.default.moveItem(at: path, to: previous)
    }
    private struct HeadsetConfiguration: Decodable { let headsetName: String }
}
private struct BoseFrame {
    let block, function, operation: UInt8
    let payload: [UInt8]
}
private struct BoseFrameBuffer {
    private var bytes: [UInt8] = []

    static func dispatch(_ frames: [BoseFrame], isCurrent: () -> Bool, receive: (BoseFrame) throws -> Void) rethrows {
        for frame in frames {
            guard isCurrent() else { return }
            try receive(frame)
        }
    }

    mutating func append(_ data: Data) throws -> [BoseFrame] {
        guard data.count + bytes.count <= 4096 else { throw Self.invalid("Bose receive buffer overflow") }
        bytes += data
        var frames: [BoseFrame] = []
        while bytes.count >= 4, bytes.count >= 4 + Int(bytes[3]) {
            let end = 4 + Int(bytes[3])
            frames.append(BoseFrame(block: bytes[0], function: bytes[1], operation: bytes[2] & 15, payload: Array(bytes[4..<end])))
            bytes.removeFirst(end)
        }
        return frames
    }
    static func parseAddresses(_ payload: [UInt8]) throws -> [[UInt8]] {
        guard !payload.isEmpty, (payload.count - 1) % 6 == 0, payload.count <= 49 else {
            throw invalid("Invalid Bose paired-source list length")
        }
        let addresses = stride(from: 1, to: payload.count, by: 6).map { Array(payload[$0..<$0 + 6]) }
        guard Set(addresses).count == addresses.count else { throw invalid("Duplicate Bose source addresses") }
        return addresses
    }
    static func parseSource(_ payload: [UInt8], expected: [UInt8]) throws -> BoseSource {
        guard payload.count >= 9, Array(payload.prefix(6)) == expected else { throw invalid("Invalid Bose source details or address") }
        let address = expected.map { String(format: "%02X", $0) }.joined(separator: ":")
        let nameBytes = payload.dropFirst(9).prefix { $0 != 0 }
        guard let name = String(bytes: nameBytes, encoding: .utf8), !name.isEmpty else { throw invalid("Invalid Bose source name") }
        return BoseSource(address: address, name: name, status: Int(payload[6]))
    }
    static func parseAddress(_ value: String) throws -> [UInt8] {
        let parts = value.split(separator: ":", omittingEmptySubsequences: false)
        let bytes = parts.compactMap { $0.count == 2 ? UInt8($0, radix: 16) : nil }
        guard bytes.count == 6, parts.count == 6 else { throw invalid("Invalid source address") }
        return bytes
    }
    static func connectPayload(_ target: [UInt8], saved: [[UInt8]]) throws -> [UInt8] {
        guard target.count == 6, saved.contains(target) else { throw invalid("Selected source is no longer paired") }
        return [0] + target
    }
    static func disconnectPayload(_ target: [UInt8], saved: [[UInt8]]) throws -> [UInt8] {
        guard target.count == 6, saved.contains(target) else { throw invalid("Selected source is no longer paired") }
        return target
    }
    static func isConnected(_ target: [UInt8], sources: [BoseSource]) -> Bool {
        let address = target.map { String(format: "%02X", $0) }.joined(separator: ":")
        return sources.contains { $0.address == address && [1, 3].contains($0.status) }
    }
    static func validateAcknowledgement(_ payload: [UInt8], target: [UInt8]) throws {
        guard target.count == 6, payload == target else { throw invalid("Bose connection acknowledgement mismatch") }
    }
    private static func invalid(_ detail: String) -> BoseSourcesError {
        BoseSourcesError(code: "invalid_response", detail: detail)
    }
}

#if BOSE_SOURCE_PROBE
@main
private struct BoseSourceProbe {
    @MainActor static func main() {
        if CommandLine.arguments.contains("--self-test") { selfTest(); return }
        let loader = BoseSources()
        var complete = false
        var successful = false
        loader.load { result in
            complete = true
            switch result {
            case .success(let sources): successful = true; emit(["sources": sources.map { ["address": $0.address, "name": $0.name, "status": $0.status] }])
            case .failure(let error): emit(["error": (error as? BoseSourcesError)?.code ?? "query_failed", "detail": error.localizedDescription])
            }
        }
        let end = Date().addingTimeInterval(9)
        while !complete && Date() < end { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
        if !complete { loader.cancel() }
        exit(successful ? 0 : 1)
    }
    private static func selfTest() {
        do {
            var buffer = BoseFrameBuffer()
            guard try buffer.append(Data([4, 4, 3])).isEmpty else { throw testFailure() }
            let frames = try buffer.append(Data([7, 1, 1, 2, 3, 4, 5, 6, 0, 1, 3, 1, 9]))
            guard frames.count == 2, frames[1].payload == [9] else { throw testFailure() }
            var currentOperation = 1
            var delivered = 0
            BoseFrameBuffer.dispatch(frames, isCurrent: { currentOperation == 1 }) { _ in
                delivered += 1
                currentOperation = 2 // Completing the first reply synchronously starts another handoff step.
            }
            guard delivered == 1 else { throw testFailure() }
            let address = try BoseFrameBuffer.parseAddresses(frames[0].payload)[0]
            let source = try BoseFrameBuffer.parseSource(address + [99, 0, 0] + Array("Phone".utf8), expected: address)
            guard source.address == "01:02:03:04:05:06", source.status == 99, source.name == "Phone" else { throw testFailure() }
            guard (try? BoseFrameBuffer.parseAddresses([1, 2])) == nil else { throw testFailure() }
            guard (try? BoseFrameBuffer.parseSource(address + [1], expected: address)) == nil else { throw testFailure() }
            guard (try? BoseFrameBuffer.parseSource(address + [1, 0, 0, 65], expected: [6, 5, 4, 3, 2, 1])) == nil else { throw testFailure() }
            guard try BoseFrameBuffer.connectPayload(address, saved: [address]) == [0] + address else { throw testFailure() }
            guard (try? BoseFrameBuffer.connectPayload(address, saved: [])) == nil else { throw testFailure() }
            guard try BoseFrameBuffer.disconnectPayload(address, saved: [address]) == address else { throw testFailure() }
            guard (try? BoseFrameBuffer.disconnectPayload(address, saved: [])) == nil else { throw testFailure() }
            guard (try? BoseFrameBuffer.parseAddress("01:02:03:04:05")) == nil else { throw testFailure() }
            guard !BoseFrameBuffer.isConnected(address, sources: [source]) else { throw testFailure() }
            guard BoseFrameBuffer.isConnected(address, sources: [BoseSource(address: source.address, name: source.name, status: 1)]) else { throw testFailure() }
            try BoseFrameBuffer.validateAcknowledgement(address, target: address)
            guard (try? BoseFrameBuffer.validateAcknowledgement([1], target: address)) == nil else { throw testFailure() }
            guard (try? BoseFrameBuffer.validateAcknowledgement(address.reversed(), target: address)) == nil else { throw testFailure() }
            guard !BoseFrameBuffer.isConnected(address, sources: [BoseSource(address: source.address, name: source.name, status: 0)]) else { throw testFailure() }
            let mac = BoseSource(address: "07:08:09:0A:0B:0C", name: "Mac", status: 3)
            let phone = BoseSource(address: source.address, name: "Phone", status: 1)
            guard BoseSource.exclusiveAddress(in: [mac, phone]) == nil else { throw testFailure() }
            guard BoseSource.exclusiveAddress(in: [phone]) == phone.address else { throw testFailure() }
            guard BoseSource.exclusiveAddress(in: [source]) == nil else { throw testFailure() }
            emit(["selfTest": "passed", "checks": 21])
        } catch { emit(["selfTest": "failed", "error": error.localizedDescription]); exit(1) }
    }
    private static func testFailure() -> BoseSourcesError { BoseSourcesError(code: "self_test", detail: "Parser assertion failed") }
    private static func emit(_ object: [String: Any]) {
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        print(String(decoding: data, as: UTF8.self))
    }
}
#endif
import Foundation
import IOBluetooth
