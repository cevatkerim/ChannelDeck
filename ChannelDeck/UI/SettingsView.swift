import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var appModel
    @State private var isConfirmingReset = false

    var body: some View {
        @Bindable var relay = appModel.airPlayRelayController

        Form {
            Section("Secure AirPlay Relay") {
                Text("ChannelDeck can serve HTTP-based HLS channels to AirPlay over a trusted HTTPS address on your local network.")
                    .foregroundStyle(.secondary)

                HStack(spacing: 10) {
                    statusIcon(for: relay.phase)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(relay.phase.title)
                            .fontWeight(.medium)
                        if case .failed(let message) = relay.phase {
                            Text(message)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .accessibilityElement(children: .combine)
            }

            Section("Cloudflare DNS") {
                TextField("Domain", text: $relay.zoneDomain, prompt: Text("example.com"))
                    .accessibilityLabel("Cloudflare domain")

                TextField("Account ID (optional)", text: $relay.accountID)
                    .accessibilityLabel("Cloudflare account ID")

                SecureField(
                    relay.hasStoredToken ? "API token stored in Keychain" : "Cloudflare API token",
                    text: $relay.apiTokenInput
                )
                .accessibilityLabel("Cloudflare API token")

                Text("Use a zone-scoped token with Zone DNS Edit and Zone Read permissions. The token is stored only in Keychain.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .disabled(relay.phase.isBusy)

            Section("Local Address") {
                LabeledContent("Generated hostname") {
                    Text(relay.hostname)
                        .textSelection(.enabled)
                        .foregroundStyle(relay.zoneDomain.isEmpty ? .secondary : .primary)
                }
                LabeledContent("Detected LAN address") {
                    HStack(spacing: 8) {
                        Text(relay.detectedLANAddress ?? "Not available")
                            .textSelection(.enabled)
                        Button("Refresh", systemImage: "arrow.clockwise") {
                            relay.refreshLANAddress()
                        }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .help("Detect the LAN address again")
                    }
                }
                Text("The hostname is unique to this installation and points directly to this Mac's private address. Cloudflare proxying stays off.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Certificate") {
                Picker("Let's Encrypt", selection: $relay.certificateEnvironment) {
                    ForEach(AirPlayRelayCertificateEnvironment.allCases, id: \.self) { environment in
                        Text(environment.displayName).tag(environment)
                    }
                }

                if relay.certificateEnvironment == .staging {
                    Label("Staging certificates test issuance but are not trusted by Apple TV.", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                if let expiration = relay.certificateExpiration {
                    LabeledContent("Valid until", value: expiration.formatted(date: .abbreviated, time: .shortened))
                }
            }
            .disabled(relay.phase.isBusy)

            Section("Apple TV Compatibility") {
                let ffmpegAvailability = DefaultFFmpegExecutableLocator().availability()
                LabeledContent("Audio conversion") {
                    Label(
                        ffmpegAvailability.statusTitle,
                        systemImage: ffmpegAvailability.isAvailable
                            ? "checkmark.circle.fill"
                            : "exclamationmark.triangle.fill"
                    )
                    .foregroundStyle(ffmpegAvailability.isAvailable ? .green : .orange)
                }
                Text(ffmpegAvailability.guidance)
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section {
                HStack {
                    Button(relay.isReady ? "Update Relay" : "Set Up Relay") {
                        Task { await relay.configure() }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!relay.canConfigure)

                    if relay.phase.isBusy {
                        ProgressView()
                            .controlSize(.small)
                            .accessibilityLabel(relay.phase.title)
                    }

                    Spacer()

                    Button("Reset…", role: .destructive) {
                        isConfirmingReset = true
                    }
                    .disabled(relay.phase.isBusy || (!relay.hasStoredToken && relay.zoneDomain.isEmpty))
                }
            } footer: {
                Text("The Mac must remain awake, running ChannelDeck, and connected to the same LAN as the AirPlay receiver during playback.")
            }

            Section("Refresh") {
                LabeledContent("Playlists", value: "Every 6 hours")
                LabeledContent("Programme guide", value: "Every 12 hours")
            }
            Section("Privacy") {
                Label("Source URLs and relay credentials are stored in Keychain", systemImage: "key.fill")
                Label("Playlist snapshots are encrypted at rest", systemImage: "lock.fill")
                Text("ChannelDeck does not include analytics or telemetry.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(width: 600, height: 680)
        .task {
            relay.refreshLANAddress()
        }
        .confirmationDialog(
            "Reset the AirPlay relay?",
            isPresented: $isConfirmingReset,
            titleVisibility: .visible
        ) {
            Button("Remove Relay Configuration", role: .destructive) {
                Task { await relay.reset() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("ChannelDeck will stop its relay, remove its Cloudflare DNS record, and delete the API token and certificates from Keychain.")
        }
    }

    @ViewBuilder
    private func statusIcon(for phase: AirPlayRelayPhase) -> some View {
        switch phase {
        case .ready:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        case .notConfigured:
            Image(systemName: "airplayvideo")
                .foregroundStyle(.secondary)
        default:
            ProgressView()
                .controlSize(.small)
        }
    }
}
