import SwiftUI

struct ProgrammeGuideView: View {
    @Environment(AppModel.self) private var appModel
    @AppStorage("channelDeck.density") private var density: DeckDensity = .comfortable
    @State private var scope: GuideScope = .favorites
    @State private var query = ""
    @State private var search = GuideSearchController()
    @State private var listingsOnly = true
    @State private var anchor = Date.now
    @State private var page = 0
    @State private var selectedProgramme: ProgrammeRecord?
    @FocusState private var searchFocused: Bool

    private var window: GuideWindow { GuideWindow(containing: anchor, page: page) }
    private var labelWidth: CGFloat { density == .comfortable ? 190 : 170 }
    private var rowHeight: CGFloat { density == .comfortable ? 84 : 66 }

    private var searchRequest: GuideSearchRequest {
        GuideSearchRequest(query: query, scope: scope, window: window, listingsOnly: listingsOnly,
                           revision: appModel.guideSearchRevision)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(ChannelDeckStyle.line)
            GeometryReader { geometry in
                let timelineWidth = max(geometry.size.width - labelWidth - 48, 240)
                let channelIDs = search.channelIDs
                VStack(spacing: 0) {
                    ruler(width: timelineWidth)
                        .padding(.horizontal, 24)
                    if channelIDs.isEmpty {
                        VStack(spacing: 8) {
                            Spacer()
                            DeckEmptyState(
                                symbol: "calendar",
                                title: search.isSearching ? "Finding your next watch…"
                                    : appModel.isLoadingProgrammeGuide ? "The guide is on its way." : "A little quiet here.",
                                message: search.isSearching ? "Searching your channels and programme listings."
                                    : appModel.isLoadingProgrammeGuide
                                    ? "We're gathering the latest listings from your playlists."
                                    : "Try another playlist or time, or include channels without listings."
                            )
                            if listingsOnly && !search.isSearching {
                                Button("Show all channels") { listingsOnly = false }
                                    .buttonStyle(DeckButtonStyle())
                            }
                            Spacer()
                        }
                        .frame(maxWidth: .infinity)
                    } else {
                        TimelineView(.periodic(from: .now, by: 30)) { context in
                            ScrollView {
                                LazyVStack(spacing: 1) {
                                    ForEach(channelIDs, id: \.self) { channelID in
                                        if let channel = appModel.channel(withID: channelID) {
                                            guideRow(channel, width: timelineWidth, now: context.date)
                                        }
                                    }
                                }
                                .padding(.horizontal, 24)
                                .padding(.bottom, 24)
                            }
                        }
                    }
                }
            }
        }
        .background(ChannelDeckStyle.canvas)
        .navigationTitle("")
        .onAppear {
            appModel.refreshGuideWindow()
            if !appModel.guideHasFavorites { scope = .all }
        }
        .task(id: searchRequest) {
            await search.update(request: searchRequest, index: appModel.guideSearchSnapshot,
                                preferences: appModel.libraryPreferences)
        }
        .background {
            Button("Search the guide") { searchFocused = true }
                .keyboardShortcut("f", modifiers: .command).hidden()
        }
        .popover(item: $selectedProgramme, arrowEdge: .bottom) { programme in
            programmeDetails(programme)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 19) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 7) {
                    Text("FIND YOUR NEXT GOOD THING").deckEyebrow()
                    Text(Calendar.current.component(.hour, from: anchor) >= 17 ? "The evening is yours." : "Your next good watch.")
                        .font(.system(size: 28, weight: .semibold, design: .rounded))
                        .tracking(-0.8)
                        .foregroundStyle(ChannelDeckStyle.ink)
                    Text(window.start.formatted(.dateTime.weekday(.wide).month(.wide).day()))
                        .font(.system(size: 13)).foregroundStyle(ChannelDeckStyle.muted)
                }
                Spacer()
                if appModel.selectedChannel != nil || appModel.selectedRecording != nil {
                    Button("Back to player", systemImage: "play.rectangle") {
                        if let channel = appModel.selectedChannel { appModel.sidebarSelection = .source(channel.sourceID) }
                        else { appModel.sidebarSelection = .recordings }
                    }
                    .buttonStyle(DeckButtonStyle())
                }
            }
            HStack(spacing: 12) {
                Picker("Channels", selection: $scope) {
                    Text("Favorites").tag(GuideScope.favorites)
                    Text("All playlists").tag(GuideScope.all)
                    ForEach(appModel.sources) { source in
                        Text(source.displayName).tag(GuideScope.source(source.id))
                    }
                }
                .labelsHidden().frame(width: 150)
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(ChannelDeckStyle.muted)
                    TextField("Channels or programmes", text: $query)
                        .textFieldStyle(.plain).focused($searchFocused)
                    if search.isSearching {
                        ProgressView().controlSize(.mini).accessibilityLabel("Searching the guide")
                    }
                    if !query.isEmpty {
                        Button("Clear search", systemImage: "xmark.circle.fill") { query = "" }
                            .labelStyle(.iconOnly).buttonStyle(.plain).foregroundStyle(ChannelDeckStyle.muted)
                    }
                }
                .padding(10)
                .background(ChannelDeckStyle.inset, in: RoundedRectangle(cornerRadius: 10))
                Toggle("With listings", isOn: $listingsOnly).toggleStyle(.checkbox).fixedSize()
                Spacer(minLength: 0)
                HStack(spacing: 3) {
                    Button("Earlier", systemImage: "chevron.left") { page = max(0, page - 1) }
                        .disabled(page == 0).labelStyle(.iconOnly).buttonStyle(DeckIconButtonStyle())
                    Button("Now") { anchor = .now; page = 0; appModel.refreshGuideWindow() }
                        .buttonStyle(DeckButtonStyle())
                    Button("Later", systemImage: "chevron.right") { page = min(2, page + 1) }
                        .disabled(page == 2).labelStyle(.iconOnly).buttonStyle(DeckIconButtonStyle())
                }
            }
            .font(.system(size: 12))
        }
        .padding(24)
    }

    private func ruler(width: CGFloat) -> some View {
        HStack(spacing: 0) {
            Text("CHANNEL / LOCAL TIME").deckEyebrow().frame(width: labelWidth, alignment: .leading)
            HStack(spacing: 0) {
                ForEach(0..<4) { tick in
                    Text(window.start.addingTimeInterval(Double(tick) * 1800), style: .time)
                        .font(.system(size: 12, weight: .medium).monospacedDigit())
                        .foregroundStyle(ChannelDeckStyle.muted)
                        .frame(width: width / 4, alignment: .leading)
                }
            }
        }
        .frame(height: 46)
    }

    private func guideRow(_ channel: ChannelRecord, width: CGFloat, now: Date) -> some View {
        let programmes = appModel.schedule(for: channel, from: window.start, to: window.end)
        return HStack(spacing: 0) {
            Button { watch(channel) } label: {
                HStack(spacing: 10) {
                    ChannelLogoView(channel: channel, size: density == .comfortable ? 38 : 30)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(channel.name).font(.system(size: density.titleSize - 1, weight: .semibold))
                            .foregroundStyle(ChannelDeckStyle.ink).lineLimit(2)
                        Text(channel.groupName).font(.system(size: 10))
                            .foregroundStyle(ChannelDeckStyle.muted).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.trailing, 14)
                .frame(width: labelWidth, height: rowHeight, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain).help("Watch \(channel.name) live")
            ZStack(alignment: .topLeading) {
                HStack(spacing: 0) {
                    ForEach(0..<4) { _ in
                        Rectangle().fill(ChannelDeckStyle.line).frame(width: 1)
                        Spacer(minLength: 0)
                    }
                }
                if programmes.isEmpty {
                    Text("No listings available")
                        .font(.system(size: 12)).foregroundStyle(ChannelDeckStyle.muted)
                        .frame(height: rowHeight).padding(.leading, 16)
                }
                ForEach(programmes, id: \.stableID) { programme in
                    if let placement = window.placement(start: programme.startDate, end: programme.endDate) {
                        programmeCell(programme, now: now)
                            .frame(width: max(1, width * placement.width - 4), height: rowHeight - 8)
                            .clipped()
                            .offset(x: width * placement.offset + 2, y: 4)
                    }
                }
                if let position = window.position(of: now) {
                    Rectangle().fill(ChannelDeckStyle.accent.opacity(0.8))
                        .frame(width: 2, height: rowHeight)
                        .offset(x: min(width - 2, width * position))
                        .allowsHitTesting(false).accessibilityHidden(true)
                }
            }
            .frame(width: width, height: rowHeight)
            .clipped()
        }
        .overlay(alignment: .bottom) { Rectangle().fill(ChannelDeckStyle.line.opacity(0.6)).frame(height: 1) }
    }

    private func programmeCell(_ programme: ProgrammeRecord, now: Date) -> some View {
        let isCurrent = programme.startDate <= now && now < programme.endDate
        return Button { selectedProgramme = programme } label: {
            VStack(alignment: .leading, spacing: 5) {
                Text(programme.title)
                    .font(.system(size: density.titleSize - 1, weight: .medium)).lineLimit(2)
                    .foregroundStyle(ChannelDeckStyle.ink)
                Text(programme.startDate, style: .time)
                    .font(.system(size: 10).monospacedDigit()).foregroundStyle(ChannelDeckStyle.muted)
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .background(isCurrent ? ChannelDeckStyle.accentSoft : ChannelDeckStyle.surface,
                        in: RoundedRectangle(cornerRadius: 10))
            .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(ChannelDeckStyle.line, lineWidth: 1) }
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .help("\(programme.title) · \(programme.startDate.formatted(date: .omitted, time: .shortened)) – \(programme.endDate.formatted(date: .omitted, time: .shortened))")
        .accessibilityLabel("\(programme.title), \(programme.startDate.formatted(date: .omitted, time: .shortened)) to \(programme.endDate.formatted(date: .omitted, time: .shortened))")
    }

    private func programmeDetails(_ programme: ProgrammeRecord) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("ON YOUR RADAR").deckEyebrow()
                Spacer()
                Button("Close", systemImage: "xmark") { selectedProgramme = nil }
                    .labelStyle(.iconOnly).buttonStyle(DeckIconButtonStyle())
            }
            Text(programme.title)
                .font(.system(size: 22, weight: .semibold, design: .rounded))
                .foregroundStyle(ChannelDeckStyle.ink)
            Text("\(programme.startDate.formatted(date: .abbreviated, time: .shortened)) – \(programme.endDate.formatted(date: .omitted, time: .shortened))")
                .font(.system(size: 12)).foregroundStyle(ChannelDeckStyle.muted)
            if let description = programme.programmeDescription, !description.isEmpty {
                ScrollView { Text(description).font(.system(size: density.readingSize)).lineSpacing(4).frame(maxWidth: .infinity, alignment: .leading) }
                    .frame(maxHeight: 180)
            }
            if let channel = appModel.channel(withID: programme.channelStableID) {
                Divider()
                HStack {
                    ChannelLogoView(channel: channel, size: 32)
                    Text(channel.name).font(.system(size: 12, weight: .medium)).lineLimit(2)
                    Spacer()
                    Button("Watch live", systemImage: "play.fill") { selectedProgramme = nil; watch(channel) }
                        .buttonStyle(DeckButtonStyle(prominent: true))
                        .help("Play what's broadcasting on this channel now")
                }
            }
        }
        .padding(24).frame(width: 430).background(ChannelDeckStyle.canvas)
    }

    private func watch(_ channel: ChannelRecord) {
        appModel.play(channel)
        appModel.sidebarSelection = .source(channel.sourceID)
    }
}
