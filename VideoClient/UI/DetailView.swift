import SwiftUI

struct DetailView: View {
    let entry: MediaEntry
    let onBack: () -> Void
    /// Переход к другой карточке — из фильмографии актёра.
    var onOpenEntry: (MediaEntry) -> Void = { _ in }

    @Environment(LibraryStore.self) private var store
    @Environment(PlaybackSession.self) private var session
    @Environment(LibraryCoordinator.self) private var coordinator

    @State private var selectedSeason: Int?
    /// Открытая страница актёра.
    @State private var selectedPerson: Person?

    private var live: MediaEntry { store.entry(id: entry.id) ?? entry }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                hero
                VStack(alignment: .leading, spacing: 26) {
                    if let overview = live.overview, !overview.isEmpty {
                        Text(overview)
                            .font(.system(size: 14))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: 780, alignment: .leading)
                    }
                    if live.kind == .show { seasonsSection }
                    if !live.cast.isEmpty { castSection }
                    filesSection
                }
                .padding(28)
            }
        }
        .sheet(item: $selectedPerson) { person in
            PersonSheet(person: person, onOpenInLibrary: onOpenEntry)
            .environment(store)
            .environment(coordinator)
        }
        .scrollContentBackground(.hidden)
        .background { backdrop }
        .onAppear { selectedSeason = live.seasons.first }
    }

    // MARK: - Шапка

    private var hero: some View {
        HStack(alignment: .top, spacing: 24) {
            CachedImage(url: TMDB.imageURL(path: live.posterPath, size: .posterLarge))
                .aspectRatio(2 / 3, contentMode: .fill)
                .frame(width: 220)
                .clipShape(.rect(cornerRadius: 16))
                .shadow(color: .black.opacity(0.35), radius: 20, y: 10)

            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(live.displayTitle)
                        .font(.system(size: 32, weight: .bold))
                        .lineLimit(2)
                    if let original = live.originalTitle, original != live.displayTitle {
                        Text(original).font(.title3).foregroundStyle(.secondary)
                    }
                    if let tagline = live.tagline, !tagline.isEmpty {
                        Text(tagline).font(.callout.italic()).foregroundStyle(.tertiary)
                    }
                }

                metaRow
                actionRow
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(28)
        .padding(.top, 12)
    }

    private var metaRow: some View {
        HStack(spacing: 8) {
            if let year = live.displayYear {
                chip(String(year))
            }
            if let rating = live.rating, rating > 0 {
                chip(String(format: "★ %.1f", rating), tint: .yellow)
            }
            if let runtime = live.runtime, runtime > 0 {
                chip(TimeFormat.runtime(minutes: runtime))
            }
            if live.kind == .show {
                chip("\(Plural.seasons(live.seasons.count)), \(Plural.episodes(live.episodes.count))")
            }
            ForEach(live.genres.prefix(3), id: \.self) { chip($0) }
        }
        .font(.system(size: 12, weight: .medium))
    }

    private func chip(_ text: String, tint: Color? = nil) -> some View {
        Text(text)
            .foregroundStyle(tint ?? .primary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .glassEffect(.regular, in: .capsule)
    }

    @ViewBuilder
    private var actionRow: some View {
        let target = playTarget
        let watched = store.isFinished(live)
        HStack(spacing: 12) {
            if live.isAvailable {
                Button {
                    session.play(entry: live, episode: target.episode, restart: false)
                } label: {
                    Label(target.label, systemImage: "play.fill")
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
            } else {
                // Файлов нет — предлагать «Смотреть» бессмысленно. Главное действие
                // здесь — вести учёт просмотренного.
                if watched {
                    Button { toggleWatched() } label: { watchedLabel(true) }
                        .buttonStyle(.glass)
                        .controlSize(.large)
                } else {
                    Button { toggleWatched() } label: { watchedLabel(false) }
                        .buttonStyle(.glassProminent)
                        .controlSize(.large)
                }

                Label("Файла нет на диске", systemImage: "externaldrive.badge.xmark")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .glassEffect(.regular, in: .capsule)
                    .help("Карточка хранится как метаданные с TMDB. Добавьте файл в папку библиотеки и нажмите ⌘R.")
            }

            if live.isAvailable, target.canRestart {
                Button {
                    session.play(entry: live, episode: target.episode, restart: true)
                } label: {
                    Label("Сначала", systemImage: "arrow.counterclockwise")
                        .padding(.horizontal, 6)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.glass)
                .controlSize(.large)
            }

            Button {
                store.update(id: live.id) { $0.isFavorite.toggle() }
            } label: {
                Image(systemName: live.isFavorite ? "heart.fill" : "heart")
                    .foregroundStyle(live.isFavorite ? .pink : .primary)
                    .padding(6)
            }
            .buttonStyle(.glass)
            .controlSize(.large)
            .help(live.isFavorite ? "Убрать из избранного" : "В избранное")

            Menu {
                Button(store.isFinished(live) ? "Снять отметку «просмотрено»" : "Отметить просмотренным") {
                    let finished = store.isFinished(live)
                    for key in live.watchKeys { store.setFinished(key: key, !finished) }
                }
                Button("Сбросить прогресс") {
                    for key in live.watchKeys { store.resetProgress(key: key) }
                }
                Divider()
                Button("Уточнить в TMDB…") {
                    Task {
                        let candidates = await coordinator.search(query: live.parsedTitle, kind: live.kind)
                        coordinator.enqueueForConfirmation(live, candidates: candidates)
                    }
                }
                Divider()
                Button("Убрать из библиотеки", role: .destructive) {
                    store.delete(id: live.id)
                    onBack()
                }
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.button)
            .buttonStyle(.glass)
            .controlSize(.large)
            .frame(width: 44)

            Spacer()
        }
    }

    private func toggleWatched() {
        let watched = store.isFinished(live)
        for key in live.watchKeys { store.setFinished(key: key, !watched) }
    }

    private func watchedLabel(_ watched: Bool) -> some View {
        Label(watched ? "Просмотрено" : "Отметить просмотренным",
              systemImage: watched ? "checkmark.circle.fill" : "checkmark.circle")
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
    }

    /// Что запустит главная кнопка: продолжить, начать, или следующий эпизод.
    private var playTarget: (label: String, episode: EpisodeEntry?, canRestart: Bool) {
        switch live.kind {
        case .movie:
            guard let file = live.movieFile else { return (String(localized: "Смотреть"), nil, false) }
            if let state = store.watchState(for: live.watchKey), state.isInProgress {
                return (String(localized: "Продолжить с \(TimeFormat.clock(state.position))"), nil, true)
            }
            if store.watchState(for: live.watchKey)?.isFinished == true {
                return (String(localized: "Смотреть снова"), nil, false)
            }
            return (String(localized: "Смотреть"), nil, false)

        case .show:
            let ordered = live.episodes.sorted { ($0.season, $0.episode) < ($1.season, $1.episode) }
            if let current = ordered.first(where: { store.watchState(for: $0.id)?.isInProgress == true }) {
                return (String(localized: "Продолжить: \(current.displayCode)"), current, true)
            }
            if let next = ordered.first(where: { store.watchState(for: $0.id)?.isFinished != true && $0.isAvailable }) {
                let isFirst = next.id == ordered.first?.id
                return (isFirst ? String(localized: "Смотреть: \(next.displayCode)") : String(localized: "Дальше: \(next.displayCode)"), next, false)
            }
            return (String(localized: "Смотреть снова"), ordered.first { $0.isAvailable }, false)
        }
    }

    // MARK: - Сезоны

    @ViewBuilder
    private var seasonsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Серии").font(.system(size: 19, weight: .semibold))
                Spacer()
                if live.seasons.count > 1 {
                    Picker("Сезон", selection: Binding(get: { selectedSeason ?? live.seasons.first ?? 1 },
                                                       set: { selectedSeason = $0 })) {
                        ForEach(live.seasons, id: \.self) { Text("Сезон \($0)").tag($0) }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .frame(width: 150)
                }
            }

            let season = selectedSeason ?? live.seasons.first ?? 1
            VStack(spacing: 8) {
                ForEach(live.episodes(inSeason: season)) { episode in
                    EpisodeRow(entry: live, episode: episode)
                }
            }
        }
    }

    // MARK: - Актёры

    private var castSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("В ролях").font(.system(size: 19, weight: .semibold))
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 16) {
                    ForEach(live.cast) { person in
                        Button {
                            selectedPerson = person
                        } label: {
                            VStack(spacing: 6) {
                            CachedImage(url: TMDB.imageURL(path: person.profilePath, size: .profile)) {
                                PosterPlaceholder(symbol: "person.fill")
                            }
                            .frame(width: 74, height: 74)
                            .clipShape(.circle)
                            Text(person.name)
                                .font(.system(size: 11, weight: .medium))
                                .lineLimit(1)
                            if let role = person.role, !role.isEmpty {
                                Text(role)
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            }
                            .frame(width: 92)
                        }
                        .buttonStyle(.plain)
                        .help(String(localized: "Открыть страницу актёра"))
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    // MARK: - Файлы

    private var filesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(live.kind == .movie ? "Файл" : "Файлы").font(.system(size: 19, weight: .semibold))
            ForEach(live.allFiles) { file in
                HStack(spacing: 10) {
                    Image(systemName: "doc.fill").foregroundStyle(.tertiary)
                    Text(file.fileName)
                        .font(.system(size: 12))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    if PlaybackSupport.unsupportedByAV.contains(file.fileExtension),
                       !PlaybackBackend.vlcAvailable {
                        Label(".\(file.fileExtension)", systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.orange)
                            .help("Системный плеер macOS обычно не открывает этот контейнер — нужен VLC")
                    }
                    Text(ByteCountFormatter.string(fromByteCount: file.fileSize, countStyle: .file))
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .glassEffect(.regular, in: .rect(cornerRadius: 10))
            }
        }
        .frame(maxWidth: 780, alignment: .leading)
    }

    private var backdrop: some View {
        ZStack(alignment: .top) {
            Rectangle().fill(.background)
            CachedImage(url: TMDB.imageURL(path: live.backdropPath, size: .backdrop)) { Color.clear }
                .frame(height: 460)
                .frame(maxWidth: .infinity)
                .clipped()
                .opacity(0.35)
                .overlay {
                    LinearGradient(colors: [.clear, Color(nsColor: .windowBackgroundColor)],
                                   startPoint: .top, endPoint: .bottom)
                }
                .blur(radius: 30)
        }
        .ignoresSafeArea()
    }
}

/// Строка эпизода: кадр, номер, название, прогресс и кнопка отметки.
struct EpisodeRow: View {
    let entry: MediaEntry
    let episode: EpisodeEntry

    @Environment(LibraryStore.self) private var store
    @Environment(PlaybackSession.self) private var session
    @State private var hovering = false

    private var state: WatchState? { store.watchState(for: episode.id) }
    private var available: Bool { episode.isAvailable }

    /// Доля просмотра для полосы: досмотренная серия — всегда полная,
    /// даже если позиция не дошла до самого конца.
    private var watchedFraction: Double {
        guard let state else { return 0 }
        return state.isFinished ? 1 : state.fraction
    }

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                CachedImage(url: TMDB.imageURL(path: episode.stillPath, size: .still)) {
                    PosterPlaceholder(symbol: "tv")
                }
                .frame(width: 128, height: 72)
                .clipShape(.rect(cornerRadius: 8))

                if hovering && available {
                    Image(systemName: "play.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(.white)
                        .padding(9)
                        .glassEffect(.regular.interactive(), in: .circle)
                }
            }
            .overlay(alignment: .bottom) {
                // Полоса прогресса на каждой серии: пустая — не начата,
                // частичная — на середине, полная — досмотрена.
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.black.opacity(0.55))
                        Capsule()
                            .fill(state?.isFinished == true ? Color.green : Color.accentColor)
                            .frame(width: geo.size.width * watchedFraction)
                    }
                }
                .frame(height: 4)
                .padding(.horizontal, 6)
                .padding(.bottom, 5)
                .opacity(available || watchedFraction > 0 ? 1 : 0.35)
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(episode.shortDisplay)
                        .font(.system(size: 11, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.secondary)
                    Text(episode.title)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                    if !available {
                        // Серия известна из TMDB, но файла нет — отметить просмотр всё равно можно.
                        Text(episode.isUpcoming ? "скоро" : "нет файла")
                            .font(.system(size: 10, weight: .medium))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .glassEffect(.regular, in: .capsule)
                            .foregroundStyle(.secondary)
                    }
                }
                if let overview = episode.overview, !overview.isEmpty {
                    Text(overview)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                if let state, !state.isFinished, state.hasResumablePosition {
                    Text(state.duration > 0
                         ? String(localized: "Остановились на \(TimeFormat.clock(state.position)) из \(TimeFormat.clock(state.duration))")
                         : String(localized: "Остановились на \(TimeFormat.clock(state.position))"))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Color.accentColor)
                }
            }

            Spacer()

            Button {
                store.setFinished(key: episode.id, !(state?.isFinished ?? false))
            } label: {
                Image(systemName: state?.isFinished == true ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 17))
                    .foregroundStyle(state?.isFinished == true ? Color.accentColor : .secondary)
            }
            .buttonStyle(.plain)
            .help(state?.isFinished == true ? "Снять отметку" : "Отметить просмотренным")
        }
        .padding(10)
        .glassEffect(.regular, in: .rect(cornerRadius: 12))
        .opacity(available ? 1 : 0.55)
        .contentShape(Rectangle())
        .onTapGesture {
            guard available else { return }
            session.play(entry: entry, episode: episode)
        }
        .onHover { hovering = $0 }
        .help(available ? "" : (episode.isUpcoming ? "Серия ещё не вышла" : "Файл этой серии не найден в библиотеке"))
        .frame(maxWidth: 780, alignment: .leading)
    }
}
