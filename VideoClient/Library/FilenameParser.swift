import Foundation

/// Разбор релизных имён файлов вида
/// `The.Big.Lebowski.1998.1080p.BluRay.x264-GROUP.mkv`
/// `Severance S02E07 2160p WEB-DL.mkv`
/// `Мандалорец.s01e03.WEB-DLRip.avi`
nonisolated enum FilenameParser {

    nonisolated struct Result {
        var title: String
        var year: Int?
        var season: Int?
        var episode: Int?
        var isEpisode: Bool { season != nil && episode != nil }
    }

    /// Мусор из релизных имён: качество, кодеки, источники, релиз-группы.
    private static let junkTokens: Set<String> = [
        "1080p", "720p", "480p", "2160p", "4k", "uhd", "hd", "sd", "hdr", "hdr10", "dv", "dolby", "vision",
        "bluray", "blu", "ray", "bdrip", "brrip", "brip", "dvdrip", "dvd", "webrip", "web", "dl", "webdl",
        "hdtv", "hdtvrip", "tvrip", "camrip", "ts", "tc", "remux", "repack", "proper", "internal", "limited",
        "x264", "x265", "h264", "h265", "hevc", "avc", "xvid", "divx", "av1", "10bit", "8bit",
        "aac", "ac3", "eac3", "dts", "hd", "ma", "truehd", "atmos", "flac", "mp3", "dd5", "dd", "5", "1",
        "dub", "dubbed", "sub", "subs", "subbed", "multi", "dual", "audio", "rus", "eng", "ukr", "vo", "mvo",
        "dvo", "avo", "lostfilm", "novafilm", "kubik", "hdrezka", "rezka", "kinozal", "rutracker",
        "extended", "unrated", "directors", "cut", "theatrical", "imax", "open", "matte",
        "amzn", "nf", "netflix", "hulu", "dsnp", "hmax", "atvp", "ddp5", "ddp",
        // Хвосты из заголовков роликов на VK Видео и Rutube
        "онлайн", "смотреть", "качестве", "хорошем", "бесплатно", "полностью",
        "версия", "полная", "дубляж", "озвучка", "трейлер", "фильм", "сериал",
        "hd", "fullhd", "4k", "1080", "720", "480", "8k",
    ]

    /// Слова-приставки в начале заголовка: «ФИЛЬМ Название», «Смотреть Название».
    private static let leadingJunk: Set<String> = [
        "фильм", "сериал", "смотреть", "кино", "мультфильм", "премьера", "новинка",
    ]

    private static let seasonEpisodePatterns: [String] = [
        #"[Ss](\d{1,2})[\s._-]*[EeЕе](\d{1,3})"#,        // S01E02, s1e2, s01 e02
        #"(\d{1,2})[xх](\d{1,3})"#,                        // 1x02
        // Число перед словом: «4 сезон 7 серия», «4-й сезон, 7-я серия»
        #"(\d{1,2})[\s._-]*(?:-?[а-яё]{1,2}[\s._-]*)?[Сс]езон\w*[\s._,-]*(\d{1,3})[\s._-]*(?:-?[а-яё]{1,2}[\s._-]*)?[Сс]ери\w*"#,
        #"(\d{1,2})[\s._-]*[Ss]eason\w*[\s._,-]*(\d{1,3})[\s._-]*[Ee]pisode\w*"#,
        // Слово перед числом: «Сезон 4 Серия 7»
        #"[Сс]езон[\s._-]*(\d{1,2}).*?[Сс]ери\w*[\s._-]*(\d{1,3})"#,
        #"[Ss]eason[\s._-]*(\d{1,2}).*?[Ee]pisode[\s._-]*(\d{1,3})"#,
    ]

    /// Номер серии без сезона — применяем только если сезон известен из папки.
    private static let episodeOnlyPatterns: [String] = [
        #"(\d{1,3})[\s._-]*(?:-?[а-яё]{1,2}[\s._-]*)?[Сс]ери\w*"#,   // «10 серия», «10-я серия»
        #"[Сс]ери\w*[\s._-]*(\d{1,3})"#,                             // «Серия 10»
        #"[Ээ]пизод[\s._-]*(\d{1,3})"#,
        #"[Ee]pisode[\s._-]*(\d{1,3})"#,
        #"^[EeЕе](\d{1,3})$"#,                                        // «E10»
    ]

    /// Достаёт номер сезона из имени папки: «4 сезон», «Season 2», «S03».
    private static func seasonNumber(in folder: String) -> Int? {
        let patterns = [
            #"^\d{1,2}"#,
            #"[Сс]езон[\s._-]*(\d{1,2})"#,
            #"[Ss]eason[\s._-]*(\d{1,2})"#,
            #"^[Ss](\d{1,2})$"#,
        ]
        // Папка вообще должна выглядеть как сезонная, иначе «2 Fast 2 Furious» даст ложный сезон.
        let looksLikeSeason = folder.range(of: #"[Сс]езон|[Ss]eason|^[Ss]\d{1,2}$"#,
                                           options: .regularExpression) != nil
        guard looksLikeSeason else { return nil }
        for pattern in patterns {
            guard let range = folder.range(of: pattern, options: .regularExpression) else { continue }
            let digits = folder[range].filter(\.isNumber)
            if let value = Int(digits) { return value }
        }
        return nil
    }

    static func parse(fileName: String, parentFolders: [String] = []) -> Result {
        let stem = (fileName as NSString).deletingPathExtension
        var working = stem

        var season: Int?
        var episode: Int?

        for pattern in seasonEpisodePatterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(working.startIndex..<working.endIndex, in: working)
            guard let match = regex.firstMatch(in: working, range: range),
                  match.numberOfRanges >= 3,
                  let seasonRange = Range(match.range(at: 1), in: working),
                  let episodeRange = Range(match.range(at: 2), in: working) else { continue }
            season = Int(working[seasonRange])
            episode = Int(working[episodeRange])
            // Всё, что после маркера серии — почти всегда технический мусор.
            if let full = Range(match.range, in: working) {
                working = String(working[working.startIndex..<full.lowerBound])
            }
            break
        }

        // В имени только номер серии («10 серия», «Эпизод 3») — сезон берём из папки.
        if season == nil, episode == nil {
            for pattern in episodeOnlyPatterns {
                guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
                let range = NSRange(working.startIndex..<working.endIndex, in: working)
                guard let match = regex.firstMatch(in: working, range: range),
                      match.numberOfRanges >= 2,
                      let episodeRange = Range(match.range(at: 1), in: working),
                      let number = Int(working[episodeRange]) else { continue }
                guard let folderSeason = parentFolders.reversed().compactMap(seasonNumber(in:)).first else { break }
                episode = number
                season = folderSeason
                if let full = Range(match.range, in: working) {
                    working = String(working[working.startIndex..<full.lowerBound])
                }
                break
            }
        }

        // Год в скобках или отдельным токеном. Берём последний правдоподобный.
        var year: Int?
        if let regex = try? NSRegularExpression(pattern: #"(?:^|[^\d])((?:19|20)\d{2})(?:[^\d]|$)"#) {
            let range = NSRange(working.startIndex..<working.endIndex, in: working)
            let matches = regex.matches(in: working, range: range)
            if let last = matches.last, let yearRange = Range(last.range(at: 1), in: working) {
                let value = Int(working[yearRange])
                let currentYear = Calendar.current.component(.year, from: Date())
                if let value, value >= 1900, value <= currentYear + 2 {
                    year = value
                    if let full = Range(last.range, in: working) {
                        working = String(working[working.startIndex..<full.lowerBound])
                    }
                }
            }
        }

        var title = cleanTitle(working)

        // Для эпизодов имя файла часто состоит только из S01E02 — тогда название берём из папки.
        if title.isEmpty || (season != nil && title.count < 2) {
            for folder in parentFolders.reversed() {
                let candidate = cleanTitle(stripSeasonFolder(folder))
                if candidate.count >= 2 {
                    title = candidate
                    if year == nil { year = yearIn(folder) }
                    break
                }
            }
        }

        return Result(title: title.isEmpty ? stem : title, year: year, season: season, episode: episode)
    }

    /// «Season 2», «Сезон 2», «2 сезон», «S02» — это не название сериала.
    private static func stripSeasonFolder(_ folder: String) -> String {
        let patterns = [
            #"^[Ss]eason[\s._-]*\d{1,2}$"#,
            #"^[Сс]езон[\s._-]*\d{1,2}$"#,
            // Число перед словом: «4 сезон», «4-й сезон», «2 season»
            #"^\d{1,2}[\s._-]*(?:-?[а-яё]{1,2}[\s._-]*)?[Сс]езон\w*$"#,
            #"^\d{1,2}[\s._-]*[Ss]eason\w*$"#,
            #"^[Ss]\d{1,2}$"#,
        ]
        for pattern in patterns where folder.range(of: pattern, options: .regularExpression) != nil {
            return ""
        }
        return folder
    }

    private static func yearIn(_ text: String) -> Int? {
        guard let range = text.range(of: #"(?:19|20)\d{2}"#, options: .regularExpression) else { return nil }
        return Int(text[range])
    }

    /// Слово без прилипшей пунктуации: «фильм,» и «фильм» — одно и то же.
    private static func normalizedToken(_ token: String) -> String {
        token.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ",.;:!?«»\"'“”"))
    }

    private static func isJunk(_ token: String) -> Bool {
        junkTokens.contains(normalizedToken(token))
    }

    private static func cleanTitle(_ raw: String) -> String {
        var text = raw
        // Скобки с техническим содержимым обычно бесполезны.
        text = text.replacingOccurrences(of: #"[\[\(\{][^\]\)\}]*[\]\)\}]"#, with: " ", options: .regularExpression)
        // Скобка могла остаться без пары: в «Скрытые фигуры (фильм, 2016)» год
        // отрезается вместе с хвостом, и от группы остаётся «(фильм,».
        // Без этого «фильм» прилипал к скобке и не опознавался как мусор.
        text = text.replacingOccurrences(of: #"[\[\(\{\]\)\}]"#, with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: #"[._]"#, with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\s*-\s*"#, with: " ", options: .regularExpression)

        var tokens = text.split(whereSeparator: { $0 == " " }).map(String.init)
        // Мусор режем с конца: внутри названия «Dune» и «Dual» встречаются законно,
        // но техтеги всегда идут хвостом.
        while let last = tokens.last, isJunk(last) {
            tokens.removeLast()
        }
        // Хвостовая релиз-группа в верхнем регистре: «...-GROUP».
        if let last = tokens.last, last.count >= 2, last == last.uppercased(),
           last.rangeOfCharacter(from: .decimalDigits) == nil, tokens.count > 1 {
            tokens.removeLast()
        }

        // Приставки режем с начала: «ФИЛЬМ Побег из Шоушенка» → «Побег из Шоушенка».
        while let first = tokens.first, leadingJunk.contains(normalizedToken(first)), tokens.count > 1 {
            tokens.removeFirst()
        }

        var result = tokens.joined(separator: " ")
        // Разделители по краям остаются от заголовков вида «Название | 2023 | 4K».
        let separators = CharacterSet(charactersIn: "|/\\—–-·•,;: \t")
        result = result.trimmingCharacters(in: separators)
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
