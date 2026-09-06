import TVServices

final class ContentProvider: TVTopShelfContentProvider {
    override func loadTopShelfContent(completionHandler: @escaping ((any TVTopShelfContent)?) -> Void) {
        guard let directory = TVShelfStore.directory else { completionHandler(nil); return }
        let entries = TVShelfStore.read(from: directory)
        var sections: [TVTopShelfItemCollection<TVTopShelfSectionedItem>] = []
        for favorite in [false, true] {
            let items = entries.filter { $0.favorite == favorite }.compactMap { entry -> TVTopShelfSectionedItem? in
                guard let artwork = entry.artwork,
                      let imageURL = TVShelfStore.imageURL(artwork.imageName(), directory: directory) else { return nil }
                let item = TVTopShelfSectionedItem(identifier: entry.id)
                item.title = entry.name
                item.imageShape = .hdtv
                item.setImageURL(imageURL, for: [.screenScale1x, .screenScale2x])
                item.displayAction = TVTopShelfAction(url: entry.actionURL)
                item.playAction = TVTopShelfAction(url: entry.actionURL)
                return item
            }
            if !items.isEmpty {
                let section = TVTopShelfItemCollection(items: items)
                section.title = favorite ? "Favorites" : "Frequently watched"
                sections.append(section)
            }
        }
        completionHandler(sections.isEmpty ? nil : TVTopShelfSectionedContent(sections: sections))
    }
}
