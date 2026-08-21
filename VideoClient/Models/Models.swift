import Foundation

// MARK: - Library roots

/// Папка, которую пользователь добавил в библиотеку. Доступ к ней после перезапуска
/// восстанавливается через security-scoped bookmark.
nonisolated struct LibraryRoot: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var displayPath: String
    var bookmark: Data
    var addedAt: Date = Date()
}

// MARK: - Files

/// Ссылка на конкретный видеофайл: корень + относительный путь.
/// Абсолютные пути не храним — они ломаются при переносе внешнего диска.
nonisolated struct VideoFileRef: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var rootID: UUID
    var relativePath: String
    var fileName: String
    var fileSize: Int64 = 0
    var modifiedAt: Date = Date()

    var fileExtension: String { (fileName as NSString).pathExtension.lowercased() }
}

// MARK: - Media

nonisolated enum MediaKind: String, Codable, Hashable, CaseIterable {
    case movie
    case show
}

nonisolated enum MatchState: String, Codable, Hashable {
    /// Совпадение подобрано автоматически и ждёт подтверждения.
    case suggested
    /// Пользователь подтвердил (или выбрал вручную).
    case confirmed
    /// TMDB ничего не нашёл.
    case unmatched
    /// Пользователь отказался привязывать метаданные.
    case skipped
}

nonisolated struct Person: Codable, Hashable, Identifiable {
    var id: Int
    var name: String
    var role: String?
    var profilePath: String?
}

nonisolated struct EpisodeEntry: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var season: Int
    var episode: Int
    var title: String
    var overview: String?
    var stillPath: String?
    var airDate: Date?
    var runtime: Int?
    /// Файла может не быть: серия известна из TMDB, но не скачана
    /// (или файл удалили — отметка о просмотре при этом сохраняется).
    var file: VideoFileRef?

    var isAvailable: Bool { file != nil }

    /// Серия, дата выхода которой ещё не наступила.
    var isUpcoming: Bool {
        guard let airDate else { return false }
        return airDate > Date()
    }

    /// Технический код — используется в именах файлов (стандарт TMDB/Plex).
    var code: String { String(format: "S%02dE%02d", season, episode) }

    /// Как показываем пользователю: «4 сезон, 3 серия».
    var displayCode: String { "\(season) сезон, \(episode) серия" }

    /// Короткая форма для списка внутри уже выбранного сезона: «3 серия».
    var shortDisplay: String { "\(episode) серия" }

    /// Есть ли у серии данные с TMDB (а не заглушка «Эпизод N»).
    var hasMetadata: Bool { overview != nil || stillPath != nil || airDate != nil }

    /// Забирает у другой записи то, чего не хватает своей.
    /// Название-заглушку («Эпизод 9») настоящим названием перебиваем всегда.
    mutating func absorb(_ other: EpisodeEntry) {
        if file == nil { file = other.file }
        if !hasMetadata && other.hasMetadata {
            title = other.title
            overview = other.overview
            stillPath = other.stillPath
            airDate = other.airDate
            runtime = other.runtime
        } else {
            overview = overview ?? other.overview
            stillPath = stillPath ?? other.stillPath
            airDate = airDate ?? other.airDate
            runtime = runtime ?? other.runtime
        }
    }
}

