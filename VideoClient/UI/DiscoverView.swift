import SwiftUI

/// Раздел «Новое и рекомендации»: горизонтальные полки подборок TMDB.
struct DiscoverView: View {
    @Environment(LibraryStore.self) private var store
    @Environment(LibraryCoordinator.self) private var coordinator
    let onSelect: (MediaEntry) -> Void

    @State private var shelves: [Recommender.Shelf] = []
    @State private var isLoading = false
    @State private var loadError: String?
    @State private var preview: MatchCandidate?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                header

                if isLoading && shelves.isEmpty {
                    loadingState
                } else if let loadError, shelves.isEmpty {
                    errorState(loadError)
                } else {
                    ForEach(shelves) { shelf in
                        ShelfRow(shelf: shelf, onSelect: onSelect, onPreview: { preview = $0 })
                    }
                }
            }
            .padding(26)
        }
        .scrollContentBackground(.hidden)
        .background { Rectangle().fill(.background).ignoresSafeArea() }
        .task { await loadIfNeeded() }
        .sheet(item: $preview) { candidate in
            PreviewSheet(candidate: candidate, onOpenInLibrary: onSelect)
                .environment(store)
                .environment(coordinator)
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Новое и рекомендации")
                    .font(.system(size: 26, weight: .bold))
                Text("Подборки с TMDB. То, что уже есть в библиотеке, скрыто.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                Task { await load(force: true) }
            } label: {
                Label("Обновить", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.glass)
            .disabled(isLoading)
        }
    }

    private var loadingState: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("Собираю подборки…").font(.callout).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 260)
    }

    private func errorState(_ message: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 36, weight: .thin))
                .foregroundStyle(.tertiary)
            Text("Не удалось загрузить подборки").font(.title3.weight(.medium))
            Text(message)
                .font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).frame(maxWidth: 420)
            Button("Повторить") { Task { await load(force: true) } }
                .buttonStyle(.glassProminent)
        }
        .frame(maxWidth: .infinity, minHeight: 260)
    }

    private func loadIfNeeded() async {
        guard shelves.isEmpty else { return }
        await load(force: false)
    }

    private func load(force: Bool) async {
        guard !isLoading else { return }
        isLoading = true
        loadError = nil
        defer { isLoading = false }

        guard await coordinator.client.hasKey else {
            loadError = "Не задан API-ключ TMDB. Откройте Настройки (⌘,) и добавьте ключ."
            return
        }
        let taste = Recommender.taste(entries: store.entries, watch: store.watch)
        let result = await Recommender(client: coordinator.client).shelves(taste: taste)
        shelves = result
        if result.isEmpty {
            loadError = "TMDB не вернул подборок. Проверьте соединение и попробуйте ещё раз."
        }
    }
}

/// Одна горизонтальная полка подборки.
struct ShelfRow: View {
    let shelf: Recommender.Shelf
    let onSelect: (MediaEntry) -> Void
    let onPreview: (MatchCandidate) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(shelf.title).font(.system(size: 19, weight: .semibold))
                if let subtitle = shelf.subtitle {
                    Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 16) {
                    ForEach(shelf.items) { item in
                        DiscoverCard(candidate: item, onSelect: onSelect, onPreview: onPreview)
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }
}

/// Карточка из подборки: постер, рейтинг и кнопка «в библиотеку».
struct DiscoverCard: View {
    let candidate: MatchCandidate
    let onSelect: (MediaEntry) -> Void
    let onPreview: (MatchCandidate) -> Void

    @Environment(LibraryStore.self) private var store
    @Environment(LibraryCoordinator.self) private var coordinator
    @State private var hovering = false
    @State private var isAdding = false

    /// Уже добавленная карточка — открываем её вместо повторного добавления.
    private var existing: MediaEntry? {
        store.entries.first { $0.tmdbID == candidate.id && $0.kind == candidate.kind }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                CachedImage(url: TMDB.imageURL(path: candidate.posterPath, size: .poster))
                    .aspectRatio(2 / 3, contentMode: .fill)
                    .frame(width: 150, height: 225)
                    .clipShape(.rect(cornerRadius: 12))

                if hovering {
                    ZStack {
                        RoundedRectangle(cornerRadius: 12).fill(.black.opacity(0.35))
                        if isAdding {
                            ProgressView().controlSize(.small)
                        } else {
                            VStack(spacing: 8) {
                                Label("Подробнее", systemImage: "info.circle")
                                    .font(.system(size: 12, weight: .medium))
                                    .padding(.horizontal, 12).padding(.vertical, 8)
                                    .glassEffect(.regular.interactive(), in: .capsule)
                                // Добавление — отдельным действием: просмотр описания
                                // не должен засорять библиотеку.
                                Button {
                                    addToLibrary()
                                } label: {
                                    Label(existing == nil ? "В библиотеку" : "Открыть",
                                          systemImage: existing == nil ? "plus" : "arrow.right")
                                        .font(.system(size: 11, weight: .medium))
                                        .padding(.horizontal, 10).padding(.vertical, 6)
                                }
                                .buttonStyle(.glass)
                            }
                        }
                    }
                    .transition(.opacity)
                }
            }
            .overlay(alignment: .topTrailing) {
                if let rating = candidate.rating, rating > 0 {
                    HStack(spacing: 3) {
                        Image(systemName: "star.fill").font(.system(size: 8))
                        Text(String(format: "%.1f", rating)).font(.system(size: 11, weight: .semibold))
                    }
                    .padding(.horizontal, 7).padding(.vertical, 4)
                    .glassEffect(.regular, in: .capsule)
                    .padding(8)
                }
            }
            .shadow(color: .black.opacity(hovering ? 0.3 : 0.15), radius: hovering ? 12 : 5, y: hovering ? 6 : 3)
            .scaleEffect(hovering ? 1.03 : 1)

            VStack(alignment: .leading, spacing: 2) {
                Text(candidate.title)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(2)
                    .frame(height: 32, alignment: .top)
                HStack(spacing: 4) {
                    if let year = candidate.year { Text(String(year)) }
                    Text(candidate.kind == .movie ? "фильм" : "сериал")
                }
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            }
            .frame(width: 150, alignment: .leading)
        }
        .onHover { value in
            withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) { hovering = value }
        }
        .onTapGesture { activate() }
        .help(candidate.overview ?? "")
    }

    /// Клик по карточке показывает описание, ничего не добавляя.
    private func activate() {
        onPreview(candidate)
    }

    private func addToLibrary() {
        if let existing {
            onSelect(existing)
            return
        }
        isAdding = true
        Task {
            if let added = await coordinator.addFromTMDB(candidate) {
                onSelect(added)
            }
            isAdding = false
        }
    }
}
