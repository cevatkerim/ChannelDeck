import SwiftUI

struct TVSettingsView: View {
    @Bindable var library: TVLibrary
    @State private var editor: SourceEditorItem?
    @State private var removing: TVSource?
    @State private var matching: TVSource?
    @State private var showingLicense = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                TVHeading(title: "Make yourself at home", subtitle: "ChannelDeck settings")
                HStack {
                    Text("Playlists").font(.title2.bold())
                    Spacer()
                    Button("Add playlist", systemImage: "plus") { editor = SourceEditorItem(source: nil) }
                }
                ForEach(library.sources) { source in
                    VStack(alignment: .leading, spacing: 16) {
                        HStack {
                            Text(source.name).font(.headline)
                            Spacer()
                            if library.refreshing.contains(source.id) { ProgressView() }
                            Button("Refresh") { Task { await library.refresh(source) } }.disabled(library.refreshing.contains(source.id))
                            Button("Edit") { editor = SourceEditorItem(source: source) }
                            if library.guideResults[source.id] != nil {
                                Button("Guide matches") { matching = source }
                            }
                            Button("Remove", role: .destructive) { removing = source }
                        }
                        if let error = library.sourceErrors[source.id] { Text(error).font(.callout).foregroundStyle(.orange) }
                        if let progress = library.guideProgress[source.id] { Text(progress).font(.callout).foregroundStyle(TVTheme.mint) }
                        if let result = library.guideResults[source.id] {
                            Text("Open-EPG · \(result.rows.filter { $0.match != nil }.count) matched · \(result.rows.filter { !$0.suggestions.isEmpty }.count) to review")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                    }.padding(28).background(TVTheme.panel, in: RoundedRectangle(cornerRadius: 18))
                }
                Text("Live rewind").font(.title2.bold()).padding(.top, 20)
                Picker("History length", selection: Binding(get: { library.state.bufferMinutes }, set: { library.setBufferMinutes($0) })) {
                    Text("5 minutes").tag(5)
                    Text("10 minutes").tag(10)
                }.pickerStyle(.segmented)
                Text("History builds while you watch or pause the current channel. Changing channels or leaving the app clears it. Available storage can shorten the window. Changes apply to the next playback session.")
                    .foregroundStyle(.secondary)
                Text("Your sources stay yours").font(.title2.bold()).padding(.top, 20)
                Text("Playlist addresses are stored in Apple TV’s Keychain. Downloaded playlists are encrypted. No channels or subscriptions are included.")
                    .foregroundStyle(.secondary)
                Text("Powered by FFmpeg 8.0.1 · LGPL 2.1 or later").font(.caption).foregroundStyle(.secondary)
                Button("Open-source license") { showingLicense = true }
            }.padding(.horizontal, 80).padding(.vertical, 40)
        }
        .sheet(item: $editor) { item in TVSourceEditor(library: library, source: item.source) }
        .sheet(item: $matching) { source in TVGuideMatchesView(library: library, source: source) }
        .sheet(isPresented: $showingLicense) {
            ScrollView {
                VStack(alignment: .leading, spacing: 30) {
                    TVHeading(title: "FFmpeg", subtitle: "8.0.1 · LGPL 2.1 or later")
                    Text("Source and build instructions: ffmpeg.org and Scripts/build_ffmpeg_tvos.sh in the ChannelDeck repository.")
                    Text(Bundle.main.url(forResource: "FFmpeg-LICENSE", withExtension: "txt").flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? "The license is included in the ChannelDeck source repository.")
                        .font(.callout)
                    Button("Done") { showingLicense = false }
                }.padding(80)
            }
        }
        .confirmationDialog("Remove \(removing?.name ?? "playlist")?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button("Remove playlist", role: .destructive) {
                if let source = removing { Task { await library.remove(source) } }
                removing = nil
            }
        } message: { Text("This removes its saved address and downloaded guide from this Apple TV.") }
    }
    private struct SourceEditorItem: Identifiable {
        let id = UUID()
        let source: TVSource?
    }
}

struct TVSourceEditor: View {
    @Bindable var library: TVLibrary
    let source: TVSource?
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var playlist = ""
    @State private var guide = ""
    @State private var mode = GuideProviderMode.automatic
    @State private var saving = false
    @State private var error: String?
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                TVHeading(title: source == nil ? "Bring your channels" : "Edit playlist", subtitle: "M3U playlist")
                TextField("Playlist name", text: $name)
                TextField("M3U URL", text: $playlist).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled().privacySensitive()
                Picker("Programme guide", selection: $mode) {
                    ForEach(GuideProviderMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.menu)
                if mode != .openEPG {
                    TextField("XMLTV guide URL (optional)", text: $guide).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled().privacySensitive()
                }
                Text("Use the Apple TV keyboard or enter text from your iPhone. Automatic uses your playlist’s guide when available and supplements missing listings with Open-EPG. Review uncertain matches in Settings.").font(.callout).foregroundStyle(.secondary)
                if let error { Text(error).foregroundStyle(.orange) }
                HStack(spacing: 30) {
                    Button(saving ? "Saving…" : "Save playlist") {
                        saving = true; error = nil
                        Task {
                            do { try await library.save(source: source, name: name, playlist: playlist, guide: guide, mode: mode); dismiss() }
                            catch { self.error = TVLibrary.safeMessage(error) }
                            saving = false
                        }
                    }.disabled(saving)
                    Button("Cancel") { dismiss() }.disabled(saving)
                    if saving { ProgressView() }
                }
            }.padding(80)
        }
        .task {
            if let source {
                name = source.name
                mode = source.guidePreferences.mode
                do { (playlist, guide) = try await library.sourceAddresses(source) }
                catch { self.error = "The stored addresses could not be loaded." }
            }
        }
    }
}
