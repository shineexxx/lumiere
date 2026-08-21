import Foundation

/// Подбирает кандидатов TMDB для карточки и применяет выбранный вариант.
nonisolated struct Matcher {

    let client: TMDBClient

    // MARK: - Поиск кандидатов

    func candidates(for entry: MediaEntry) async throws -> [MatchCandidate] {
        let found = try await search(title: entry.parsedTitle, year: entry.parsedYear, preferring: entry.kind)

        // Регулярки справляются почти всегда. Модель зовём только когда результат
        // явно плохой: ничего не нашлось или лучшее совпадение слабое.
        let needsHelp = found.isEmpty || (found.first?.score ?? 0) < 0.5
        guard needsHelp, let guess = await TitleAI.shared.guess(from: entry.parsedTitle),
              LibraryScanner.normalizedKey(guess.title) != LibraryScanner.normalizedKey(entry.parsedTitle) else {
            return found
        }

        log.info("Заголовок переразобран встроенной моделью: «\(guess.title)»")
        let retry = try await search(title: guess.title,
                                     year: guess.year ?? entry.parsedYear,
                                     preferring: entry.kind)
        // Берём вариант модели, только если он объективно лучше прежнего.
        return (retry.first?.score ?? 0) > (found.first?.score ?? 0) ? retry : found
    }

    /// Ищет и в фильмах, и в сериалах. Определение типа по имени файла ненадёжно
    /// («4 сезон 7 серия» легко принять за фильм), поэтому показываем оба списка,
    /// а угаданный тип лишь слегка поднимаем в выдаче.
    func search(title: String, year: Int?, preferring kind: MediaKind?) async throws -> [MatchCandidate] {
        let query = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }

        async let movieResults = client.searchMovies(query, year: year)
        async let showResults = client.searchShows(query, year: year)

        var found = try await movieResults.map(MatchCandidate.init(movie:))
        found += try await showResults.map(MatchCandidate.init(show:))

        found = found.map { candidate in
            var scored = candidate
            var value = Self.score(candidate: candidate, title: query, year: year)
            if let kind, candidate.kind == kind { value = min(1, value + 0.08) }
            scored.score = value
            return scored
        }
        return found.sorted { $0.score > $1.score }
    }

    /// Насколько кандидат похож на то, что мы вытащили из имени файла.
    static func score(candidate: MatchCandidate, title: String, year: Int?) -> Double {
        let target = LibraryScanner.normalizedKey(title)
        let variants = [candidate.title, candidate.originalTitle].compactMap { $0 }.map(LibraryScanner.normalizedKey)
        var best = variants.map { similarity(target, $0) }.max() ?? 0

        if let year, let candidateYear = candidate.year {
            let delta = abs(year - candidateYear)
            // Год — сильный сигнал: точное попадание почти всегда означает верный фильм.
            if delta == 0 { best += 0.25 }
            else if delta == 1 { best += 0.05 }
            else { best -= 0.2 }
        }
        // При прочих равных предпочитаем то, что реально смотрели люди.
        if let rating = candidate.rating, rating > 0 { best += 0.02 }
        return min(1, max(0, best))
    }

    /// Нормализованное расстояние Левенштейна.
    static func similarity(_ a: String, _ b: String) -> Double {
        if a.isEmpty || b.isEmpty { return 0 }
        if a == b { return 1 }
        if a.contains(b) || b.contains(a) { return 0.9 }

        let source = Array(a), target = Array(b)
        var previous = Array(0...target.count)
        var current = [Int](repeating: 0, count: target.count + 1)

        for i in 1...source.count {
            current[0] = i
            for j in 1...target.count {
                let cost = source[i - 1] == target[j - 1] ? 0 : 1
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
            }
            swap(&previous, &current)
        }
        let distance = Double(previous[target.count])
        return max(0, 1 - distance / Double(max(source.count, target.count)))
    }

    /// Порог, выше которого совпадение считаем достаточно надёжным,
    /// чтобы предложить его пользователю по умолчанию.
    static let confidentThreshold: Double = 0.85

    // MARK: - Применение

    /// Переносит файлы между представлениями «фильм» (один файл) и «сериал» (эпизоды),
    /// чтобы при смене типа ничего не потерялось.
    static func convertKind(of entry: inout MediaEntry, to kind: MediaKind) {
        guard entry.kind != kind else { return }
        switch kind {
        case .show:
            if let file = entry.movieFile {
                // Номера серии нет — считаем первой серией первого сезона.
                let parsed = FilenameParser.parse(fileName: file.fileName)
                entry.episodes.append(EpisodeEntry(season: parsed.season ?? 1,
                                                   episode: parsed.episode ?? 1,
                                                   title: String(localized: "Эпизод \(parsed.episode ?? 1)"),
                                                   file: file))
                entry.movieFile = nil
            }
        case .movie:
            // У фильма один файл: берём самый крупный, остальные остаются недоступны,
            // пока пользователь не вернёт тип обратно.
            if entry.movieFile == nil {
                entry.movieFile = entry.episodes.compactMap(\.file).max { $0.fileSize < $1.fileSize }
                entry.episodes.removeAll()
            }
        }
        entry.kind = kind
    }

    /// Загружает полные метаданные выбранного кандидата и вписывает их в карточку.
    func apply(candidate: MatchCandidate, to entry: MediaEntry) async throws -> MediaEntry {
        var updated = entry
        updated.tmdbID = candidate.id
        updated.matchState = .confirmed
        // Тип мог быть угадан неверно — перекладываем файлы под выбранный.
        Self.convertKind(of: &updated, to: candidate.kind)

        switch candidate.kind {
        case .movie:
            let detail = try await client.movieDetail(id: candidate.id)
            updated.kind = .movie
            updated.title = detail.title
            updated.originalTitle = detail.original_title
            updated.overview = detail.overview
            updated.posterPath = detail.poster_path
            updated.backdropPath = detail.backdrop_path
            updated.rating = detail.vote_average
            updated.voteCount = detail.vote_count
            updated.releaseDate = TMDB.date(from: detail.release_date)
            updated.genres = detail.genres.map(\.name)
            updated.runtime = detail.runtime
            updated.tagline = detail.tagline
            updated.cast = (detail.credits?.cast.prefix(12) ?? []).map {
                Person(id: $0.id, name: $0.name, role: $0.character, profilePath: $0.profile_path)
            }
            updated.directors = (detail.credits?.crew ?? []).filter { $0.job == "Director" }.map(\.name)

        case .show:
            let detail = try await client.showDetail(id: candidate.id)
            updated.kind = .show
            updated.title = detail.name
            updated.originalTitle = detail.original_name
            updated.overview = detail.overview
            updated.posterPath = detail.poster_path
            updated.backdropPath = detail.backdrop_path
            updated.rating = detail.vote_average
            updated.voteCount = detail.vote_count
            updated.releaseDate = TMDB.date(from: detail.first_air_date)
            updated.genres = detail.genres.map(\.name)
            updated.runtime = detail.episode_run_time.first
            updated.tagline = detail.tagline
            updated.cast = (detail.credits?.cast.prefix(12) ?? []).map {
                Person(id: $0.id, name: $0.name, role: $0.character, profilePath: $0.profile_path)
            }
            updated.directors = (detail.credits?.crew ?? []).filter { $0.job == "Creator" || $0.job == "Executive Producer" }
                .prefix(3).map(\.name)

            updated = try await fillEpisodes(in: updated, showID: candidate.id, allSeasons: detail.seasons)
        }
        return updated
    }

    /// Заполняет список серий по данным TMDB.
    /// Берём все сезоны сериала, а не только те, что есть на диске: карточка должна
    /// показывать сериал целиком, помечая, что скачано, а что нет.
    func fillEpisodes(in entry: MediaEntry,
                      showID: Int,
                      allSeasons: [TMDB.SeasonStub] = []) async throws -> MediaEntry {
        var updated = entry

        // Обычные сезоны берём все; спецвыпуски (сезон 0) — только если под них есть файлы.
        var numbers = Set(allSeasons.map(\.season_number).filter { $0 >= 1 })
        numbers.formUnion(entry.seasons)
        if !entry.seasons.contains(0) { numbers.remove(0) }

        for seasonNumber in numbers.sorted() {
            guard let season = try? await client.season(showID: showID, season: seasonNumber) else { continue }
            for meta in season.episodes {
                let title = meta.name ?? String(localized: "Эпизод \(meta.episode_number)")
                if let index = updated.episodes.firstIndex(where: {
                    $0.season == seasonNumber && $0.episode == meta.episode_number
                }) {
                    // Серия уже есть (обычно с файлом) — обновляем метаданные, id не трогаем:
                    // к нему привязана отметка о просмотре.
                    updated.episodes[index].title = title
                    updated.episodes[index].overview = meta.overview
                    updated.episodes[index].stillPath = meta.still_path
                    updated.episodes[index].airDate = TMDB.date(from: meta.air_date)
                    updated.episodes[index].runtime = meta.runtime
                } else {
                    // Серии нет на диске — добавляем как метаданные, без файла.
                    updated.episodes.append(EpisodeEntry(season: seasonNumber,
                                                         episode: meta.episode_number,
                                                         title: title,
                                                         overview: meta.overview,
                                                         stillPath: meta.still_path,
                                                         airDate: TMDB.date(from: meta.air_date),
                                                         runtime: meta.runtime,
                                                         file: nil))
                }
            }
        }
        updated.episodes.sort { ($0.season, $0.episode) < ($1.season, $1.episode) }
        return updated
    }
}
