import Foundation

/// DTO ответов TMDB. Только те поля, которые реально используем.
nonisolated enum TMDB {

    struct SearchPage<T: Decodable>: Decodable {
        var page: Int
        var results: [T]
        var total_results: Int
    }

    struct MovieResult: Decodable, Identifiable, Hashable {
        var id: Int
        var title: String
        var original_title: String?
        var overview: String?
        var poster_path: String?
        var backdrop_path: String?
        var release_date: String?
        var vote_average: Double?
        var vote_count: Int?

        var year: Int? { release_date.flatMap { Int($0.prefix(4)) } }
    }

    struct ShowResult: Decodable, Identifiable, Hashable {
        var id: Int
        var name: String
        var original_name: String?
        var overview: String?
        var poster_path: String?
        var backdrop_path: String?
        var first_air_date: String?
        var vote_average: Double?
        var vote_count: Int?

        var year: Int? { first_air_date.flatMap { Int($0.prefix(4)) } }
    }

    /// Ответ /search/multi: фильмы, сериалы и люди в одном списке, в порядке
    /// релевантности самого TMDB. Для глобального поиска это лучше, чем
    /// склеивать два отдельных запроса и пересортировывать их у себя.
    struct MultiResult: Decodable, Identifiable, Hashable {
        var id: Int
        var media_type: String?
        var title: String?
        var name: String?
        var original_title: String?
        var original_name: String?
        var overview: String?
        var poster_path: String?
        var release_date: String?
        var first_air_date: String?
        var vote_average: Double?
    }

    struct Genre: Decodable, Hashable { var id: Int; var name: String }

    struct CreditsResponse: Decodable {
        struct CastMember: Decodable {
            var id: Int
            var name: String
            var character: String?
            var profile_path: String?
        }
        struct CrewMember: Decodable {
            var id: Int
            var name: String
            var job: String?
        }
        var cast: [CastMember] = []
        var crew: [CrewMember] = []
    }

    struct MovieDetail: Decodable {
        var id: Int
        var title: String
        var original_title: String?
        var overview: String?
        var poster_path: String?
        var backdrop_path: String?
        var release_date: String?
        var vote_average: Double?
        var vote_count: Int?
        var runtime: Int?
        var tagline: String?
        var genres: [Genre] = []
        var credits: CreditsResponse?
    }

    struct SeasonStub: Decodable {
        var season_number: Int
        var episode_count: Int?
        var name: String?
    }

    struct ShowDetail: Decodable {
        var id: Int
        var name: String
        var seasons: [SeasonStub] = []
        var original_name: String?
        var overview: String?
        var poster_path: String?
        var backdrop_path: String?
        var first_air_date: String?
        var vote_average: Double?
        var vote_count: Int?
        var episode_run_time: [Int] = []
        var tagline: String?
        var genres: [Genre] = []
        var credits: CreditsResponse?
    }

    struct SeasonDetail: Decodable {
        struct Episode: Decodable {
            var id: Int
            var episode_number: Int
            var season_number: Int?
            var name: String?
            var overview: String?
            var still_path: String?
            var air_date: String?
            var runtime: Int?
        }
        var season_number: Int
        var episodes: [Episode] = []
    }

    /// Размеры картинок, которые отдаёт CDN TMDB.
    enum ImageSize: String {
        case posterSmall = "w185"
        case poster = "w500"
        case posterLarge = "w780"
        case backdrop = "w1280"
        case still = "w300"
        case original
        /// Аватары актёров используют тот же размер, что и мелкий постер.
        static let profile = ImageSize.posterSmall
    }

    static func imageURL(path: String?, size: ImageSize) -> URL? {
        guard let path, !path.isEmpty else { return nil }
        return URL(string: "https://image.tmdb.org/t/p/\(size.rawValue)\(path)")
    }

    static func date(from string: String?) -> Date? {
        guard let string, !string.isEmpty else { return nil }
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: string)
    }
}

/// Единый вид результата поиска для UI подтверждения.
nonisolated struct MatchCandidate: Identifiable, Hashable {
    var id: Int
    var kind: MediaKind
    var title: String
    var originalTitle: String?
    var year: Int?
    var overview: String?
    var posterPath: String?
    var rating: Double?
    /// Насколько уверенно совпало с распарсенным именем (0…1).
    var score: Double = 0

    init(movie: TMDB.MovieResult) {
        id = movie.id
        kind = .movie
        title = movie.title
        originalTitle = movie.original_title
        year = movie.year
        overview = movie.overview
        posterPath = movie.poster_path
        rating = movie.vote_average
    }

    /// Строка из /search/multi. Люди в выдаче тоже встречаются — их пропускаем.
    init?(multi: TMDB.MultiResult) {
        let resolved: (kind: MediaKind, title: String, original: String?, year: Int?)
        switch multi.media_type {
        case "movie":
            resolved = (.movie,
                        multi.title ?? multi.original_title ?? "",
                        multi.original_title,
                        multi.release_date.flatMap { Int($0.prefix(4)) })
        case "tv":
            resolved = (.show,
                        multi.name ?? multi.original_name ?? "",
                        multi.original_name,
                        multi.first_air_date.flatMap { Int($0.prefix(4)) })
        default:
            return nil
        }
        guard !resolved.title.isEmpty else { return nil }
        kind = resolved.kind
        title = resolved.title
        originalTitle = resolved.original
        year = resolved.year
        id = multi.id
        overview = multi.overview
        posterPath = multi.poster_path
        rating = multi.vote_average
    }

    init(show: TMDB.ShowResult) {
        id = show.id
        kind = .show
        title = show.name
        originalTitle = show.original_name
        year = show.year
        overview = show.overview
        posterPath = show.poster_path
        rating = show.vote_average
    }
}
