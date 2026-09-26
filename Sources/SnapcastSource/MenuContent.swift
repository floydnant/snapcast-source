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

            streamVolume
            Toggle("Mute this Mac while streaming", isOn: $model.muteLocal)

            SpeakersSection()

            DisclosureGroup("Settings", isExpanded: $showSettings) { SettingsSection().padding(.top, 6) }

            Divider()
            HStack {
                Text(model.effectiveSourceName).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                Button("Quit") { model.quit() }.keyboardShortcut("q")
            }
        }
        .padding(14)
        .frame(width: 320)
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

    private var streamVolume: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Image(systemName: "speaker.fill").foregroundStyle(.secondary)
                Slider(value: $model.streamVolume, in: 0...1)
                    .accessibilityLabel("Stream volume")
                Image(systemName: "speaker.wave.3.fill").foregroundStyle(.secondary)
            }
            if let caption = model.volumeCaption {
                Text(caption).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct SpeakersSection: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        switch model.controlState {
        case .disconnected where model.relays.isEmpty && model.relayOverride.isEmpty:
            EmptyView()  // nothing to control yet
        default:
            VStack(alignment: .leading, spacing: 6) {
                Text("Speakers").font(.subheadline.weight(.semibold))
                content
            }
        }
    }

    @ViewBuilder private var content: some View {
        switch model.controlState {
        case .connected where model.connectedSpeakers.isEmpty:
            note("No speakers connected.")
        case .connected:
            ForEach(model.connectedSpeakers) { SpeakerRow(speaker: $0) }
        case .failed(let reason):
            note(reason)
        default:
            note("Connecting…")
        }
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}

struct SpeakerRow: View {
    @EnvironmentObject var model: AppModel
    let speaker: SnapcastControl.Speaker

    var body: some View {
        HStack(spacing: 8) {
            Button { model.toggleMute(speaker) } label: {
                Image(systemName: speaker.muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .foregroundStyle(speaker.muted ? Color.secondary : Color.accentColor)
                    .frame(width: 18)
            }
            .buttonStyle(.plain)
            .help(speaker.muted ? "Unmute \(speaker.name)" : "Mute \(speaker.name)")
            .accessibilityLabel(speaker.muted ? "Unmute \(speaker.name)" : "Mute \(speaker.name)")

            VStack(alignment: .leading, spacing: 0) {
                Text(speaker.name).lineLimit(1)
                Text(speaker.streamID).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(width: 92, alignment: .leading)

            Slider(value: Binding(get: { Double(speaker.percent) / 100 },
                                  set: { model.setVolume(speaker, $0) }), in: 0...1)
                .opacity(speaker.muted ? 0.45 : 1)
                .accessibilityLabel("\(speaker.name) volume")
            Text("\(speaker.percent)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 24, alignment: .trailing)
        }
    }
}

/// Text fields apply on Enter or when focus leaves them, not per keystroke: changing
/// the relay, name or token reconnects, and a reconnect per typed character is what
/// the first version did.
struct SettingsSection: View {
    @EnvironmentObject var model: AppModel
    @State private var relay = ""
    @State private var name = ""
    @State private var token = ""
    @FocusState private var focus: Field?

    enum Field { case relay, name, token }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            LabeledContent("Relay") {
                TextField(automaticPlaceholder, text: $relay)
                    .textFieldStyle(.roundedBorder)
                    .foregroundStyle(StreamEngine.RelayTarget(relay) != nil ? Color.primary : .red)
                    .focused($focus, equals: .relay)
                    .onSubmit(commit)
            }
            Text(model.relays.isEmpty
                 ? "No relay found automatically."
                 : "Found: " + model.relays.map(\.name).joined(separator: ", "))
                .font(.caption).foregroundStyle(.secondary)

            LabeledContent("Name") {
                TextField(StreamEngine.defaultSourceName, text: $name)
                    .textFieldStyle(.roundedBorder)
                    .focused($focus, equals: .name)
                    .onSubmit(commit)
            }
            LabeledContent("Token") {
                SecureField("none", text: $token)
                    .textFieldStyle(.roundedBorder)
                    .focused($focus, equals: .token)
                    .onSubmit(commit)
            }

            Toggle("Follow this Mac's volume keys", isOn: $model.followSystemVolume)
            Toggle("Open at login", isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
            if let error = model.loginItemError {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            Toggle("Start streaming when opened", isOn: $model.streamOnLaunch)
        }
        .onAppear {
            relay = model.relayOverride
            name = model.sourceName
            token = model.token
        }
        .onChange(of: focus) { commit() }
        .onDisappear(perform: commit)
    }

    private func commit() {
        if relay != model.relayOverride, StreamEngine.RelayTarget(relay) != nil { model.relayOverride = relay }
        if name != model.sourceName { model.sourceName = name }
        if token != model.token { model.token = token }
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
