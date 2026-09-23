@MainActor
final class QC35Model: ObservableObject {
    @Published private(set) var sources: [BoseSource] = []
    @Published private(set) var loading = false
    @Published private(set) var releaseOnSleep = true
    @Published private(set) var avoidHeadsetMic = true
    @Published private(set) var message: String?
    @Published private(set) var selectedAddress: String?
    private let bluetooth = BoseSources()
    private let connection = MacConnection()
    private let root: URL
    private var localAddress: String?
    private var visibleAddresses: [String] = []
    private var generation = 0
    private let logger = Logger(subsystem: "com.vanja.qc35.control", category: "actions")

    init(root: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/QC35InputGuard")) {
        self.root = root
    }

    func refresh() {
        cancel()
        do { try reloadOptions(); try loadCache() }
        catch { report(error); return }
        loading = true
        message = nil
        let token = generation
        bluetooth.load { [weak self] result in self?.refreshed(result, token: token) }
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
            let data = CachedSources(localAddress: localAddress, selectedAddress: selectedAddress, sources: devices)
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
        let path = root.appendingPathComponent("ControlCenter/sources.json")
        guard FileManager.default.fileExists(atPath: path.path) else { return }
        let cached = try JSONDecoder().decode(CachedSources.self, from: Data(contentsOf: path))
        localAddress = cached.localAddress
        selectedAddress = cached.selectedAddress
        let visible = visibleAddresses.isEmpty ? cached.sources : visibleAddresses.compactMap { address in cached.sources.first { $0.address == address } }
        sources = visible.map { BoseSource(address: $0.address, name: $0.name, status: -1) }
    }

    private func clearSelection() throws {
        selectedAddress = nil
        let path = root.appendingPathComponent("ControlCenter/sources.json")
        guard FileManager.default.fileExists(atPath: path.path) else { return }
        let cached = try JSONDecoder().decode(CachedSources.self, from: Data(contentsOf: path))
        let cleared = CachedSources(localAddress: cached.localAddress, selectedAddress: nil, sources: cached.sources)
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
        if case .failure(let error) = result { receive(.failure(error), token: token); return }
        let released = devices.map { BoseSource(address: $0.address, name: $0.name, status: $0.address == localAddress ? 0 : $0.status) }
        log("handoff_complete", ["target": "saved_source", "exclusive": "true"])
        receive(.success(released), token: token)
    }

    private func failHandoff(_ detail: String, token: Int) {
        receive(.failure(BoseSourcesError(code: "handoff_failed", detail: detail)), token: token)
    }

    func cancel() {
        generation += 1
        bluetooth.cancel()
        connection.cancel()
        loading = false
    }

    private func invalidateStatuses() { sources = sources.map { BoseSource(address: $0.address, name: $0.name, status: -1) } }

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

    private struct CachedSources: Codable { let localAddress: String?; let selectedAddress: String?; let sources: [BoseSource] }
}

#if QC35_MODEL_TEST
extension QC35Model {
    static func verifySelectionCache() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("qc35-selection-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("ControlCenter"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let phone = BoseSource(address: "01:02:03:04:05:06", name: "Phone", status: 1)
        let cached = CachedSources(localAddress: "07:08:09:0A:0B:0C", selectedAddress: phone.address, sources: [phone])
        try JSONEncoder().encode(cached).write(to: root.appendingPathComponent("ControlCenter/sources.json"))
        let model = QC35Model(root: root)
        try model.loadCache()
        guard model.selectedAddress == phone.address else { throw CocoaError(.fileReadCorruptFile) }
        model.receive(.failure(BoseSourcesError(code: "handoff_failed", detail: "Fixture connection failure")), token: 0)
        try model.loadCache()
        guard model.selectedAddress == nil else { throw CocoaError(.fileReadCorruptFile) }
        model.refreshed(.failure(BoseSourcesError(code: "disconnected", detail: "Fixture disconnected")), token: 0)
        guard model.selectedAddress == nil, model.message != nil else { throw CocoaError(.fileReadCorruptFile) }
    }
}

@main private struct QC35SelectionCacheTests {
    @MainActor static func main() throws {
        try QC35Model.verifySelectionCache()
        print("{\"selectionCacheTests\":\"passed\",\"checks\":3}")
    }
}
#endif

import Foundation
import Combine
import OSLog
