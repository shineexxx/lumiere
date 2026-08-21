import Foundation

/// Строит рекомендации по тому, что пользователь уже посмотрел.
///
/// Алгоритм в три шага:
/// 1. Из просмотренного собираем профиль вкусов — веса жанров и людей.
/// 2. Берём кандидатов двумя путями: «похожее на X» по конкретным тайтлам
///    и подбор по любимым жанрам. Первый путь точнее, второй шире.
/// 3. Ранжируем кандидатов по совпадению с профилем и отсеиваем то,
///    что уже есть в библиотеке.
nonisolated struct Recommender {

    let client: TMDBClient

    // MARK: - Профиль вкусов

    struct Taste {
        /// Название жанра → вес. Вес растёт от количества и свежести просмотров.
        var genres: [String: Double] = [:]
        var people: [String: Double] = [:]
        /// Тайтлы, от которых пляшем в «похожем».
        var seedMovies: [Int] = []
        var seedShows: [Int] = []
        /// Что уже в библиотеке — исключаем из выдачи.
        var knownMovieIDs: Set<Int> = []
        var knownShowIDs: Set<Int> = []

        var isEmpty: Bool { genres.isEmpty && seedMovies.isEmpty && seedShows.isEmpty }

        var topGenres: [String] {
            genres.sorted { $0.value > $1.value }.prefix(5).map(\.key)
        }
    }

    /// Собирает профиль. Досмотренное весит больше начатого,
    /// избранное — ещё больше, недавнее важнее давнего.
    static func taste(entries: [MediaEntry], watch: [UUID: WatchState]) -> Taste {
        var taste = Taste()
        let now = Date()

        // Кандидаты в «семена»: то, что смотрели, с приоритетом по свежести.
        var seeds: [(id: Int, kind: MediaKind, weight: Double, date: Date)] = []

        for entry in entries {
            if let tmdbID = entry.tmdbID {
                switch entry.kind {
                case .movie: taste.knownMovieIDs.insert(tmdbID)
                case .show: taste.knownShowIDs.insert(tmdbID)
                }
            }

            // Насколько активно карточку смотрели.
            let states = entry.watchKeys.compactMap { watch[$0] }
            guard !states.isEmpty else { continue }
            let finished = states.count { $0.isFinished }
            let started = states.count { $0.position > 60 }
            guard finished > 0 || started > 0 else { continue }

            let lastPlayed = states.map(\.lastPlayedAt).max() ?? now
            // Свежесть: за полгода вес падает примерно вдвое.
            let months = max(0, now.timeIntervalSince(lastPlayed) / (30 * 24 * 3600))
            let recency = 1.0 / (1.0 + months / 6)

            var weight = Double(finished) * 1.0 + Double(started - finished) * 0.35
            if entry.isFavorite { weight *= 1.6 }
            weight *= recency
            guard weight > 0 else { continue }

            for genre in entry.genres {
                taste.genres[genre, default: 0] += weight
            }
            for person in entry.cast.prefix(6) {
                taste.people[person.name, default: 0] += weight * 0.3
            }
            for director in entry.directors {
                taste.people[director, default: 0] += weight * 0.5
            }

            if let tmdbID = entry.tmdbID {
                seeds.append((tmdbID, entry.kind, weight, lastPlayed))
            }
        }

        let ranked = seeds.sorted { $0.weight > $1.weight }
        taste.seedMovies = ranked.filter { $0.kind == .movie }.prefix(4).map(\.id)
        taste.seedShows = ranked.filter { $0.kind == .show }.prefix(4).map(\.id)
        return taste
    }

    // MARK: - Подборки

    struct Shelf: Identifiable {
        var id: String { title }
        var title: String
        var subtitle: String?
        var items: [MatchCandidate]
    }

    /// Подборки для раздела «Новое и рекомендации».
    func shelves(taste: Taste) async -> [Shelf] {
        var shelves: [Shelf] = []

        // 1. Персональные рекомендации — только если есть история.
        if !taste.isEmpty {
            let personal = await personalRecommendations(taste: taste)
            if !personal.isEmpty {
                shelves.append(Shelf(title: "Вам может понравиться",
                                     subtitle: taste.topGenres.isEmpty
                                        ? "Подобрано по вашим просмотрам"
                                        : "По вашим просмотрам: " + taste.topGenres.prefix(3).joined(separator: ", "),
                                     items: personal))
            }
        }

        // 2. Общие подборки — они интересны и без истории.
        async let trendingMovies = safe { try await client.trendingMovies().map(MatchCandidate.init(movie:)) }
        async let trendingShows = safe { try await client.trendingShows().map(MatchCandidate.init(show:)) }
        async let topRated = safe { try await client.topRatedMovies().map(MatchCandidate.init(movie:)) }

        let movies = await trendingMovies
        if !movies.isEmpty {
            shelves.append(Shelf(title: "Популярное за неделю", subtitle: "Фильмы", items: filter(movies, taste)))
        }
        let shows = await trendingShows
        if !shows.isEmpty {
            shelves.append(Shelf(title: "Сериалы недели", subtitle: nil, items: filter(shows, taste)))
        }
        let rated = await topRated
        if !rated.isEmpty {
            shelves.append(Shelf(title: "Высокие оценки", subtitle: "Лучшее по мнению зрителей TMDB",
                                 items: filter(rated, taste)))
        }

        return shelves.filter { !$0.items.isEmpty }
    }

    /// Персональная подборка: «похожее» по любимым тайтлам плюс подбор по жанрам.
    func personalRecommendations(taste: Taste) async -> [MatchCandidate] {
        var pool: [MatchCandidate] = []

        // Похожее на конкретные просмотренные тайтлы.
        for id in taste.seedMovies {
            pool += await safe { try await client.recommendedMovies(for: id).map(MatchCandidate.init(movie:)) }
        }
        for id in taste.seedShows {
            pool += await safe { try await client.recommendedShows(for: id).map(MatchCandidate.init(show:)) }
        }

        // Подбор по любимым жанрам — расширяет выдачу за пределы «похожего».
        let genreIDs = await genreIDs(for: taste.topGenres)
        if !genreIDs.movies.isEmpty {
            pool += await safe { try await client.discoverMovies(genreIDs: genreIDs.movies).map(MatchCandidate.init(movie:)) }
        }
        if !genreIDs.shows.isEmpty {
            pool += await safe { try await client.discoverShows(genreIDs: genreIDs.shows).map(MatchCandidate.init(show:)) }
        }

        // Чем чаще тайтл встретился в разных источниках, тем он релевантнее.
        var frequency: [Int: Int] = [:]
        for item in pool { frequency[item.id, default: 0] += 1 }

        var seen = Set<Int>()
        var unique: [MatchCandidate] = []
        for item in pool where !seen.contains(item.id) {
            seen.insert(item.id)
            var scored = item
            let repeats = Double(frequency[item.id] ?? 1)
            let rating = (item.rating ?? 0) / 10
            scored.score = min(1, rating * 0.6 + min(repeats, 4) / 4 * 0.4)
            unique.append(scored)
        }

        return filter(unique, taste).sorted { $0.score > $1.score }.prefix(24).map { $0 }
    }

    /// Отбрасывает то, что уже в библиотеке, и совсем непопулярное.
    private func filter(_ items: [MatchCandidate], _ taste: Taste) -> [MatchCandidate] {
        items.filter { item in
            switch item.kind {
            case .movie: !taste.knownMovieIDs.contains(item.id)
            case .show: !taste.knownShowIDs.contains(item.id)
            }
        }
    }

    /// Переводит названия жанров обратно в идентификаторы TMDB.
    private func genreIDs(for names: [String]) async -> (movies: [Int], shows: [Int]) {
        guard !names.isEmpty else { return ([], []) }
        let movieGenres = await safe { try await client.movieGenres() }
        let showGenres = await safe { try await client.showGenres() }
        let wanted = Set(names.map { $0.lowercased() })
        return (movieGenres.filter { wanted.contains($0.name.lowercased()) }.map(\.id),
                showGenres.filter { wanted.contains($0.name.lowercased()) }.map(\.id))
    }

    /// Одна неудачная подборка не должна ронять весь экран.
    private func safe<T>(_ operation: () async throws -> [T]) async -> [T] {
        (try? await operation()) ?? []
    }
}
