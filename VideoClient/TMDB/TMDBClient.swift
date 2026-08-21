import Foundation

enum TMDBError: LocalizedError {
    case missingKey
    case unauthorized
    case http(Int)
    case decoding(String)

    var errorDescription: String? {
        switch self {
        case .missingKey: String(localized: "Не задан API-ключ TMDB — откройте Настройки.")
        case .unauthorized: String(localized: "TMDB отклонил ключ. Проверьте его в настройках.")
        case .http(let code): String(localized: "TMDB ответил ошибкой \(code).")
        case .decoding(let detail): String(localized: "Не удалось разобрать ответ TMDB: \(detail)")
        }
    }
}

/// Клиент TMDB v3. Поддерживает и короткий API-ключ (v3), и длинный Bearer-токен (v4).
actor TMDBClient {

    /// Идентификатор старой записи в связке ключей — нужен только для переноса.
    static let keychainAccount = "tmdb-api-key"

    private let session: URLSession
    private var key: String?
    private var language: String

    init(key: String? = TMDBKeyStore.key, language: String = MetadataLanguage.effective) {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 20
        config.requestCachePolicy = .returnCacheDataElseLoad
        self.session = URLSession(configuration: config)
        self.key = key?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.language = language
    }

    func setKey(_ newKey: String?) {
        key = newKey?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func setLanguage(_ newLanguage: String) {
        language = newLanguage
    }

    var hasKey: Bool { !(key ?? "").isEmpty }

    /// Проверка ключа при сохранении в настройках.
    func validateKey() async -> Result<Void, Error> {
        do {
            let _: TMDB.SearchPage<TMDB.MovieResult> = try await get("/search/movie", query: ["query": "matrix"])
            return .success(())
        } catch {
            return .failure(error)
        }
    }

    // MARK: - Endpoints

    func searchMovies(_ title: String, year: Int?) async throws -> [TMDB.MovieResult] {
        var query = ["query": title]
        if let year { query["year"] = String(year) }
        let page: TMDB.SearchPage<TMDB.MovieResult> = try await get("/search/movie", query: query)
        if page.results.isEmpty, year != nil {
            // Год из имени файла часто относится к релизу рипа, а не к фильму.
            let retry: TMDB.SearchPage<TMDB.MovieResult> = try await get("/search/movie", query: ["query": title])
            return retry.results
        }
        return page.results
    }

    func searchShows(_ title: String, year: Int?) async throws -> [TMDB.ShowResult] {
        var query = ["query": title]
        if let year { query["first_air_date_year"] = String(year) }
        let page: TMDB.SearchPage<TMDB.ShowResult> = try await get("/search/tv", query: query)
        if page.results.isEmpty, year != nil {
            let retry: TMDB.SearchPage<TMDB.ShowResult> = try await get("/search/tv", query: ["query": title])
            return retry.results
        }
        return page.results
    }

    /// Общий поиск по всему каталогу — то, что ищет строка в правом верхнем углу.
    func searchMulti(_ text: String, page: Int = 1) async throws -> [TMDB.MultiResult] {
        let response: TMDB.SearchPage<TMDB.MultiResult> =
            try await get("/search/multi", query: ["query": text, "page": String(page)])
        return response.results
    }

    func movieDetail(id: Int) async throws -> TMDB.MovieDetail {
        try await get("/movie/\(id)", query: ["append_to_response": "credits"])
    }

    func showDetail(id: Int) async throws -> TMDB.ShowDetail {
        try await get("/tv/\(id)", query: ["append_to_response": "credits"])
    }

    func season(showID: Int, season: Int) async throws -> TMDB.SeasonDetail {
        try await get("/tv/\(showID)/season/\(season)")
    }

    // MARK: - Актёры

    func personDetail(id: Int) async throws -> TMDB.PersonDetail {
        try await get("/person/\(id)")
    }

    /// Фильмография: и кино, и сериалы одним списком, как отдаёт TMDB.
    func personCredits(id: Int) async throws -> [TMDB.MultiResult] {
        let credits: TMDB.PersonCredits = try await get("/person/\(id)/combined_credits")
        return credits.cast
    }

    // MARK: - Подборки и рекомендации

    func trendingMovies(window: String = "week") async throws -> [TMDB.MovieResult] {
        let page: TMDB.SearchPage<TMDB.MovieResult> = try await get("/trending/movie/\(window)")
        return page.results
    }

    func trendingShows(window: String = "week") async throws -> [TMDB.ShowResult] {
        let page: TMDB.SearchPage<TMDB.ShowResult> = try await get("/trending/tv/\(window)")
        return page.results
    }

    func popularMovies() async throws -> [TMDB.MovieResult] {
        let page: TMDB.SearchPage<TMDB.MovieResult> = try await get("/movie/popular")
        return page.results
    }

    func topRatedMovies() async throws -> [TMDB.MovieResult] {
        let page: TMDB.SearchPage<TMDB.MovieResult> = try await get("/movie/top_rated")
        return page.results
    }

    /// «Похожее на то, что вы смотрели» — рекомендации TMDB по конкретному тайтлу.
    func recommendedMovies(for movieID: Int) async throws -> [TMDB.MovieResult] {
        let page: TMDB.SearchPage<TMDB.MovieResult> = try await get("/movie/\(movieID)/recommendations")
        return page.results
    }

    func recommendedShows(for showID: Int) async throws -> [TMDB.ShowResult] {
        let page: TMDB.SearchPage<TMDB.ShowResult> = try await get("/tv/\(showID)/recommendations")
        return page.results
    }

    /// Подбор по жанрам — основа рекомендаций по вкусам.
    func discoverMovies(genreIDs: [Int], minVotes: Int = 300) async throws -> [TMDB.MovieResult] {
        let page: TMDB.SearchPage<TMDB.MovieResult> = try await get("/discover/movie", query: [
            "with_genres": genreIDs.map(String.init).joined(separator: "|"),
            "sort_by": "vote_average.desc",
            "vote_count.gte": String(minVotes),
        ])
        return page.results
    }

    func discoverShows(genreIDs: [Int], minVotes: Int = 150) async throws -> [TMDB.ShowResult] {
        let page: TMDB.SearchPage<TMDB.ShowResult> = try await get("/discover/tv", query: [
            "with_genres": genreIDs.map(String.init).joined(separator: "|"),
            "sort_by": "vote_average.desc",
            "vote_count.gte": String(minVotes),
        ])
        return page.results
    }

    func movieGenres() async throws -> [TMDB.Genre] {
        struct Response: Decodable { var genres: [TMDB.Genre] }
        let response: Response = try await get("/genre/movie/list")
        return response.genres
    }

    func showGenres() async throws -> [TMDB.Genre] {
        struct Response: Decodable { var genres: [TMDB.Genre] }
        let response: Response = try await get("/genre/tv/list")
        return response.genres
    }

    // MARK: - Transport

    private func get<T: Decodable>(_ path: String, query: [String: String] = [:]) async throws -> T {
        guard let key, !key.isEmpty else { throw TMDBError.missingKey }

        var components = URLComponents(string: "https://api.themoviedb.org/3" + path)!
        var items = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        items.append(URLQueryItem(name: "language", value: language))
        // Длинный ключ — это v4-токен, он идёт заголовком, а не параметром.
        let isBearer = key.count > 60
        if !isBearer { items.append(URLQueryItem(name: "api_key", value: key)) }
        components.queryItems = items

        var request = URLRequest(url: components.url!)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if isBearer { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw TMDBError.http(-1) }
        switch http.statusCode {
        case 200...299: break
        case 401: throw TMDBError.unauthorized
        case 429:
            // Rate limit — одна аккуратная повторная попытка.
            try await Task.sleep(for: .seconds(2))
            return try await get(path, query: query)
        default: throw TMDBError.http(http.statusCode)
        }

        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw TMDBError.decoding(String(describing: error))
        }
    }
}