/// Одна карточка в библиотеке: фильм (один файл) или сериал (много эпизодов).
nonisolated struct MediaEntry: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var kind: MediaKind

    // Что распарсили из имени файла — используется для поиска и как fallback заголовок.
    var parsedTitle: String
    var parsedYear: Int?

    // Метаданные TMDB
    var tmdbID: Int?
    var title: String?
    var originalTitle: String?
    var overview: String?
    var posterPath: String?
    var backdropPath: String?
    var rating: Double?
    var voteCount: Int?
    var releaseDate: Date?
    var genres: [String] = []
    var runtime: Int?
    var tagline: String?
    var cast: [Person] = []
    var directors: [String] = []

    var matchState: MatchState = .unmatched
    var addedAt: Date = Date()

    // Содержимое
    var movieFile: VideoFileRef?
    var episodes: [EpisodeEntry] = []

    // Пользовательское
    var isFavorite: Bool = false

    var displayTitle: String { title ?? parsedTitle }

    var displayYear: Int? {
        if let releaseDate { return Calendar.current.component(.year, from: releaseDate) }
        return parsedYear
    }

    /// Ключ, под которым хранится прогресс фильма. Не зависит от файла:
    /// удаление файла не стирает отметку о просмотре.
    var watchKey: UUID { id }

    /// Файлы, реально имеющиеся на диске.
    var allFiles: [VideoFileRef] {
        if let movieFile { return [movieFile] }
        return episodes.compactMap(\.file)
    }

    /// Есть ли что включить прямо сейчас.
    var isAvailable: Bool {
        switch kind {
        case .movie: movieFile != nil
        case .show: episodes.contains { $0.isAvailable }
        }
    }

    /// Ключи прогресса для всей карточки: фильм — один, сериал — по серии.
    var watchKeys: [UUID] {
        switch kind {
        case .movie: [watchKey]
        case .show: episodes.map(\.id)
        }
    }

    /// Серии, которые можно включить.
    var availableEpisodes: [EpisodeEntry] {
        episodes.filter(\.isAvailable)
    }

    var seasons: [Int] {
        Array(Set(episodes.map(\.season))).sorted()
    }

    func episodes(inSeason season: Int) -> [EpisodeEntry] {
        episodes.filter { $0.season == season }.sorted { $0.episode < $1.episode }
    }
}

// MARK: - Watch tracking

nonisolated struct WatchState: Codable, Hashable {
    /// Позиция в секундах.
    var position: Double = 0
    /// Длительность в секундах, как её сообщил плеер.
    var duration: Double = 0
    var lastPlayedAt: Date = Date()
    /// Явно отмечено просмотренным (вручную или досмотрено до конца).
    var isFinished: Bool = false
    /// Сколько раз досмотрен до конца.
    var playCount: Int = 0

    var fraction: Double {
        guard duration > 0 else { return 0 }
        return min(1, max(0, position / duration))
    }

    /// Есть ли смысл предлагать «продолжить»: начал, но не досмотрел.
    var isInProgress: Bool {
        !isFinished && position > WatchRules.resumeMinimum && fraction < WatchRules.finishedThreshold
    }

    /// Позиция, с которой стоит возобновить. В отличие от isInProgress не смотрит
    /// на отметку «просмотрено»: пересматривая, тоже удобно продолжать с места.
    var hasResumablePosition: Bool {
        position > WatchRules.resumeMinimum && fraction < WatchRules.finishedThreshold
    }
}

/// Русские склонения после числительных: 1 серия, 2 серии, 5 серий.
nonisolated enum Plural {
    static func format(_ count: Int, _ one: String, _ few: String, _ many: String) -> String {
        "\(count) \(word(count, one, few, many))"
    }

    static func word(_ count: Int, _ one: String, _ few: String, _ many: String) -> String {
        let mod100 = abs(count) % 100
        if (11...14).contains(mod100) { return many }
        switch abs(count) % 10 {
        case 1: return one
        case 2...4: return few
        default: return many
        }
    }

    static func episodes(_ count: Int) -> String { format(count, "серия", "серии", "серий") }
    static func seasons(_ count: Int) -> String { format(count, "сезон", "сезона", "сезонов") }
    static func items(_ count: Int) -> String { format(count, "карточка", "карточки", "карточек") }
    static func files(_ count: Int) -> String { format(count, "файл", "файла", "файлов") }
}

nonisolated enum WatchRules {
    /// С какой доли считаем фильм досмотренным.
    static let finishedThreshold: Double = 0.92
    /// Насколько отматываем назад при возобновлении, чтобы вспомнить контекст.
    static var resumeRewind: Double {
        Double(UserDefaults.standard.object(forKey: "resumeRewindSeconds") as? Int ?? 8)
    }

    /// С какой отметки предлагаем продолжить, а не начинать сначала.
    static var resumeMinimum: Double {
        Double(UserDefaults.standard.object(forKey: "resumeMinimumSeconds") as? Int ?? 15)
    }
}
