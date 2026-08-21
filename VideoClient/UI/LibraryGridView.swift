import SwiftUI

struct LibraryGridView: View {
    let entries: [MediaEntry]
    let filter: LibraryFilter
    /// Строка поиска по самой библиотеке — живёт прямо в разделе,
    /// чтобы не путаться с общим поиском по TMDB в правом верхнем углу.
    @Binding var query: String
    /// Меняется, когда пользователь нажал ⌃F: это сигнал поставить курсор в строку.
    let focusToken: Int
    let onSelect: (MediaEntry) -> Void

    @Environment(LibraryStore.self) private var store
    @Environment(PlaybackSession.self) private var session
    @Environment(LibraryCoordinator.self) private var coordinator

    @FocusState private var queryFocused: Bool

    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 200), spacing: 22)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                if filter == .continueWatching {
                    continueSection
                } else {
                    header(filter.title, count: entries.count)
                    grid
                }
            }
            .padding(26)
        }
        .onChange(of: focusToken) { _, _ in queryFocused = true }
        .scrollContentBackground(.hidden)
        .background {
            LibraryBackdrop(entries: entries)
        }
        .overlay {
            if entries.isEmpty { emptyState }
        }
    }

    private var grid: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 26) {
            ForEach(entries) { entry in
                PosterCard(entry: entry)
                    .onTapGesture(count: 2) { session.play(entry: entry) }
                    .onTapGesture { onSelect(entry) }
                    .contextMenu { menu(for: entry) }
            }
        }
    }

    @ViewBuilder
    private var continueSection: some View {
        let items = store.continueWatching
        if items.isEmpty {
            header(String(localized: "Продолжить смотреть"), count: 0)
        } else {
            header(String(localized: "Продолжить смотреть"), count: items.count)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 300, maximum: 380), spacing: 20)],
                      alignment: .leading, spacing: 20) {
                ForEach(items) { item in
                    ContinueCard(item: item)
                        .onTapGesture { session.play(entry: item.entry, episode: item.episode) }
                        .contextMenu {
                            Button("Открыть карточку") { onSelect(item.entry) }
                            Button("Смотреть сначала") {
                                session.play(entry: item.entry, episode: item.episode, restart: true)
                            }
                            Button("Отметить просмотренным") {
                                store.setFinished(key: item.key, true)
                            }
                        }
                }
            }

            let recent = store.entries.sorted { $0.addedAt > $1.addedAt }.prefix(12)
            if !recent.isEmpty {
                header(String(localized: "Недавно добавленные"), count: nil)
                LazyVGrid(columns: columns, alignment: .leading, spacing: 26) {
                    ForEach(Array(recent)) { entry in
                        PosterCard(entry: entry)
                            .onTapGesture(count: 2) { session.play(entry: entry) }
                            .onTapGesture { onSelect(entry) }
                            .contextMenu { menu(for: entry) }
                    }
                }
            }
        }
    }

    private func header(_ title: String, count: Int?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(title).font(.system(size: 22, weight: .semibold))
            if let count {
                Text("\(count)")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .glassEffect(.regular, in: .capsule)
            }
            Spacer()
            librarySearchField
        }
    }

    private var librarySearchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            TextField("Поиск по библиотеке", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($queryFocused)
                .frame(width: 190)
                .onExitCommand { query = ""; queryFocused = false }
            if !query.isEmpty {
                Button {
                    query = ""
                    queryFocused = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .glassEffect(.regular, in: .capsule)
        .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 9 }
    }

    @ViewBuilder
    private func menu(for entry: MediaEntry) -> some View {
        Button("Смотреть") { session.play(entry: entry) }
        if entry.kind == .movie, store.watchState(for: entry.watchKey) != nil {
            Button("Смотреть сначала") { session.play(entry: entry, restart: true) }
        }
        Divider()
        Button(entry.isFavorite ? "Убрать из избранного" : "В избранное") {
            store.update(id: entry.id) { $0.isFavorite.toggle() }
        }
        Button(store.isFinished(entry) ? "Снять отметку «просмотрено»" : "Отметить просмотренным") {
            let finished = store.isFinished(entry)
            for key in entry.watchKeys { store.setFinished(key: key, !finished) }
        }
        Divider()
        Button("Уточнить в TMDB…") {
            Task {
                let candidates = await coordinator.search(query: entry.parsedTitle, kind: entry.kind)
                coordinator.enqueueForConfirmation(entry, candidates: candidates)
            }
        }
        Button("Показать файл в Finder") { revealInFinder(entry) }
        Divider()
        Button("Убрать из библиотеки", role: .destructive) { store.delete(id: entry.id) }
    }

    private func revealInFinder(_ entry: MediaEntry) {
        guard let file = entry.allFiles.first,
              let root = store.root(id: file.rootID) else { return }
        let path = (root.displayPath as NSString).appendingPathComponent(file.relativePath)
        NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: root.displayPath)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: query.isEmpty ? filter.symbol : "magnifyingglass")
                .font(.system(size: 40, weight: .thin))
                .foregroundStyle(.tertiary)
            Text(!query.isEmpty ? "В библиотеке ничего не найдено"
                 : filter == .continueWatching ? "Ничего не начато" : "Здесь пока пусто")
                .font(.title3.weight(.medium))
            Text(!query.isEmpty
                 ? "По запросу «\(query)» в этом разделе ничего нет. Поиск в правом верхнем углу ищет по всему TMDB."
                 : filter == .continueWatching
                 ? "Начните смотреть что-нибудь — и оно появится здесь с того места, где вы остановились."
                 : "Попробуйте другой раздел или добавьте ещё одну папку.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)
        }
    }
}

