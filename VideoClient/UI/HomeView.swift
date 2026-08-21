import SwiftUI

/// «Главная»: продолжение просмотра, недавнее и вся библиотека в одном экране.
struct HomeView: View {
    @Environment(LibraryStore.self) private var store
    @Environment(PlaybackSession.self) private var session
    let onSelect: (MediaEntry) -> Void
    let onOpenFilter: (LibraryFilter) -> Void

    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 200), spacing: 22)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                greeting

                if !store.continueWatching.isEmpty {
                    continueSection
                }
                if !recentlyAdded.isEmpty {
                    section(String(localized: "Недавно добавленные"), filter: .all, entries: recentlyAdded)
                }
                if !availableNow.isEmpty {
                    section(String(localized: "Готово к просмотру"), filter: .available, entries: availableNow)
                }
                if !unfinishedShows.isEmpty {
                    section(String(localized: "Сериалы в процессе"), filter: .shows, entries: unfinishedShows)
                }
                if store.entries.isEmpty {
                    emptyHint
                }
            }
            .padding(26)
        }
        .scrollContentBackground(.hidden)
        .background { LibraryBackdrop(entries: Array(store.entries.prefix(1))) }
    }

    private var greeting: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(timeGreeting)
                .font(.system(size: 28, weight: .bold))
            HStack(spacing: 6) {
                Text(Plural.items(store.entries.count))
                Text("·")
                Text("\(store.entries.count(where: \.isAvailable)) на диске")
                if watchedCount > 0 {
                    Text("·")
                    Text("\(watchedCount) просмотрено")
                }
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        }
    }

    private var timeGreeting: String {
        switch Calendar.current.component(.hour, from: Date()) {
        case 5..<12: String(localized: "Доброе утро")
        case 12..<18: String(localized: "Добрый день")
        case 18..<23: String(localized: "Добрый вечер")
        default: String(localized: "Доброй ночи")
        }
    }

    private var watchedCount: Int {
        store.entries.count { store.isFinished($0) }
    }

    private var continueSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionHeader(String(localized: "Продолжить смотреть"), filter: .continueWatching)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 300, maximum: 380), spacing: 20)],
                      alignment: .leading, spacing: 20) {
                ForEach(store.continueWatching.prefix(6)) { item in
                    ContinueCard(item: item)
                        .onTapGesture {
                            if item.isAvailable {
                                session.play(entry: item.entry, episode: item.episode)
                            } else {
                                onSelect(item.entry)
                            }
                        }
                }
            }
        }
    }

    private func section(_ title: String, filter: LibraryFilter, entries: [MediaEntry]) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionHeader(title, filter: filter)
            LazyVGrid(columns: columns, alignment: .leading, spacing: 26) {
                ForEach(entries) { entry in
                    PosterCard(entry: entry)
                        .onTapGesture { onSelect(entry) }
                }
            }
        }
    }

    private func sectionHeader(_ title: String, filter: LibraryFilter) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.system(size: 20, weight: .semibold))
            Spacer()
            Button {
                onOpenFilter(filter)
            } label: {
                HStack(spacing: 3) {
                    Text("Все")
                    Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
                }
                .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
    }

    private var emptyHint: some View {
        VStack(spacing: 10) {
            Image(systemName: "film.stack")
                .font(.system(size: 44, weight: .thin))
                .foregroundStyle(.tertiary)
            Text("Библиотека пуста").font(.title3.weight(.medium))
            Text("Добавьте папку с видео (⌘O) или загляните в «Новое и рекомендации» — оттуда можно добавлять фильмы как метаданные, без файлов.")
                .font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).frame(maxWidth: 460)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    // MARK: - Выборки

    private var recentlyAdded: [MediaEntry] {
        Array(store.entries.sorted { $0.addedAt > $1.addedAt }.prefix(12))
    }

    private var availableNow: [MediaEntry] {
        Array(store.entries.filter { $0.isAvailable && !store.isFinished($0) }
            .sorted { $0.displayTitle.localizedCompare($1.displayTitle) == .orderedAscending }
            .prefix(12))
    }

    private var unfinishedShows: [MediaEntry] {
        Array(store.entries.filter { entry in
            entry.kind == .show && !store.isFinished(entry) && store.watchedEpisodeCount(entry) > 0
        }.prefix(12))
    }
}
