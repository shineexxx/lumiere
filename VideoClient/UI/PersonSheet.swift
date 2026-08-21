import SwiftUI

/// Страница актёра: фотография, биография и вся фильмография с TMDB.
/// Открывается из состава фильма или сериала; из неё же можно провалиться
/// в карточку любого фильма — в том числе того, которого нет на диске.
struct PersonSheet: View {
    let person: Person
    let onOpenInLibrary: (MediaEntry) -> Void

    @Environment(LibraryStore.self) private var store
    @Environment(LibraryCoordinator.self) private var coordinator
    @Environment(\.dismiss) private var dismiss

    @State private var detail: TMDB.PersonDetail?
    @State private var credits: [MatchCandidate] = []
    @State private var isLoading = true
    @State private var loadError: String?
    @State private var isBiographyExpanded = false
    @State private var preview: MatchCandidate?

    private let columns = [GridItem(.adaptive(minimum: 130, maximum: 160), spacing: 16)]

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    header
                    if let biography = detail?.biography, !biography.isEmpty {
                        biographySection(biography)
                    }
                    if let loadError {
                        Label(loadError, systemImage: "wifi.exclamationmark")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    if !credits.isEmpty { filmography }
                    if isLoading {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Загружаю фильмографию…").font(.callout).foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(24)
            }
            Divider()
            HStack {
                Spacer()
                Button("Закрыть") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(16)
        }
        .frame(width: 760, height: 660)
        .task { await load() }
        .sheet(item: $preview) { candidate in
            PreviewSheet(candidate: candidate) { entry in
                dismiss()
                onOpenInLibrary(entry)
            }
            .environment(store)
            .environment(coordinator)
        }
    }

    // MARK: - Шапка

    private var header: some View {
        HStack(alignment: .top, spacing: 18) {
            CachedImage(url: TMDB.imageURL(path: detail?.profile_path ?? person.profilePath, size: .poster)) {
                PosterPlaceholder(symbol: "person.fill")
            }
            .frame(width: 130, height: 195)
            .clipShape(.rect(cornerRadius: 14))
            .shadow(color: .black.opacity(0.28), radius: 12, y: 6)

            VStack(alignment: .leading, spacing: 8) {
                Text(detail?.name ?? person.name)
                    .font(.system(size: 24, weight: .bold))
                    .lineLimit(2)
                if let role = person.role, !role.isEmpty {
                    Text("В этой карточке: \(role)")
                        .font(.callout).foregroundStyle(.secondary)
                }
                HStack(spacing: 8) {
                    if let department = detail?.known_for_department, !department.isEmpty {
                        chip(department)
                    }
                    if let years = lifeYears { chip(years) }
                    if !credits.isEmpty {
                        chip(Plural.format(credits.count, Plural.rolesForms))
                    }
                }
                .font(.system(size: 12, weight: .medium))
                if let place = detail?.place_of_birth, !place.isEmpty {
                    Text(place).font(.system(size: 12)).foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 0)
        }
    }

    /// «1974 — 2008» или просто год рождения.
    private var lifeYears: String? {
        guard let birth = detail?.birthday?.prefix(4), !birth.isEmpty else { return nil }
        if let death = detail?.deathday?.prefix(4), !death.isEmpty {
            return "\(birth) — \(death)"
        }
        return String(birth)
    }

    private func chip(_ text: String) -> some View {
        Text(text)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .glassEffect(.regular, in: .capsule)
    }

    // MARK: - Биография

    private func biographySection(_ biography: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(biography)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .lineLimit(isBiographyExpanded ? nil : 5)
                .fixedSize(horizontal: false, vertical: true)
            // Биографии у TMDB бывают на несколько экранов — по умолчанию сворачиваем.
            if biography.count > 400 {
                Button(isBiographyExpanded ? "Свернуть" : "Читать дальше") {
                    withAnimation(.easeInOut(duration: 0.2)) { isBiographyExpanded.toggle() }
                }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.accentColor)
            }
        }
    }

    // MARK: - Фильмография

    private var filmography: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Фильмография").font(.system(size: 19, weight: .semibold))
            LazyVGrid(columns: columns, alignment: .leading, spacing: 18) {
                ForEach(credits) { candidate in
                    DiscoverCard(candidate: candidate,
                                 onSelect: { entry in
                                     dismiss()
                                     onOpenInLibrary(entry)
                                 },
                                 onPreview: { preview = $0 })
                }
            }
        }
    }

    // MARK: - Загрузка

    private func load() async {
        defer { isLoading = false }
        guard await coordinator.client.hasKey else {
            loadError = String(localized: "Не задан API-ключ TMDB. Откройте Настройки (⌘,) и добавьте ключ.")
            return
        }
        do {
            async let details = coordinator.client.personDetail(id: person.id)
            async let roles = coordinator.client.personCredits(id: person.id)
            detail = try await details
            credits = MatchCandidate.filmography(from: try await roles)
        } catch {
            loadError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

}
