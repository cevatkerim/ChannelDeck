import SwiftUI

struct TVChannelArtworkView: View {
    let channel: TVChannel
    @Bindable var artwork: TVArtworkLibrary
    let favorite: Bool
    @State private var image: UIImage?
    @State private var programmeTitle: String?
    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            GeometryReader { geometry in
                if let image {
                    Image(uiImage: image).resizable().scaledToFill().frame(width: geometry.size.width, height: geometry.size.height).clipped()
                } else {
                    TVTheme.background
                    TVChannelLogo(url: channel.logoURL).padding(40).frame(width: geometry.size.width, height: geometry.size.height)
                }
            }
            if let programmeTitle {
                Text(programmeTitle).font(.caption.weight(.medium)).foregroundStyle(.white)
                    .lineLimit(2).multilineTextAlignment(.leading)
                    .padding(16).frame(maxWidth: .infinity, alignment: .leading)
                    .background(.black.opacity(0.8), in: Rectangle())
            }
            if favorite {
                Image(systemName: "star.fill").font(.caption).foregroundStyle(TVTheme.mint)
                    .padding(10).background(.black.opacity(0.7), in: Circle()).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing).padding(10)
            }
        }
        .accessibilityValue(programmeTitle ?? "")
        .accessibilityIdentifier("Channel artwork \(channel.name)")
        .task(id: "\(channel.id)|\(artwork.revision)") {
            artwork.ensure(channel)
            let key = TVShelfStore.key(channel.id)
            let data = await artwork.pipeline.image(for: key)
            let metadata = await artwork.pipeline.artwork(for: key)
            guard !Task.isCancelled else { return }
            image = data.flatMap(UIImage.init(data:))
            programmeTitle = metadata?.previewTitle()
        }
    }
}
