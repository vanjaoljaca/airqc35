@MainActor
final class MacConnection: NSObject {
    private var completion: ((Result<Void, Error>) -> Void)?
    private var device: IOBluetoothDevice?
    private var deadline: DispatchWorkItem?

    func connect(completion: @escaping (Result<Void, Error>) -> Void) {
        guard self.completion == nil else { completion(.failure(failure("QC35 connection in progress"))); return }
        self.completion = completion
        do { try begin() }
        catch { finish(.failure(error)) }
    }

    private func begin() throws {
        let target = try resolve()
        if target.isConnected() { finish(.success(())); return }
        device = target
        armDeadline()
        let status = target.openConnection(self, withPageTimeout: 8192, authenticationRequired: true)
        guard status == kIOReturnSuccess else { throw failure("Connect QC35: \(status)") }
    }

    private func resolve() throws -> IOBluetoothDevice {
        let path = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/QC35InputGuard/config.json")
        let config = try JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any]
        guard let name = config?["headsetName"] as? String else { throw failure("QC35 configuration unavailable") }
        let matches = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] ?? []).filter { $0.name == name }
        guard matches.count == 1 else { throw failure("QC35 must match one paired device") }
        return matches[0]
    }

    private func armDeadline() {
        let work = DispatchWorkItem { [weak self] in self?.finish(.failure(self?.failure("QC35 did not connect") ?? CocoaError(.fileReadUnknown))) }
        deadline = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: work)
    }

    @objc func connectionComplete(_ device: IOBluetoothDevice!, status: IOReturn) {
        guard device?.addressString == self.device?.addressString, completion != nil else { return }
        guard status == kIOReturnSuccess, device.isConnected() else { finish(.failure(failure("QC35 did not connect"))); return }
        finish(.success(()))
    }

    private func finish(_ result: Result<Void, Error>) {
        let callback = completion
        completion = nil
        deadline?.cancel(); deadline = nil
        device = nil
        callback?(result)
    }

    private func failure(_ detail: String) -> BoseSourcesError { BoseSourcesError(code: "mac_connect_failed", detail: detail) }
}

import Foundation
import IOBluetooth