/// Широкая карточка «продолжить смотреть» с кадром и прогрессом.
struct ContinueCard: View {
    let item: LibraryStore.ContinueItem
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .bottomLeading) {
                CachedImage(url: TMDB.imageURL(path: item.episode?.stillPath ?? item.entry.backdropPath,
                                               size: .backdrop)) {
                    PosterPlaceholder(symbol: item.entry.kind == .show ? "tv" : "film")
                }
                .aspectRatio(16 / 9, contentMode: .fill)
                .frame(maxWidth: .infinity)
                .clipped()

                LinearGradient(colors: [.clear, .black.opacity(0.75)], startPoint: .center, endPoint: .bottom)

                VStack(alignment: .leading, spacing: 3) {
                    Text(item.entry.displayTitle)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    if let episode = item.episode {
                        Text("\(episode.displayCode) · \(episode.title)")
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.8))
                            .lineLimit(1)
                    } else {
                        Text("Осталось \(TimeFormat.clock(max(0, item.state.duration - item.state.position)))")
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.8))
                    }
                }
                .padding(12)

                if hovering {
                    Image(systemName: "play.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(.white)
                        .padding(14)
                        .glassEffect(.regular.interactive(), in: .circle)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .transition(.opacity)
                }
            }
            .aspectRatio(16 / 9, contentMode: .fit)

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Rectangle().fill(.quaternary)
                    Rectangle().fill(Color.accentColor).frame(width: geo.size.width * item.state.fraction)
                }
            }
            .frame(height: 3)
        }
        .clipShape(.rect(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14).strokeBorder(.white.opacity(hovering ? 0.3 : 0.08), lineWidth: 1)
        }
        .shadow(color: .black.opacity(hovering ? 0.28 : 0.14), radius: hovering ? 14 : 6, y: hovering ? 7 : 3)
        .scaleEffect(hovering ? 1.02 : 1)
        .onHover { value in
            withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) { hovering = value }
        }
    }
}

/// Мягкий фон из постеров библиотеки — чтобы стекло было на чём показать себя.
struct LibraryBackdrop: View {
    let entries: [MediaEntry]

    @Environment(PlaybackSession.self) private var session

    var body: some View {
        ZStack {
            Rectangle().fill(.background)
            // Пока открыт плеер, размытие не рисуем: окно библиотеки всё равно
            // за плеером, а размытие во весь экран — самая дорогая вещь в интерфейсе,
            // и делит видеопамять с выводом видео.
            if !session.isPresented,
               let path = entries.first(where: { $0.backdropPath != nil })?.backdropPath {
                CachedImage(url: TMDB.imageURL(path: path, size: .backdrop)) { Color.clear }
                    .blur(radius: 60, opaque: false)
                    .opacity(0.22)
                    .ignoresSafeArea()
            }
        }
        .ignoresSafeArea()
    }
}
