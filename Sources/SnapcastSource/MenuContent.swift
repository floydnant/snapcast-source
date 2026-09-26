import StreamCore
import SwiftUI

struct MenuContent: View {
    @EnvironmentObject var model: AppModel
    @State private var showSettings = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            status
            if model.isStreaming { LevelBar(level: model.level) }

            Button(action: model.primaryAction) {
                Text(model.primaryActionTitle).frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .tint(model.isActive ? .red : .accentColor)
            .keyboardShortcut(.defaultAction)

            Toggle("Mute this Mac while streaming", isOn: $model.muteLocal)

            DisclosureGroup("Settings", isExpanded: $showSettings) { settings.padding(.top, 6) }

            Divider()
            HStack {
                Text(model.effectiveSourceName).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Quit") { model.quit() }.keyboardShortcut("q")
            }
        }
        .padding(14)
        .frame(width: 300)
    }

    private var status: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: model.menuBarSymbol)
                .font(.title2)
                .foregroundStyle(model.isStreaming ? Color.accentColor : .secondary)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.headline).font(.headline)
                if let detail = model.detail {
                    Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 8) {
            LabeledContent("Relay") {
                TextField(automaticPlaceholder, text: $model.relayOverride)
                    .textFieldStyle(.roundedBorder)
                    .foregroundStyle(model.relayOverrideIsValid ? Color.primary : .red)
            }
            Text(model.relays.isEmpty
                 ? "No relay found automatically."
                 : "Found: " + model.relays.map(\.name).joined(separator: ", "))
                .font(.caption).foregroundStyle(.secondary)

            LabeledContent("Name") {
                TextField(StreamEngine.defaultSourceName, text: $model.sourceName).textFieldStyle(.roundedBorder)
            }
            LabeledContent("Token") {
                SecureField("none", text: $model.token).textFieldStyle(.roundedBorder)
            }

            Toggle("Open at login", isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
            if let error = model.loginItemError {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            Toggle("Start streaming when opened", isOn: $model.streamOnLaunch)
        }
    }

    private var automaticPlaceholder: String {
        model.relays.first.map { "Automatic (\($0.name))" } ?? "Automatic"
    }
}

struct LevelBar: View {
    let level: Float

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(level > 0.9 ? Color.orange : Color.accentColor)
                    .frame(width: geo.size.width * CGFloat(Self.scaled(level)))
            }
        }
        .frame(height: 6)
        .accessibilityLabel("Level")
        .accessibilityValue("\(Int(Self.scaled(level) * 100)) percent")
    }

    /// dBFS mapped over a 60 dB range, which is how level meters read.
    static func scaled(_ peak: Float) -> Float {
        guard peak > 0 else { return 0 }
        let db = 20 * log10(peak)
        return max(0, min(1, (db + 60) / 60))
    }
}
