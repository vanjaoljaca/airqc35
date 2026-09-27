@MainActor
final class QC35Model: ObservableObject {
    @Published private(set) var sources: [BoseSource] = []
    @Published private(set) var loading = false
    @Published private(set) var releaseOnSleep = true
    @Published private(set) var avoidHeadsetMic = true
    @Published private(set) var message: String?
    @Published private(set) var selectedAddress: String?
    @Published private(set) var headsets: [HeadsetState] = []
    @Published private(set) var headsetMessage: String?
    @Published private(set) var headsetAction: HeadsetAction?
    @Published private(set) var headsetInventoryValid = false
    private let bluetooth = BoseSources()
    private let connection = MacConnection()
    private let inspectHeadsets: (String) throws -> [HeadsetState]
    private let headsetOperations: HeadsetOperations
    private var headsetMonitor: HeadsetBluetooth?
    private let root: URL
    private var configuredHeadsetName = ""
    private var localAddress: String?
    private var visibleAddresses: [String] = []
    private var generation = 0
    private let logger = Logger(subsystem: "com.vanja.qc35.control", category: "actions")

    init(root: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/QC35InputGuard"),
         inspectHeadsets: ((String) throws -> [HeadsetState])? = nil, headsetOperations: HeadsetOperations? = nil) {
        self.root = root
        if let inspectHeadsets { self.inspectHeadsets = inspectHeadsets }
        else {
            let monitor = HeadsetBluetooth()
            headsetMonitor = monitor
            self.inspectHeadsets = monitor.snapshot
        }
        let native = connection
        self.headsetOperations = headsetOperations ?? HeadsetOperations(
            connect: { native.connect(address: $0, completion: $1) },
            disconnect: { native.release(address: $0, completion: $1) },
            output: { native.activateOutput(address: $0, completion: $1) })
        headsetMonitor?.onChange = { [weak self] in self?.reloadHeadsets() }
    }

    func refresh() {
        cancel(stopObservation: false)
        message = nil
        var configured = false
        do { try reloadOptions(); configured = true }
        catch { report(error) }
        reloadHeadsets()
        guard configured else { return }
        do { try loadCache() }
        catch { clearSources(); report(error) }
        guard headsetInventoryValid, headsets.contains(where: { $0.name == configuredHeadsetName && $0.isConnected }) else { return }
        loading = true
        message = nil
        let token = generation
        bluetooth.load { [weak self] result in self?.refreshed(result, token: token) }
    }

    private func reloadHeadsets() {
        do {
            headsets = try inspectHeadsets(configuredHeadsetName)
            headsetInventoryValid = true
            headsetMessage = nil
        } catch {
            headsetInventoryValid = false
            headsetMessage = error.localizedDescription
            log("headset_inventory_failed", ["error": String(describing: error)])
        }
    }

    func setHeadsetConnection(_ headset: HeadsetState, connected: Bool) {
        guard !loading else { return }
        reloadHeadsets()
        guard headsetInventoryValid, let current = headsets.first(where: { $0.id == headset.id }) else { return }
        generation += 1
        loading = true; message = nil
        headsetAction = HeadsetAction(address: current.address, connecting: connected)
        beginHeadsetAction(current, connected: connected, token: generation)
    }

    private func beginHeadsetAction(_ headset: HeadsetState, connected: Bool, token: Int) {
        log("headset_connection_requested", ["connected": String(connected)])
        if connected {
            headsetOperations.connect(headset.address) { [weak self] result in
                self?.headsetConnected(result, address: headset.address, token: token)
            }
        } else {
            headsetOperations.disconnect(headset.address) { [weak self] result in
                self?.headsetActionFinished(result, token: token)
            }
        }
    }

    private func headsetConnected(_ result: Result<Void, Error>, address: String, token: Int) {
        guard token == generation else { return }
        if case .failure = result { headsetActionFinished(result, token: token); return }
        reloadHeadsets()
        guard headsetInventoryValid, let current = headsets.first(where: { $0.address == address && $0.isConnected }) else {
            headsetActionFinished(.failure(BoseSourcesError(code: "disconnected", detail: "QC35 disconnected")), token: token); return
        }
        do { try useHeadset(current) }
        catch { headsetActionFinished(.failure(error), token: token); return }
        headsetOperations.output(address) { [weak self] result in
            self?.headsetActionFinished(result, token: token)
        }
    }

