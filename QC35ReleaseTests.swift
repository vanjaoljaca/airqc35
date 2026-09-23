final class FakeHeadset: HeadsetConnection {
    let identifier: String
    var connected = true
    var remainsConnected = false
    var status: IOReturn = 0
    var closes = 0
    init(_ identifier: String = "qc35") { self.identifier = identifier }
    func disconnect() -> IOReturn {
        closes += 1
        connected = remainsConnected
        return status
    }
}

final class ReleaseFixture {
    let device = FakeHeadset()
    var target: HeadsetConnection?
    var failure: Error?
    var scheduled: [() -> Void] = []
    var events: [(String, [String: String])] = []
    init() { target = device }

    lazy var release = ConnectionRelease(resolve: { [unowned self] in
        if let failure { throw failure }
        return target
    }, schedule: { [unowned self] action in
        scheduled.append(action)
        return DispatchWorkItem(block: {})
    }, emit: { [unowned self] name, fields in events.append((name, fields)) })

    func receive(_ state: MacAvailability) { release.update(state, reason: "test") }
    // Fire even cancelled work to prove the generation guard, not the fake scheduler.
    func tick() { if !scheduled.isEmpty { scheduled.removeFirst()() } }
}

func require(_ condition: Bool, _ message: String) throws {
    if !condition { throw AudioFailure(description: message) }
}

