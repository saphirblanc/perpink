import SwiftUI

struct SettingsView: View {
    @Bindable var settings: SettingsStore

    @Environment(\.dismiss) private var dismiss
    #if os(iOS)
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    #endif

    var body: some View {
        #if os(iOS)
        NavigationStack {
            form
                .navigationTitle("Settings")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
        }
        #else
        // The Mac's Settings window: no Done, it closes like any window.
        form
            .formStyle(.grouped)
            .frame(width: 480)
            .fixedSize(horizontal: false, vertical: true)
        #endif
    }

    private var form: some View {
        Form {
            Section {
                TextField("URL", text: $settings.serverURLString, prompt: Text("http://hermes.example.ts.net:8642"))
                    .urlEntry()
            } header: {
                Text("Server")
            } footer: {
                Text("Your Hermes API server. Plain HTTP is fine over a tailnet — Tailscale already encrypts the connection.")
            }

            Section {
                TextField("Name", text: $settings.profile, prompt: Text("default"))
                    .identifierEntry()
                SecureField("Key", text: $settings.apiKey, prompt: Text("API_SERVER_KEY"))
                    .identifierEntry()
            } header: {
                Text("Profile")
            } footer: {
                Text("Leave the profile empty for the default one. A named profile only accepts its own API_SERVER_KEY.")
            }

            textSizeSection

            Section {
                Button("Test connection") {
                    Task { await settings.checkConnection() }
                }
                .disabled(!settings.isConfigured || settings.connectionStatus == .checking)
                connectionStatus
            }
        }
        .onChange(of: settings.serverURLString) { settings.resetConnectionStatus() }
        .onChange(of: settings.profile) { settings.resetConnectionStatus() }
        .onChange(of: settings.apiKey) { settings.resetConnectionStatus() }
    }

    /// A slider between a small and a large "A", as in the system's own Text
    /// Size settings. On iOS it only appears once the system size is let go.
    private var textSizeSection: some View {
        Section {
            #if os(iOS)
            Toggle("Use System Size", isOn: followsSystem)
            if settings.textSizeStep != nil {
                textSizeSlider
            }
            #else
            textSizeSlider
            #endif
        } header: {
            // The Mac's slider carries its own "Text Size" label.
            #if os(iOS)
            Text("Text Size")
            #else
            Text("Conversation")
            #endif
        } footer: {
            #if os(iOS)
            Text("The system size is the one set in Settings › Display & Brightness › Text Size.")
            #else
            Text("Also in the View menu: ⌘1 and ⌘− to change it, ⌘0 for the usual size.")
            #endif
        }
    }

    private var textSizeSlider: some View {
        Slider(value: textSizeStep, in: 0...Double(TextSize.steps.count - 1), step: 1) {
            Text("Text Size")
        } minimumValueLabel: {
            Text("A").font(.caption)
                .accessibilityLabel("Smaller")
        } maximumValueLabel: {
            Text("A").font(.title2)
                .accessibilityLabel("Larger")
        }
        #if os(iOS)
        .labelsHidden()
        #endif
    }

    #if os(iOS)
    /// Letting go of the system size starts the slider where the system is.
    private var followsSystem: Binding<Bool> {
        Binding {
            settings.textSizeStep == nil
        } set: { follows in
            settings.textSizeStep = follows ? nil
                : TextSize.steps.firstIndex(of: dynamicTypeSize) ?? TextSize.steps.firstIndex(of: .large)
        }
    }

    private var textSizeStep: Binding<Double> {
        Binding {
            Double(settings.textSizeStep ?? TextSize.steps.firstIndex(of: .large)!)
        } set: { value in
            settings.textSizeStep = Int(value.rounded())
        }
    }
    #else
    /// The usual size is stored as no size at all.
    private var textSizeStep: Binding<Double> {
        Binding {
            Double(settings.textSizeStep ?? TextSize.systemStep)
        } set: { value in
            let step = Int(value.rounded())
            settings.textSizeStep = step == TextSize.systemStep ? nil : step
        }
    }
    #endif

    @ViewBuilder
    private var connectionStatus: some View {
        switch settings.connectionStatus {
        case .unknown:
            EmptyView()
        case .checking:
            HStack(spacing: 8) {
                ProgressView()
                Text("Connecting…")
            }
        case .ok:
            Label("Connected", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed(let message):
            VStack(alignment: .leading, spacing: 6) {
                Label("Couldn't connect", systemImage: "exclamationmark.triangle")
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private extension View {
    /// A field for a URL: no capitals, no corrections, the URL keyboard.
    func urlEntry() -> some View {
        #if os(iOS)
        keyboardType(.URL)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
        #else
        autocorrectionDisabled()
        #endif
    }

    /// A field for a name or a key, typed exactly as given.
    func identifierEntry() -> some View {
        #if os(iOS)
        textInputAutocapitalization(.never)
            .autocorrectionDisabled()
        #else
        autocorrectionDisabled()
        #endif
    }
}