    private func headsetActionFinished(_ result: Result<Void, Error>, token: Int) {
        guard token == generation else { return }
        loading = false; headsetAction = nil
        reloadHeadsets()
        if case .failure(let error) = result { report(error); return }
        refresh()
    }

    private func useHeadset(_ headset: HeadsetState) throws {
        guard headsets.filter({ $0.name == headset.name }).count == 1 else {
            throw BoseSourcesError(code: "ambiguous_headset", detail: "Give each QC35 a different Bluetooth name first")
        }
        guard headset.name != configuredHeadsetName else { return }
        try scopeLegacyCache()
        var config = try readConfig()
        config["headsetName"] = headset.name
        config["visibleSourceAddresses"] = [String]()
        try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys])
            .write(to: root.appendingPathComponent("config.json"), options: .atomic)
        try reloadOptions()
        clearSources()
    }

    private func refreshed(_ result: Result<[BoseSource], Error>, token: Int) {
        guard token == generation else { return }
        if case .failure(let error) = result, (error as? BoseSourcesError)?.code == "disconnected",
            let selectedAddress, selectedAddress != localAddress {
            loading = false // A remote handoff intentionally releases the Mac control link.
            message = nil
            return
        }
        receive(result, token: token)
    }

    private func receive(_ result: Result<[BoseSource], Error>, token: Int) {
        guard token == generation else { return }
        loading = false
        switch result {
        case .success(let devices): accept(devices)
        case .failure(let error):
            invalidateStatuses(); report(error)
            do { try clearSelection() }
            catch { report(error) }
        }
    }

    private func accept(_ devices: [BoseSource]) {
        localAddress = devices.first { $0.status == 3 }?.address ?? localAddress
        selectedAddress = BoseSource.exclusiveAddress(in: devices)
        sources = visibleAddresses.isEmpty ? devices : visibleAddresses.compactMap { address in devices.first { $0.address == address } }
        do {
            let data = CachedSources(headsetName: configuredHeadsetName, localAddress: localAddress, selectedAddress: selectedAddress, sources: devices)
            try JSONEncoder().encode(data).write(to: root.appendingPathComponent("ControlCenter/sources.json"), options: .atomic)
            log("devices_refreshed", ["count": String(devices.count)])
        } catch { report(error) }
    }

    func setOption(_ name: String, _ value: Bool) {
        do {
            guard name == "releaseOnSleep" || name == "avoidHeadsetMic" else { return }
            var data = try readConfig()
            data[name] = value
            try JSONSerialization.data(withJSONObject: data, options: [.prettyPrinted, .sortedKeys]).write(to: root.appendingPathComponent("config.json"), options: .atomic)
            try reloadOptions()
            log("option_saved", ["name": name, "value": String(value)])
            message = nil
        } catch { report(error) }
    }

    private func reloadOptions() throws {
        let data = try readConfig()
        guard let name = data["headsetName"] as? String, !name.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
        configuredHeadsetName = name
        releaseOnSleep = data["releaseOnSleep"] as? Bool ?? true
        avoidHeadsetMic = data["avoidHeadsetMic"] as? Bool ?? true
        visibleAddresses = data["visibleSourceAddresses"] as? [String] ?? []
    }

    private func readConfig() throws -> [String: Any] {
        guard let data = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("config.json"))) as? [String: Any] else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return data
    }

    private func loadCache() throws {
        try scopeLegacyCache()
        let path = root.appendingPathComponent("ControlCenter/sources.json")
        guard FileManager.default.fileExists(atPath: path.path) else { clearSources(); return }
        let cached = try JSONDecoder().decode(CachedSources.self, from: Data(contentsOf: path))
        guard cached.headsetName == configuredHeadsetName else {
            clearSources()
            return
        }
        localAddress = cached.localAddress
        selectedAddress = cached.selectedAddress
        let visible = visibleAddresses.isEmpty ? cached.sources : visibleAddresses.compactMap { address in cached.sources.first { $0.address == address } }
        sources = visible.map { BoseSource(address: $0.address, name: $0.name, status: -1) }
    }

    private func scopeLegacyCache() throws {
        guard !configuredHeadsetName.isEmpty else { return }
        let path = root.appendingPathComponent("ControlCenter/sources.json")
        guard let data = try? Data(contentsOf: path), let cached = try? JSONDecoder().decode(CachedSources.self, from: data), cached.headsetName == nil else { return }
        let scoped = CachedSources(headsetName: configuredHeadsetName, localAddress: cached.localAddress, selectedAddress: cached.selectedAddress, sources: cached.sources)
        try JSONEncoder().encode(scoped).write(to: path, options: .atomic)
    }

    private func clearSelection() throws {
        selectedAddress = nil
        let path = root.appendingPathComponent("ControlCenter/sources.json")
        guard FileManager.default.fileExists(atPath: path.path) else { return }
        let cached = try JSONDecoder().decode(CachedSources.self, from: Data(contentsOf: path))
        guard cached.headsetName == configuredHeadsetName else { return }
        let cleared = CachedSources(headsetName: cached.headsetName, localAddress: cached.localAddress, selectedAddress: nil, sources: cached.sources)
        try JSONEncoder().encode(cleared).write(to: path, options: .atomic)
    }

    func select(_ source: BoseSource) {
        guard !loading else { return }
        generation += 1
        loading = true
        message = nil
        let token = generation
        invalidateStatuses()
        log("handoff_requested", ["target": source.address == localAddress ? "mac" : "saved_source"])
        connection.connect { [weak self] result in self?.connected(result, source: source, token: token) }
    }

    private func connected(_ result: Result<Void, Error>, source: BoseSource, token: Int) {
        guard token == generation else { return }
        reloadHeadsets()
        if case .failure(let error) = result { receive(.failure(error), token: token); return }
        if source.address == localAddress {
            connection.activateOutput { [weak self] result in self?.beginHandoff(result, source: source, token: token) }
        } else { beginHandoff(.success(()), source: source, token: token) }
    }

    private func beginHandoff(_ result: Result<Void, Error>, source: BoseSource, token: Int) {
        guard token == generation else { return }
        if case .failure(let error) = result { receive(.failure(error), token: token); return }
        bluetooth.prepareHandoff(source) { [weak self] result in self?.prepareHandoff(result, source: source, token: token) }
    }

    private func prepareHandoff(_ result: Result<[BoseSource], Error>, source: BoseSource, token: Int) {
        guard token == generation else { return }
        guard case .success(let devices) = result else { receive(result, token: token); return }
        guard let local = devices.first(where: { $0.status == 3 }), let selected = devices.first(where: { $0.address == source.address }) else {
            failHandoff("Device is no longer available", token: token); return
        }
        localAddress = local.address
        guard selected.status == 1 || selected.status == 3 else { failHandoff("Selected device did not connect", token: token); return }
        releaseOtherConnection(devices, selected: selected, token: token)
    }

    private func releaseOtherConnection(_ devices: [BoseSource], selected: BoseSource, token: Int) {
        if selected.address == localAddress {
            finishMacHandoff(.success(devices), token: token)
        } else {
            connection.release { [weak self] result in self?.finishRemoteHandoff(result, devices: devices, token: token) }
        }
    }

    private func finishMacHandoff(_ result: Result<[BoseSource], Error>, token: Int) {
        guard token == generation else { return }
        guard case .success(let devices) = result else { receive(result, token: token); return }
        guard let localAddress, BoseSource.exclusiveAddress(in: devices) == localAddress else {
            failHandoff("The other device is still connected", token: token); return
        }
        log("handoff_complete", ["target": "mac", "exclusive": "true"])
        receive(.success(devices), token: token)
    }

    private func finishRemoteHandoff(_ result: Result<Void, Error>, devices: [BoseSource], token: Int) {
        guard token == generation else { return }
        reloadHeadsets()
        if case .failure(let error) = result { receive(.failure(error), token: token); return }
        let released = devices.map { BoseSource(address: $0.address, name: $0.name, status: $0.address == localAddress ? 0 : $0.status) }
        log("handoff_complete", ["target": "saved_source", "exclusive": "true"])
        receive(.success(released), token: token)
    }

    private func failHandoff(_ detail: String, token: Int) {
        receive(.failure(BoseSourcesError(code: "handoff_failed", detail: detail)), token: token)
    }

    func cancel(stopObservation: Bool = true) {
        generation += 1
        bluetooth.cancel()
        connection.cancel()
        if stopObservation { headsetMonitor?.stop() }
        loading = false
        headsetAction = nil
    }

    func pauseHeadsetObservation() { headsetMonitor?.stop() }

    func resumeHeadsetObservation() {
        headsetMonitor?.start()
        reloadHeadsets()
    }

    private func invalidateStatuses() { sources = sources.map { BoseSource(address: $0.address, name: $0.name, status: -1) } }

    private func clearSources() { sources = []; selectedAddress = nil; localAddress = nil }

    private func report(_ error: Error) {
        message = (error as? BoseSourcesError)?.code == "disconnected" ? "QC35 disconnected" : error.localizedDescription
        log("operation_failed", ["error": String(describing: error)])
    }

    private func log(_ event: String, _ fields: [String: String]) {
        var record = fields
        record["event"] = event
        guard let data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]) else { return }
        logger.info("\(String(decoding: data, as: UTF8.self), privacy: .public)")
    }

    struct HeadsetAction { let address: String; let connecting: Bool }
    struct HeadsetOperations {
        typealias Completion = (Result<Void, Error>) -> Void
        let connect: (String, @escaping Completion) -> Void
        let disconnect: (String, @escaping Completion) -> Void
        let output: (String, @escaping Completion) -> Void
    }
    private struct CachedSources: Codable { let headsetName: String?; let localAddress: String?; let selectedAddress: String?; let sources: [BoseSource] }
}

