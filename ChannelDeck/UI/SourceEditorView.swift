import SwiftUI

struct SourceEditorView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var appModel = appModel

        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text(appModel.sourceEditorTitle)
                    .font(.title2.weight(.semibold))
                Text("Playlist credentials are stored in your Mac keychain and redacted elsewhere in the app.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Form {
                TextField("Name", text: $appModel.sourceDraft.displayName, prompt: Text("My TV"))
                TextField("Playlist URL", text: $appModel.sourceDraft.playlistURL, prompt: Text("https://…/playlist.m3u"))
                    .textContentType(.URL)
                TextField("EPG override", text: $appModel.sourceDraft.epgURL, prompt: Text("Optional; uses url-tvg by default"))
                    .textContentType(.URL)
            }
            .formStyle(.grouped)

            if let error = appModel.sourceEditorError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .accessibilityLabel("Error: \(error)")
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(appModel.isSavingSource)
                Button(appModel.isEditingSource ? "Save" : "Add Playlist") {
                    Task {
                        if await appModel.commitSourceDraft() {
                            dismiss()
                        }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(!appModel.canCommitSourceDraft || appModel.isSavingSource)
                .overlay {
                    if appModel.isSavingSource { ProgressView().controlSize(.small) }
                }
            }
        }
        .padding(24)
        .frame(width: 520, height: 390)
        .interactiveDismissDisabled(appModel.isSavingSource)
    }
}
