struct QC35View: View {
    @ObservedObject var model: QC35Model
    var heightChanged: (CGFloat) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            VStack(alignment: .leading, spacing: 6) {
                Text("Bluetooth").font(.subheadline.weight(.medium))
                headsets
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Device").font(.subheadline.weight(.medium)).foregroundStyle(.primary)
                devices
            }
            Divider().opacity(0.5)
            option("Lid release", symbol: "eject", value: model.releaseOnSleep, key: "releaseOnSleep")
            option("Avoid headset mic", symbol: "mic.slash", value: model.avoidHeadsetMic, key: "avoidHeadsetMic")
            if let message = model.message {
                Text(message).font(.caption).foregroundStyle(.secondary).lineLimit(3).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(20)
        .frame(width: 320)
        .fixedSize(horizontal: false, vertical: true)
        .background(GeometryReader { proxy in Color.clear.preference(key: PanelHeight.self, value: proxy.size.height) })
        .onPreferenceChange(PanelHeight.self, perform: heightChanged)
    }

    private var headsets: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !model.headsets.isEmpty {
                ScrollView {
                    VStack(spacing: 4) { ForEach(model.headsets) { headset in headsetRow(headset) } }
                }
                .scrollIndicators(.hidden)
                .frame(height: min(CGFloat(model.headsets.count) * 60 - 4, 176))
            } else if model.headsetMessage == nil {
                Text("No paired QC35").font(.subheadline).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).padding(.horizontal, 10)
            }
            if let message = model.headsetMessage {
                Text(message).font(.caption).foregroundStyle(.secondary).lineLimit(3)
            }
        }
    }

    private func headsetRow(_ headset: HeadsetState) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "headphones").font(.system(size: 18)).frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(headset.name).lineLimit(1)
                Text(headsetStatus(headset)).font(.caption).foregroundStyle(.secondary)
                if model.headsets.filter({ $0.name == headset.name }).count > 1 {
                    Text(headset.address.suffix(8)).font(.caption2.monospaced()).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 4)
            Button(headset.isConnected ? "Disconnect" : "Connect") {
                model.setHeadsetConnection(headset, connected: !headset.isConnected)
            }
            .buttonStyle(.bordered).controlSize(.small)
            .disabled(model.loading || !model.headsetInventoryValid)
            .accessibilityLabel("\(headset.isConnected ? "Disconnect" : "Connect") \(headset.name)")
        }
        .padding(.horizontal, 10).frame(height: 56)
        .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 12))
    }

    private func headsetStatus(_ headset: HeadsetState) -> String {
        if let action = model.headsetAction, action.address == headset.address {
            return action.connecting ? "Connecting…" : "Disconnecting…"
        }
        guard model.headsetInventoryValid else { return "Unavailable" }
        return headset.isConnected ? "Connected to Mac" : "Disconnected"
    }

    private var header: some View {
        HStack(spacing: 9) {
            Image(systemName: "headphones").font(.system(size: 19, weight: .medium))
            Text("AirQc35").font(.headline)
            Spacer()
            if model.loading { ProgressView().controlSize(.small) }
            Button { model.refresh() } label: { Image(systemName: "arrow.clockwise").font(.subheadline) }
                .buttonStyle(.plain).foregroundStyle(.secondary).disabled(model.loading).accessibilityLabel("Refresh devices")
        }
    }

    private func option(_ label: String, symbol: String, value: Bool, key: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 18)).frame(width: 24).foregroundStyle(.primary)
            Text(label)
            Spacer(minLength: 12)
            Toggle(label, isOn: Binding(get: { value }, set: { model.setOption(key, $0) }))
                .labelsHidden().toggleStyle(.switch).controlSize(.small).fixedSize()
                .frame(width: 34, alignment: .trailing)
        }
        .padding(.horizontal, 10)
    }

    private var devices: some View {
        ScrollView {
            VStack(spacing: 4) {
                ForEach(model.sources, id: \.address) { source in device(source) }
                if model.sources.isEmpty { Text(model.loading ? "Loading…" : "No devices loaded").foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 40) }
            }
        }
        .scrollIndicators(.hidden)
        .frame(height: max(44, min(CGFloat(model.sources.count) * 48, 144)))
    }

    private func device(_ source: BoseSource) -> some View {
        Button { model.select(source) } label: {
            HStack(spacing: 10) {
                Image(systemName: symbol(source)).font(.system(size: 18)).frame(width: 24)
                Text(source.name).lineLimit(1)
                Spacer(minLength: 4)
                Group {
                    if model.selectedAddress == source.address { Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint) }
                    else { Color.clear }
                }.frame(width: 34, height: 18, alignment: .trailing)
            }
            .padding(.horizontal, 10).frame(height: 44).contentShape(RoundedRectangle(cornerRadius: 12))
            .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 12))
        }.buttonStyle(.plain).disabled(model.loading)
    }

    private func symbol(_ source: BoseSource) -> String {
        let name = source.name.lowercased()
        if name.contains("ipad") { return "ipad" }
        if name.contains("iphone") { return "iphone" }
        if name.contains("mac") || source.status == 3 { return "laptopcomputer" }
        return "hifispeaker"
    }
}

private struct PanelHeight: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

import SwiftUI
