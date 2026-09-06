import SwiftUI

struct SourceEditorView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss
    @State private var showsGuideOptions = false
    @State private var showsMatches = false
    @FocusState private var focusedField: Field?
    private enum Field { case name, playlist, guide }

    var body: some View {
        @Bindable var appModel = appModel

        VStack(alignment: .leading, spacing: 24) {
            HStack(alignment: .top) {
                Image(systemName: "rectangle.stack.badge.plus")
                    .font(.system(size: 23, weight: .light))
                    .foregroundStyle(ChannelDeckStyle.accent)
                    .frame(width: 54, height: 54)
                    .background(ChannelDeckStyle.accentSoft, in: RoundedRectangle(cornerRadius: 17))
                Spacer()
                Button("Close", systemImage: "xmark") { dismiss() }
                    .labelStyle(.iconOnly)
                    .buttonStyle(DeckIconButtonStyle())
                    .foregroundStyle(ChannelDeckStyle.muted)
                    .disabled(appModel.isSavingSource)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text(appModel.isEditingSource ? "A few little adjustments." : "Bring your channels home.")
                    .font(.system(size: 27, weight: .semibold, design: .rounded))
                    .tracking(-0.7)
                    .foregroundStyle(ChannelDeckStyle.ink)
                Text(
                    appModel.isEditingSource
                        ? "Update your playlist and we'll take it from here."
                        : "Add your M3U playlist. We'll take care of the lineup."
                )
                .font(.system(size: 12))
                .foregroundStyle(ChannelDeckStyle.muted)
            }

            VStack(alignment: .leading, spacing: 19) {
                field("Playlist name", hint: "Give it a name that feels familiar.", field: .name) {
                    TextField("My TV", text: $appModel.sourceDraft.displayName)
                        .focused($focusedField, equals: .name)
                        .accessibilityLabel("Playlist name")
                }
                field("Playlist URL", hint: nil, field: .playlist) {
                    TextField("https://example.com/playlist.m3u", text: $appModel.sourceDraft.playlistURL)
                        .textContentType(.URL)
                        .focused($focusedField, equals: .playlist)
                        .accessibilityLabel("Playlist URL")
                }
                DisclosureGroup(isExpanded: $showsGuideOptions) {
                    Picker("Guide provider", selection: $appModel.sourceDraft.guideMode) {
                        ForEach(GuideProviderMode.allCases) { mode in Text(mode.title).tag(mode) }
                    }
                    .padding(.top, 12)
                    if appModel.sourceDraft.guideMode != .openEPG {
                    field(
                        "Programme guide URL", hint: "Leave blank to use the guide included in your playlist.",
                        field: .guide
                    ) {
                        TextField("https://example.com/guide.xml", text: $appModel.sourceDraft.epgURL)
                            .textContentType(.URL)
                            .focused($focusedField, equals: .guide)
                            .accessibilityLabel("Programme guide URL override")
                    }
                    .padding(.top, 12)
                    }
                    if appModel.sourceDraft.guideMode != .playlist {
                        Text("Open-EPG downloads relevant country guides once daily. Matching stays on your Mac; playlist credentials are never sent. Movies and series are excluded.")
                            .font(.caption).foregroundStyle(ChannelDeckStyle.muted)
                            .fixedSize(horizontal: false, vertical: true).padding(.top, 8)
                        Link("About Open-EPG", destination: URL(string: "https://www.open-epg.com/app/epgguide.php")!)
                            .font(.caption)
                        if let sourceID = appModel.editingGuideSourceID {
                            if let result = appModel.guideResults[sourceID] {
                                Text("\(result.rows.filter { $0.match != nil }.count) of \(result.rows.count) live channels matched to Open-EPG")
                                    .font(.caption)
                                Button("Review matches…") { showsMatches = true }
                            } else {
                                if appModel.guidePreferences(for: sourceID).mode != .playlist {
                                    Button("Load guide matches…") { Task { await appModel.refreshGuideOnly(sourceID) } }
                                        .disabled(appModel.refreshingGuides.contains(sourceID))
                                    if appModel.refreshingGuides.contains(sourceID) { ProgressView().controlSize(.small) }
                                } else {
                                    Text("Save changes to discover guides and review matches.").font(.caption)
                                }
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Text("Programme guide").font(.system(size: 12, weight: .medium))
                        Text("Optional").font(.system(size: 11)).foregroundStyle(ChannelDeckStyle.muted)
                    }
                }
                .foregroundStyle(ChannelDeckStyle.ink)
            }
            .disabled(appModel.isSavingSource)

            if appModel.sourceDraftUsesUnencryptedTransport {
                Label(
                    "This playlist uses HTTP. Its credentials and data can be visible on the network.",
                    systemImage: "exclamationmark.shield"
                )
                .font(.system(size: 11))
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            }
            if let error = appModel.sourceEditorError {
                Label(error, systemImage: "exclamationmark.circle")
                    .font(.system(size: 12))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("Error: \(error)")
            }

            Label("Your playlist credentials stay in your Mac's Keychain.", systemImage: "lock.shield")
                .font(.system(size: 11))
                .foregroundStyle(ChannelDeckStyle.muted)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(ChannelDeckStyle.inset, in: RoundedRectangle(cornerRadius: 10))

            HStack(spacing: 10) {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(DeckButtonStyle())
                    .disabled(appModel.isSavingSource)
                Button {
                    Task {
                        if await appModel.commitSourceDraft() { dismiss() }
                    }
                } label: {
                    HStack(spacing: 8) {
                        if appModel.isSavingSource { ProgressView().controlSize(.mini) }
                        Text(
                            appModel.isSavingSource
                                ? "Connecting…" : (appModel.isEditingSource ? "Save changes" : "Add playlist"))
                        if !appModel.isSavingSource { Image(systemName: "arrow.right") }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(DeckButtonStyle(prominent: true))
                .disabled(!appModel.canCommitSourceDraft || appModel.isSavingSource)
                .help(
                    appModel.canCommitSourceDraft ? "Connect this playlist" : "Enter a valid HTTP or HTTPS playlist URL"
                )
            }
        }
        .padding(30)
        .frame(width: 520)
        .background(ChannelDeckStyle.surface)
        .tint(ChannelDeckStyle.accent)
        .interactiveDismissDisabled(appModel.isSavingSource)
        .sheet(isPresented: $showsMatches) {
            if let sourceID = appModel.editingGuideSourceID { GuideMatchingView(sourceID: sourceID) }
        }
        .onAppear {
            showsGuideOptions = !appModel.sourceDraft.epgURL.isEmpty || appModel.sourceDraft.guideMode != .playlist
            focusedField = appModel.isEditingSource ? .playlist : .name
        }
    }

    private func field<Content: View>(_ title: String, hint: String?, field: Field, @ViewBuilder content: () -> Content)
        -> some View
    {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(ChannelDeckStyle.ink)
            content()
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .padding(13)
                .background(ChannelDeckStyle.canvas, in: RoundedRectangle(cornerRadius: 10))
                .overlay {
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(
                            focusedField == field ? ChannelDeckStyle.accent : ChannelDeckStyle.line, lineWidth: 1)
                }
            if let hint {
                Text(hint).font(.system(size: 10)).foregroundStyle(ChannelDeckStyle.muted)
            }
        }
    }
}
