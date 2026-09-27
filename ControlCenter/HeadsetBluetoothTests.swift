#if HEADSET_BLUETOOTH_TEST
@main
private struct HeadsetBluetoothTests {
    @MainActor static func main() {
        do {
            try inventoryTests()
            try eventTests()
            print(#"{"event":"headset_bluetooth_tests_passed","count":14,"hardwareWrites":0}"#)
        } catch {
            let record = ["event": "headset_bluetooth_tests_failed", "error": error.localizedDescription]
            let data = try! JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]) + Data([10])
            FileHandle.standardError.write(data)
            exit(1)
        }
    }

    private static func inventoryTests() throws {
        try filtersModelsAndConfiguredName()
        try preservesSameNamesWithDifferentAddresses()
        try deduplicatesAddressSpellings()
        try rejectsConflictingSnapshots()
        try rejectsInvalidHeadsetAddress()
        try preservesLiveConnectionValues()
        try acceptsEmptyPairingList()
        try distinguishesUnavailableRadio()
    }

    private static func filtersModelsAndConfiguredName() throws {
        let names = ["Bose QC35 II", "quietcomfort35", "QC 35", "QC35II", "Travel Headphones", "QC45", "QC350", "Keyboard"]
        let entries = names.enumerated().map { state($0.element, suffix: $0.offset) }
        let selected = try HeadsetInventory.snapshot(entries, configuredName: "Travel Headphones")
        try require(Set(selected.map(\.name)) == Set(names.prefix(5)), "Model or renamed-headset filter changed")
        try require(!HeadsetInventory.includes("Travel Headphones", configuredName: "travel headphones"), "Exact configured-name rule changed")
    }

    private static func preservesSameNamesWithDifferentAddresses() throws {
        let entries = [state("Bose QC35 II", suffix: 2), state("Bose QC35 II", suffix: 1)]
        let selected = try HeadsetInventory.snapshot(entries, configuredName: "")
        try require(selected.map(\.id) == [entries[1].address, entries[0].address], "Same-name headsets lost identity or stable order")
    }

    private static func deduplicatesAddressSpellings() throws {
        let first = HeadsetState(address: "aa-bb-cc-dd-ee-ff", name: "QC35", isConnected: true)
        let second = HeadsetState(address: "AA:BB:CC:DD:EE:FF", name: "QC35", isConnected: true)
        let selected = try HeadsetInventory.snapshot([first, second], configuredName: "")
        try require(selected == [second] && selected[0].id == second.address, "Address normalization did not deduplicate")
    }

    private static func rejectsConflictingSnapshots() throws {
        let initial = state("QC35", suffix: 1)
        for other in [HeadsetState(address: initial.address, name: initial.name, isConnected: true),
                      HeadsetState(address: initial.address, name: "QC35 II", isConnected: false)] {
            try requireError("conflicting_device") { _ = try HeadsetInventory.snapshot([initial, other], configuredName: "") }
        }
    }

    private static func rejectsInvalidHeadsetAddress() throws {
        for address in ["", "AA:BB:CC:DD:EE", "AA:BB:CC:DD:EE:GG", "A:BB:CC:DD:EE:FF"] {
            try requireError("invalid_address") {
                _ = try HeadsetInventory.snapshot([HeadsetState(address: address, name: "QC35", isConnected: false)], configuredName: "")
            }
        }
        let unrelated = HeadsetState(address: "", name: "Unrelated device", isConnected: false)
        try require(try HeadsetInventory.snapshot([unrelated], configuredName: "").isEmpty, "Unrelated device blocked inventory")
    }

    private static func preservesLiveConnectionValues() throws {
        let first = HeadsetState(address: "00:11:22:33:44:55", name: "QC35", isConnected: true)
        let second = HeadsetState(address: first.address, name: first.name, isConnected: false)
        try require(try HeadsetInventory.snapshot([first], configuredName: "") == [first], "Connected snapshot changed")
        try require(try HeadsetInventory.snapshot([second], configuredName: "") == [second], "Old connected status survived new snapshot")
    }

    private static func acceptsEmptyPairingList() throws {
        try HeadsetInventory.requireAvailable(1)
        try require(try HeadsetInventory.snapshot([], configuredName: "QC35").isEmpty, "Empty pairing list was invented")
    }

    private static func distinguishesUnavailableRadio() throws {
        try requireError("bluetooth_off") { try HeadsetInventory.requireAvailable(0) }
        try requireError("bluetooth_unavailable") { try HeadsetInventory.requireAvailable(nil) }
        try requireError("bluetooth_unavailable") { try HeadsetInventory.requireAvailable(0xFF) }
        try HeadsetInventory.requireAvailable(1)
    }

    @MainActor private static func eventTests() throws {
        try coalescesEventBurst()
        try acceptsNextEventAfterDelivery()
        try dropsStoppedCallbacks()
        try dropsOldSessionWithoutClearingNewWork()
        try deliversReentrantEventSeparately()
        try releasesPendingOwner()
    }

    @MainActor private static func coalescesEventBurst() throws {
        let fixture = EventFixture()
        let token = fixture.start()
        for _ in 0..<10 { fixture.delivery.signal(token) }
        try require(fixture.queue.count == 1, "Event burst queued duplicate refreshes")
        fixture.tick()
        try require(fixture.deliveries == 1, "Event burst did not deliver once")
    }

    @MainActor private static func acceptsNextEventAfterDelivery() throws {
        let fixture = EventFixture()
        let token = fixture.start()
        fixture.delivery.signal(token); fixture.tick()
        fixture.delivery.signal(token); fixture.tick()
        try require(fixture.deliveries == 2, "Monitoring stopped after first change")
    }

    @MainActor private static func dropsStoppedCallbacks() throws {
        let fixture = EventFixture()
        let token = fixture.start()
        fixture.delivery.signal(token); fixture.delivery.stop(); fixture.tick()
        fixture.delivery.signal(token)
        try require(fixture.deliveries == 0 && fixture.queue.isEmpty, "Stopped monitoring delivered stale change")
    }

    @MainActor private static func dropsOldSessionWithoutClearingNewWork() throws {
        let fixture = EventFixture()
        let old = fixture.start(); fixture.delivery.signal(old)
        let current = fixture.start(); fixture.delivery.signal(current)
        fixture.tick(); fixture.delivery.signal(old); fixture.delivery.signal(current)
        try require(fixture.deliveries == 0 && fixture.queue.count == 1, "Old session disturbed pending current refresh")
        fixture.tick()
        try require(fixture.deliveries == 1, "Current session did not deliver")
    }

    @MainActor private static func deliversReentrantEventSeparately() throws {
        let fixture = EventFixture()
        var token = 0
        token = fixture.delivery.start {
            fixture.deliveries += 1
            if fixture.deliveries == 1 { fixture.delivery.signal(token) }
        }
        fixture.delivery.signal(token); fixture.tick(); fixture.tick()
        try require(fixture.deliveries == 2, "Change during delivery was lost")
        fixture.delivery.stop()
    }

    @MainActor private static func releasesPendingOwner() throws {
        var work: (() -> Void)?
        var calls = 0
        var delivery: HeadsetEventDelivery? = HeadsetEventDelivery { work = $0; return DispatchWorkItem(block: {}) }
        weak let weakDelivery = delivery
        let token = delivery!.start { calls += 1 }
        delivery!.signal(token); delivery = nil; work?()
        try require(weakDelivery == nil && calls == 0, "Queued change retained or called a released owner")
    }

    private static func state(_ name: String, suffix: Int) -> HeadsetState {
        HeadsetState(address: String(format: "00:11:22:33:44:%02X", suffix), name: name, isConnected: false)
    }

    private static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw HeadsetBluetoothError(code: "test_failed", detail: message) }
    }

    private static func requireError(_ code: String, _ operation: () throws -> Void) throws {
        do { try operation() }
        catch let error as HeadsetBluetoothError where error.code == code { return }
        throw HeadsetBluetoothError(code: "test_failed", detail: "Expected error: \(code)")
    }
}

@MainActor
private final class EventFixture {
    var queue: [() -> Void] = []
    var deliveries = 0
    lazy var delivery = HeadsetEventDelivery { [unowned self] callback in
        queue.append(callback)
        return DispatchWorkItem(block: {})
    }

    func start() -> Int { delivery.start { [weak self] in self?.deliveries += 1 } }
    // Execute cancelled work too: the session guard must make it harmless.
    func tick() { if !queue.isEmpty { queue.removeFirst()() } }
}
#endif

import Foundation