#if QC35_MODEL_TEST
extension QC35Model {
    static func verifySelectionCache() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("qc35-selection-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("ControlCenter"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let phone = BoseSource(address: "01:02:03:04:05:06", name: "Phone", status: 1)
        let cached = CachedSources(headsetName: "Bose QC35 II", localAddress: "07:08:09:0A:0B:0C", selectedAddress: phone.address, sources: [phone])
        try JSONEncoder().encode(cached).write(to: root.appendingPathComponent("ControlCenter/sources.json"))
        let model = QC35Model(root: root, inspectHeadsets: { _ in [] })
        model.configuredHeadsetName = "Bose QC35 II"
        try model.loadCache()
        guard model.selectedAddress == phone.address else { throw CocoaError(.fileReadCorruptFile) }
        model.receive(.failure(BoseSourcesError(code: "handoff_failed", detail: "Fixture connection failure")), token: 0)
        try model.loadCache()
        guard model.selectedAddress == nil else { throw CocoaError(.fileReadCorruptFile) }
        model.refreshed(.failure(BoseSourcesError(code: "disconnected", detail: "Fixture disconnected")), token: 0)
        guard model.selectedAddress == nil, model.message != nil else { throw CocoaError(.fileReadCorruptFile) }
    }

    static func verifyHeadsetState() throws -> Int {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("qc35-headsets-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("ControlCenter"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var checks = 0
        func check(_ condition: Bool, _ detail: String) throws {
            guard condition else { throw BoseSourcesError(code: "model_test_failed", detail: detail) }
            checks += 1
        }
        let first = HeadsetState(address: "AA:BB:CC:DD:EE:01", name: "Bose QC35 II", isConnected: false)
        let second = HeadsetState(address: "AA:BB:CC:DD:EE:02", name: "Travel QC35", isConnected: false)
        let phone = BoseSource(address: "01:02:03:04:05:06", name: "Phone", status: 1)
        let cacheURL = root.appendingPathComponent("ControlCenter/sources.json")
        let cache = CachedSources(headsetName: first.name, localAddress: "07:08:09:0A:0B:0C", selectedAddress: phone.address, sources: [phone])
        let config: [String: Any] = ["headsetName": first.name, "preferredInputName": "External mic", "fallbackInputName": "Built-in mic",
                                   "releaseOnSleep": false, "avoidHeadsetMic": true, "visibleSourceAddresses": [phone.address], "futureOption": "preserved"]
        try JSONSerialization.data(withJSONObject: config).write(to: root.appendingPathComponent("config.json"))
        try JSONEncoder().encode(cache).write(to: cacheURL)
        var inventory = [first, second]
        var unavailable = false
        let model = QC35Model(root: root, inspectHeadsets: { _ in
            if unavailable { throw HeadsetBluetoothError(code: "bluetooth_off", detail: "Bluetooth is off") }
            return inventory
        })
        model.refresh()
        try check(model.headsets == inventory && model.headsetInventoryValid && !model.loading, "Disconnected headsets should remain available")
        try check(model.selectedAddress == phone.address && model.sources.first?.status == -1, "Saved handoff should not imply live connectivity")

        model.loading = true
        let token = model.generation
        inventory[0] = HeadsetState(address: first.address, name: first.name, isConnected: true)
        model.reloadHeadsets()
        try check(model.headsets[0].isConnected && model.loading && model.generation == token, "Bluetooth event must not cancel an active handoff")
        try check(model.selectedAddress == phone.address, "Bluetooth event must not replace the handoff selection")
        unavailable = true
        model.reloadHeadsets()
        try check(!model.headsetInventoryValid && model.headsetMessage == "Bluetooth is off", "Power failure must invalidate live state")
        try check(model.headsets.count == 2, "Unavailable inventory should retain names for disabled rows")
        unavailable = false; inventory[0] = first; model.loading = false
        try Data("invalid cache".utf8).write(to: cacheURL)
        model.refresh()
        try check(model.headsetInventoryValid && model.headsets.count == 2 && model.sources.isEmpty, "Corrupt destination cache must not hide Bluetooth inventory")
        try FileManager.default.removeItem(at: cacheURL)
        model.refresh()
        try check(model.message == nil && model.headsets.count == 2 && model.sources.isEmpty, "Missing cache should allow a fresh Bluetooth-only panel")

        try JSONEncoder().encode(cache).write(to: cacheURL)
        try model.loadCache()
        try model.useHeadset(second)
        let updated = try model.readConfig()
        try check(updated["headsetName"] as? String == second.name && (updated["visibleSourceAddresses"] as? [String])?.isEmpty == true,
                  "Choosing another headset should change its configured target and reset destination filters")
        try check(updated["preferredInputName"] as? String == "External mic" && updated["fallbackInputName"] as? String == "Built-in mic"
                  && updated["releaseOnSleep"] as? Bool == false && updated["avoidHeadsetMic"] as? Bool == true
                  && updated["futureOption"] as? String == "preserved", "Choosing a headset must preserve microphone and other preferences")
        try model.loadCache()
        try check(model.sources.isEmpty && model.selectedAddress == nil && model.localAddress == nil, "Another headset must not inherit cached destinations")
        inventory = [second, HeadsetState(address: first.address, name: second.name, isConnected: false)]
        model.reloadHeadsets()
        var rejected = false
        do { try model.useHeadset(second) } catch { rejected = true }
        try check(rejected, "Duplicate headset names must fail before changing configuration or connecting")

        model.loading = true
        model.headsetAction = HeadsetAction(address: second.address, connecting: true)
        let staleToken = model.generation
        model.cancel()
        model.headsetConnected(.success(()), address: second.address, token: staleToken)
        model.headsetActionFinished(.failure(BoseSourcesError(code: "fixture", detail: "stale")), token: staleToken)
        try check(!model.loading && model.headsetAction == nil && model.message != "stale", "Cancelled action callbacks must not select output or change state")
        try JSONEncoder().encode(CachedSources(headsetName: nil, localAddress: cache.localAddress, selectedAddress: phone.address, sources: [phone])).write(to: cacheURL)
        model.configuredHeadsetName = first.name
        try model.loadCache()
        let migrated = try JSONDecoder().decode(CachedSources.self, from: Data(contentsOf: cacheURL))
        try check(migrated.headsetName == first.name && model.selectedAddress == phone.address, "Upgrade must preserve legacy handoff destinations for the original headset")
        model.configuredHeadsetName = second.name
        try model.loadCache()
        try check(model.sources.isEmpty, "Migrated cache must not leak into a different headset")
        return checks
    }

    static func verifyHeadsetActions() throws -> Int {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("qc35-actions-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("ControlCenter"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let configURL = root.appendingPathComponent("config.json")
        let original = Data(#"{"headsetName":"Home QC35","visibleSourceAddresses":["phone"],"avoidHeadsetMic":true}"#.utf8)
        try original.write(to: configURL)
        let home = HeadsetState(address: "AA:BB:CC:DD:EE:01", name: "Home QC35", isConnected: false)
        let travel = HeadsetState(address: "AA:BB:CC:DD:EE:02", name: "Travel QC35", isConnected: false)
        var inventory = [home, travel]
        var requests: [String] = []
        var completed: HeadsetOperations.Completion?
        var outputCompleted: HeadsetOperations.Completion?
        let operations = HeadsetOperations(
            connect: { requests.append("connect:\($0)"); completed = $1 },
            disconnect: { requests.append("disconnect:\($0)"); completed = $1 },
            output: { requests.append("output:\($0)"); outputCompleted = $1 })
        let model = QC35Model(root: root, inspectHeadsets: { _ in inventory }, headsetOperations: operations)
        var checks = 0
        func check(_ condition: Bool, _ detail: String) throws {
            guard condition else { throw BoseSourcesError(code: "action_test_failed", detail: detail) }
            checks += 1
        }
        model.refresh()
        model.setHeadsetConnection(travel, connected: true)
        try check(requests == ["connect:\(travel.address)"], "Connect must target the clicked paired Bluetooth address")
        try check(try Data(contentsOf: configURL) == original, "Pending connection must preserve active headset configuration")
        model.pauseHeadsetObservation(); model.resumeHeadsetObservation()
        try check(model.loading && model.headsetAction?.address == travel.address, "Restoring focus must preserve the pending operation")
        completed?(.failure(BoseSourcesError(code: "fixture_timeout", detail: "Connect timed out")))
        try check(try Data(contentsOf: configURL) == original && !model.loading, "Failed connection must preserve active configuration and source filter")

        model.setHeadsetConnection(travel, connected: true)
        inventory[1] = HeadsetState(address: travel.address, name: travel.name, isConnected: true)
        completed?(.success(()))
        try check(model.configuredHeadsetName == travel.name && requests.last == "output:\(travel.address)", "Successful connection should select the new headset and request its output")
        outputCompleted?(.failure(BoseSourcesError(code: "fixture_output", detail: "Output unavailable")))
        try check(model.headsets[1].isConnected && !model.loading && model.message == "Output unavailable", "An output error must not misreport the Bluetooth link as disconnected")

        try original.write(to: configURL)
        try model.reloadOptions()
        let duplicate = HeadsetState(address: travel.address, name: home.name, isConnected: false)
        inventory = [home, duplicate]
        model.setHeadsetConnection(duplicate, connected: true)
        try check(requests.last == "connect:\(duplicate.address)", "Same-name devices must still connect by address")
        inventory[1] = HeadsetState(address: duplicate.address, name: duplicate.name, isConnected: true)
        let count = requests.count
        completed?(.success(()))
        try check(requests.count == count && model.headsets[1].isConnected && model.message?.contains("different Bluetooth name") == true,
                  "Ambiguous names may connect but must not route audio or change the helper target")
        try check(try Data(contentsOf: configURL) == original, "Ambiguous connection must preserve prior configuration")
        model.setHeadsetConnection(inventory[1], connected: false)
        try check(requests.last == "disconnect:\(duplicate.address)", "Disconnect must target the clicked headset")
        inventory = [home, duplicate]
        completed?(.success(()))
        try check(!model.loading && !model.headsets[1].isConnected, "Confirmed disconnect should update live inventory")
        model.setHeadsetConnection(duplicate, connected: true)
        model.cancel()
        let cancelledCount = requests.count
        completed?(.success(()))
        try check(requests.count == cancelledCount && !model.loading, "Late completion after close must not activate output")
        return checks
    }
}

@main private struct QC35SelectionCacheTests {
    @MainActor static func main() throws {
        try QC35Model.verifySelectionCache()
        let checks = try QC35Model.verifyHeadsetState() + QC35Model.verifyHeadsetActions() + 3
        print("{\"modelTests\":\"passed\",\"checks\":\(checks),\"nativeIO\":false}")
    }
}
#endif

import Foundation
import Combine
import OSLog
