@MainActor
final class QC35Model: ObservableObject {
    @Published private(set) var sources: [BoseSource] = []
    @Published private(set) var loading = false
    @Published private(set) var releaseOnSleep = true
    @Published private(set) var avoidHeadsetMic = true
    @Published private(set) var message: String?
    private let bluetooth = BoseSources()
    private let connection = MacConnection()
    private let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/QC35InputGuard")
    private var localAddress: String?
    private var visibleAddresses: [String] = []
    private var generation = 0
    private let logger = Logger(subsystem: "com.vanja.qc35.control", category: "actions")

    func refresh() {
        cancel()
        do { try reloadOptions(); try loadCache() }
        catch { report(error); return }
        loading = true
        message = nil
        let token = generation
        bluetooth.load { [weak self] result in self?.receive(result, token: token) }
    }

    private func receive(_ result: Result<[BoseSource], Error>, token: Int) {
        guard token == generation else { return }
        loading = false
        switch result {
        case .success(let devices): accept(devices)
        case .failure(let error): invalidateStatuses(); report(error)
        }
    }

    private func accept(_ devices: [BoseSource]) {
        localAddress = devices.first { $0.status == 3 }?.address ?? localAddress
        sources = visibleAddresses.isEmpty ? devices : visibleAddresses.compactMap { address in devices.first { $0.address == address } }
        do {
            let data = CachedSources(localAddress: localAddress, sources: devices)
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
        let visible = visibleAddresses.isEmpty ? cached.sources : visibleAddresses.compactMap { address in cached.sources.first { $0.address == address } }
        sources = visible.map { BoseSource(address: $0.address, name: $0.name, status: -1) }
    }

    func select(_ source: BoseSource) {
        guard !loading else { return }
        generation += 1
        loading = true
        message = nil
        let token = generation
        invalidateStatuses()
        log("reconnect_requested", ["target": source.address == localAddress ? "mac" : "saved_source"])
        connection.connect { [weak self] result in self?.connected(result, source: source, token: token) }
    }

    private func connected(_ result: Result<Void, Error>, source: BoseSource, token: Int) {
        guard token == generation else { return }
        if case .failure(let error) = result { receive(.failure(error), token: token); return }
        let completion: (Result<[BoseSource], Error>) -> Void = { [weak self] result in self?.receive(result, token: token) }
        if source.address == localAddress { bluetooth.load(completion: completion) }
        else { bluetooth.connect(source, completion: completion) }
    }

    func cancel() {
        generation += 1
        bluetooth.cancel()
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

    private struct CachedSources: Codable { let localAddress: String?; let sources: [BoseSource] }
}

import Foundation
import Combine
import OSLog