func runReleaseTests() {
    let awake = MacAvailability(lidClosed: false, displaysAsleep: false)
    let closed = MacAvailability(lidClosed: true, displaysAsleep: false)
    var passed = 0
    func test(_ name: String, _ body: () throws -> Void) {
        do { try body(); passed += 1; print("PASS \(name)") }
        catch { fputs("FAIL \(name): \(error)\n", stderr); exit(1) }
    }
    test("startup open/awake preserves connection") {
        let f = ReleaseFixture(); f.receive(awake)
        try require(f.device.connected && f.device.closes == 0, "Unexpected disconnect")
    }
    test("startup closed with external display awake releases") {
        let f = ReleaseFixture(); f.receive(closed)
        try require(!f.device.connected && f.device.closes == 1, "Closed lid not released")
    }
    test("display sleep with open lid releases") {
        let f = ReleaseFixture(); f.receive(MacAvailability(lidClosed: false, displaysAsleep: true))
        try require(f.device.closes == 1, "Display sleep not released")
    }
    test("system willSleep independently releases") {
        let f = ReleaseFixture(); f.receive(MacAvailability(lidClosed: false, displaysAsleep: false, systemSleeping: true))
        try require(f.device.closes == 1, "System sleep not released")
    }
    test("unknown initial snapshots do not disconnect") {
        let f = ReleaseFixture(); f.receive(MacAvailability())
        try require(f.device.closes == 0, "Unknown was treated as sleep")
    }
    test("lid open cannot clear sleeping displays") {
        let f = ReleaseFixture(); f.receive(MacAvailability(lidClosed: true, displaysAsleep: true))
        f.receive(MacAvailability(lidClosed: false, displaysAsleep: true))
        f.device.connected = true; f.release.connected("qc35")
        try require(f.device.closes == 2, "Display sleep was cleared by lid open")
    }
    test("system wake cannot clear physical closed lid") {
        let f = ReleaseFixture(); f.receive(MacAvailability(lidClosed: true, displaysAsleep: false, systemSleeping: true))
        f.receive(closed); f.device.connected = true; f.release.connected("qc35")
        try require(f.device.closes == 2, "Wake cleared physical lid")
    }
    test("incoming address filtering and reactive re-release") {
        let f = ReleaseFixture(); f.receive(closed); f.device.connected = true
        f.release.connected("keyboard")
        try require(f.device.closes == 1 && f.device.connected, "Touched unrelated connection")
        f.release.connected("qc35")
        try require(f.device.closes == 2 && !f.device.connected, "Reconnection not released")
    }
    test("incoming while awake and wake itself never write Bluetooth") {
        let f = ReleaseFixture(); f.receive(closed); f.receive(awake)
        try require(!f.device.connected, "Wake reconnected")
        f.device.connected = true; f.release.connected("qc35")
        try require(f.device.closes == 1 && f.device.connected, "Awake connection was released")
    }
    test("three attempts maximum; duplicate state cannot restart budget") {
        let f = ReleaseFixture(); f.device.remainsConnected = true; f.receive(closed)
        f.tick(); f.receive(closed); f.tick(); f.tick(); f.receive(closed)
        try require(f.device.closes == 3 && f.scheduled.isEmpty, "Retry budget exceeded")
        try require(f.events.contains { $0.0 == "release_exhausted" }, "Missing exhausted state")
    }
    test("wake invalidates queued failure retry") {
        let f = ReleaseFixture(); f.device.remainsConnected = true; f.receive(closed)
        f.receive(awake); f.tick()
        try require(f.device.closes == 1, "Stale retry disconnected after wake")
    }
    test("retry refresh detects wake before queued workspace event") {
        let f = ReleaseFixture(); f.device.remainsConnected = true; f.receive(closed)
        f.release.refreshBeforeRetry = { [unowned f] in f.receive(awake) }; f.tick()
        try require(f.device.closes == 1, "Retry ignored fresh availability")
    }
    test("configuration change invalidates previous address work") {
        let f = ReleaseFixture(); f.device.remainsConnected = true; f.receive(closed)
        let other = FakeHeadset("new-configured-device"); f.target = other
        var config = Settings(); config.headsetName = "new-configured-device"
        f.release.configurationChanged(config); f.tick()
        try require(f.device.closes == 1 && other.closes == 1, "Stale config work acted")
    }
    test("unannounced resolution change cannot redirect a retry") {
        let f = ReleaseFixture(); f.device.remainsConnected = true; f.receive(closed)
        let other = FakeHeadset("other-device"); f.target = other; f.tick()
        try require(f.device.closes == 1 && other.closes == 0, "Retry redirected to another device")
    }
    test("missing and ambiguous resolution never disconnect") {
        let missing = ReleaseFixture(); missing.target = nil; missing.receive(closed)
        let ambiguous = ReleaseFixture(); ambiguous.failure = AudioFailure(description: "Ambiguous paired headset")
        ambiguous.receive(closed); ambiguous.release.connected("qc35")
        try require(missing.device.closes == 0 && ambiguous.device.closes == 0, "Invalid resolution wrote Bluetooth")
    }
    test("API success without observed disconnect is not verified") {
        let f = ReleaseFixture(); f.device.remainsConnected = true; f.receive(closed)
        try require(!f.events.contains { $0.0 == "release_verified" }, "False verified claim")
        try require(f.scheduled.count == 1, "Unverified close not retried")
    }
    test("observed disconnect is recorded with actual API status") {
        let f = ReleaseFixture(); f.device.status = -1; f.receive(closed)
        try require(f.events.contains { $0.0 == "release_verified" && $0.1["status"] == "-1" && $0.1["connectedAfter"] == "false" }, "Lost readback or status")
        try require(f.scheduled.isEmpty, "Retried an already disconnected device")
    }
    test("already disconnected is left alone") {
        let f = ReleaseFixture(); f.device.connected = false; f.receive(closed)
        try require(f.device.closes == 0 && f.scheduled.isEmpty, "Wrote Bluetooth for absent connection")
    }
    test("old configuration defaults both options to enabled") {
        let config = try JSONDecoder().decode(Settings.self, from: legacyConfiguration())
        try require(config.releaseOnSleep && config.avoidHeadsetMic, "Legacy behavior changed")
        try require(config.preferredInput == "Wireless microphone", "Preferred input changed")
    }
    test("explicit false options survive decoding") {
        var values = try configurationDictionary(legacyConfiguration())
        values["releaseOnSleep"] = false; values["avoidHeadsetMic"] = false
        let config = try JSONDecoder().decode(Settings.self, from: JSONSerialization.data(withJSONObject: values))
        try require(!config.releaseOnSleep && !config.avoidHeadsetMic, "False options became defaults")
    }
    test("release disabled on startup preserves connection and incoming events") {
        let f = ReleaseFixture(); var config = Settings(); config.releaseOnSleep = false
        f.release.configurationChanged(config); f.receive(closed); f.release.connected("qc35")
        try require(f.device.closes == 0 && f.scheduled.isEmpty, "Disabled release wrote Bluetooth")
    }
    test("disabling release cancels queued failure retry") {
        let f = ReleaseFixture(); f.device.remainsConnected = true; f.receive(closed)
        var config = Settings(); config.releaseOnSleep = false
        f.release.configurationChanged(config); f.tick(); f.release.connected("qc35")
        try require(f.device.closes == 1 && f.scheduled.isEmpty, "Disabled release let stale work run")
    }
    test("enabling release while already unavailable acts immediately") {
        let f = ReleaseFixture(); var config = Settings(); config.releaseOnSleep = false
        f.release.configurationChanged(config); f.receive(closed)
        config.releaseOnSleep = true; f.release.configurationChanged(config)
        try require(f.device.closes == 1 && !f.device.connected, "Enable did not release immediately")
    }
    test("enabling while awake never disconnects") {
        let f = ReleaseFixture(); var config = Settings(); config.releaseOnSleep = false
        f.release.configurationChanged(config); f.receive(awake)
        config.releaseOnSleep = true; f.release.configurationChanged(config)
        try require(f.device.closes == 0, "Enable while awake disconnected")
    }
    test("duplicate reloads and mic changes do not reset release budget") {
        let f = ReleaseFixture(); f.device.remainsConnected = true; f.receive(closed)
        var config = Settings(); f.release.configurationChanged(config); f.tick()
        config.avoidHeadsetMic = false; f.release.configurationChanged(config); f.tick()
        f.release.configurationChanged(config); f.tick()
        try require(f.device.closes == 3 && f.scheduled.isEmpty, "Config noise reset retry budget")
    }
    test("release disable then enable invalidates old retry generation") {
        let f = ReleaseFixture(); f.device.remainsConnected = true; f.receive(closed)
        var config = Settings(); config.releaseOnSleep = false; f.release.configurationChanged(config)
        config.releaseOnSleep = true; f.release.configurationChanged(config); f.tick()
        try require(f.device.closes == 2, "Old generation acted after re-enable")
        f.tick(); f.tick(); f.tick()
        try require(f.device.closes == 4 && f.scheduled.isEmpty, "New generation lost bounded budget")
    }
    test("mic option off prevents input writes without changing preferred fallback") {
        var config = Settings(); config.preferredInput = "Wireless microphone"; config.avoidHeadsetMic = false
        var writes: [AudioDeviceID] = []; var states: [String] = []
        try restoreMicrophone(fakeAudioDevices(), config, apply: { target, _ in writes.append(target.id) }, state: { name, _ in states.append(name) })
        try require(writes.isEmpty && states == ["mic_guard_disabled"], "Disabled mic guard attempted a write")
        config.avoidHeadsetMic = true
        try restoreMicrophone(fakeAudioDevices(), config, apply: { target, _ in writes.append(target.id) }, state: { _, _ in })
        try require(writes == [2], "Re-enabled guard did not use preferred microphone")
    }
    test("enabled mic retains fallback and ambiguous-name behavior") {
        var config = Settings(); config.preferredInput = "Unavailable microphone"
        var writes: [(AudioDeviceID, Bool)] = []; var states: [String] = []
        try restoreMicrophone(fakeAudioDevices(), config, apply: { writes.append(($0.id, $1)) }, state: { name, _ in states.append(name) })
        try require(writes.count == 1 && writes[0].0 == 3 && writes[0].1, "Fallback changed")
        let duplicate = fakeAudioDevices() + [Device(id: 4, name: config.fallbackInput, input: true, alive: true)]
        try restoreMicrophone(duplicate, config, apply: { writes.append(($0.id, $1)) }, state: { name, _ in states.append(name) })
        try require(writes.count == 1 && states.last == "no_unique_safe_input", "Ambiguous fallback was selected")
    }
    test("save preserves unknown nested JSON values") {
        let directory = try configurationTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("settings.json")
        try legacyConfiguration().write(to: file, options: .atomic)
        var config = try JSONDecoder().decode(Settings.self, from: Data(contentsOf: file)); config.releaseOnSleep = false
        try save(config, to: file)
        let values = try configurationDictionary(Data(contentsOf: file))
        try require((values["future"] as? [String: String])?["keep"] == "yes", "Unknown nested data was lost")
        try require(values["releaseOnSleep"] as? Bool == false, "Option was not written")
    }
    test("option command changes only requested field and keeps unrelated JSON") {
        let directory = try configurationTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("settings.json")
        try legacyConfiguration().write(to: file, options: .atomic)
        try changeOption(["avoidHeadsetMic", "false"], at: file)
        let values = try configurationDictionary(Data(contentsOf: file))
        try require(values["avoidHeadsetMic"] as? Bool == false && values["releaseOnSleep"] == nil, "Option touched another field")
        try require(values["preferredInput"] as? String == "Wireless microphone" && values["future"] != nil, "Option lost preferences or extra fields")
    }
    test("option parser rejects nonexact keys and booleans before writing") {
        let invalid = [[], ["releaseOnSleep"], ["unknown", "true"], ["releaseOnSleep", "TRUE"], ["releaseOnSleep", "1"], ["avoidHeadsetMic", "false", "extra"]]
        for args in invalid {
            var rejected = false
            do { _ = try optionChange(args) } catch { rejected = true }
            try require(rejected, "Invalid option arguments accepted: \(args)")
        }
    }
    print("{\"event\":\"release_regressions_passed\",\"count\":\(passed),\"hardwareWrites\":0}")
}

func configurationTestDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("qc35-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    return directory
}

func legacyConfiguration() -> Data {
    Data(#"{"preferredInput":"Wireless microphone","fallbackInput":"MacBook Pro Microphone","headsetName":"Bose QC35 II","future":{"keep":"yes"}}"#.utf8)
}

func configurationDictionary(_ data: Data) throws -> [String: Any] {
    guard let values = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw AudioFailure(description: "Test configuration was not an object")
    }
    return values
}

func fakeAudioDevices() -> [Device] {
    [Device(id: 1, name: "Bose QC35 II", input: true, alive: true),
     Device(id: 2, name: "Wireless microphone", input: true, alive: true),
     Device(id: 3, name: "MacBook Pro Microphone", input: true, alive: true)]
}

import Foundation
import IOKit
import CoreAudio
