import SwiftUI

/// Просмотр карточки из рекомендаций без добавления в библиотеку:
/// описание, рейтинг, состав — и только по явной кнопке добавление.
struct PreviewSheet: View {
    let candidate: MatchCandidate
    let onOpenInLibrary: (MediaEntry) -> Void

    @Environment(LibraryStore.self) private var store
    @Environment(LibraryCoordinator.self) private var coordinator
    @Environment(\.dismiss) private var dismiss

    @State private var details: MediaEntry?
    @State private var isLoading = true
    @State private var isAdding = false
    /// Открытая страница актёра.
    @State private var selectedPerson: Person?

    /// Карточка может уже быть в библиотеке — тогда предлагаем её открыть.
    private var existing: MediaEntry? {
        store.entries.first { $0.tmdbID == candidate.id && $0.kind == candidate.kind }
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    hero
                    if let overview = (details?.overview ?? candidate.overview), !overview.isEmpty {
                        Text(overview)
                            .font(.system(size: 14))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let details, !details.cast.isEmpty {
                        castSection(details.cast)
                    }
                    if isLoading {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Загружаю подробности…").font(.callout).foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(24)
            }
            Divider()
            footer
        }
        .frame(width: 680, height: 620)
        .task { await loadDetails() }
        .sheet(item: $selectedPerson) { person in
            PersonSheet(person: person) { entry in
                dismiss()
                onOpenInLibrary(entry)
            }
            .environment(store)
            .environment(coordinator)
        }
    }

    private var hero: some View {
        HStack(alignment: .top, spacing: 20) {
            CachedImage(url: TMDB.imageURL(path: details?.posterPath ?? candidate.posterPath, size: .poster))
                .aspectRatio(2 / 3, contentMode: .fill)
                .frame(width: 160)
                .clipShape(.rect(cornerRadius: 14))
                .shadow(color: .black.opacity(0.3), radius: 14, y: 7)

            VStack(alignment: .leading, spacing: 10) {
                Text(details?.displayTitle ?? candidate.title)
                    .font(.system(size: 24, weight: .bold))
                    .lineLimit(3)
                if let original = details?.originalTitle ?? candidate.originalTitle,
                   original != (details?.displayTitle ?? candidate.title) {
                    Text(original).font(.callout).foregroundStyle(.secondary)
                }
                if let tagline = details?.tagline, !tagline.isEmpty {
                    Text(tagline).font(.callout.italic()).foregroundStyle(.tertiary)
                }

                HStack(spacing: 8) {
                    if let year = details?.displayYear ?? candidate.year {
                        chip(String(year))
                    }
                    if let rating = details?.rating ?? candidate.rating, rating > 0 {
                        chip(String(format: "★ %.1f", rating), tint: .yellow)
                    }
                    if let runtime = details?.runtime, runtime > 0 {
                        chip(TimeFormat.runtime(minutes: runtime))
                    }
                    chip(candidate.kind == .movie ? "Фильм" : "Сериал")
                }
                .font(.system(size: 12, weight: .medium))

                if let genres = details?.genres, !genres.isEmpty {
                    Text(genres.joined(separator: " · "))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }

                if !isLoading {
                    Label("Нет в библиотеке — это карточка с TMDB",
                          systemImage: existing == nil ? "sparkles" : "checkmark.circle")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .opacity(existing == nil ? 1 : 0)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func chip(_ text: String, tint: Color? = nil) -> some View {
        Text(text)
            .foregroundStyle(tint ?? .primary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .glassEffect(.regular, in: .capsule)
    }

    private func castSection(_ cast: [Person]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("В ролях").font(.system(size: 16, weight: .semibold))
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 14) {
                    ForEach(cast) { person in
                        Button {
                            selectedPerson = person
                        } label: {
                            VStack(spacing: 5) {
                            CachedImage(url: TMDB.imageURL(path: person.profilePath, size: .profile)) {
                                PosterPlaceholder(symbol: "person.fill")
                            }
                            .frame(width: 62, height: 62)
                            .clipShape(.circle)
                            Text(person.name)
                                .font(.system(size: 10, weight: .medium))
                                .lineLimit(1)
                            if let role = person.role, !role.isEmpty {
                                Text(role).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
                            }
                            }
                            .frame(width: 78)
                        }
                        .buttonStyle(.plain)
                        .help(String(localized: "Открыть страницу актёра"))
                    }
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if let existing {
                Button("Открыть в библиотеке") {
                    dismiss()
                    onOpenInLibrary(existing)
                }
                .buttonStyle(.glassProminent)
            } else {
                Button {
                    add(andOpen: false)
                } label: {
                    if isAdding {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Добавить в библиотеку", systemImage: "plus")
                    }
                }
                .buttonStyle(.glassProminent)
                .disabled(isAdding)

                Button("Добавить и открыть") { add(andOpen: true) }
                    .buttonStyle(.glass)
                    .disabled(isAdding)
            }

            Spacer()

            Button("Закрыть") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(16)
    }

    private func loadDetails() async {
        details = await coordinator.preview(for: candidate)
        isLoading = false
    }

    private func add(andOpen: Bool) {
        isAdding = true
        Task {
            let added = await coordinator.addFromTMDB(candidate)
            isAdding = false
            dismiss()
            if andOpen, let added { onOpenInLibrary(added) }
        }
    }
}
