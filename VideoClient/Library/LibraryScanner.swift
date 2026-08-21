import Foundation

/// Обходит корневые папки, находит видеофайлы и группирует их в карточки.
nonisolated enum LibraryScanner {

    static let videoExtensions: Set<String> = [
        "mp4", "m4v", "mov", "mkv", "avi", "wmv", "flv", "webm", "mpg", "mpeg", "m2ts", "ts", "vob", "ogv", "3gp",
    ]

    /// Порог по умолчанию: отсекает сэмплы и трейлеры. Меняется в настройках.
    static let defaultMinimumFileSize: Int64 = 50 * 1024 * 1024

    static var minimumFileSize: Int64 {
        let stored = UserDefaults.standard.object(forKey: "minimumFileSizeMB") as? Int
        return Int64(stored ?? 50) * 1024 * 1024
    }

    /// Имена, которые почти всегда означают не сам фильм.
    static let skipNamePatterns: [String] = ["sample", "trailer", "трейлер", "тизер", "teaser"]

    static var skipSamples: Bool {
        UserDefaults.standard.object(forKey: "skipSampleFiles") as? Bool ?? true
    }

    nonisolated struct FoundFile {
        var file: VideoFileRef
        var parsed: FilenameParser.Result
    }

    /// Рекурсивный обход одной корневой папки на любую глубину вложенности.
    /// Тяжёлая часть — вынесена с главного потока.
    nonisolated static func scan(rootURL: URL, rootID: UUID) -> [FoundFile] {
        let fm = FileManager.default
        let minimumSize = minimumFileSize
        let skipSamples = self.skipSamples
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey, .isHiddenKey]
        // Без .skipsSubdirectoryDescendants — обход идёт вглубь по всему дереву.
        guard let enumerator = fm.enumerator(at: rootURL,
                                             includingPropertiesForKeys: keys,
                                             options: [.skipsHiddenFiles, .skipsPackageDescendants]) else {
            return []
        }

        var found: [FoundFile] = []
        let rootComponents = rootURL.standardizedFileURL.pathComponents

        for case let url as URL in enumerator {
            guard videoExtensions.contains(url.pathExtension.lowercased()) else { continue }
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true else { continue }
            let size = Int64(values.fileSize ?? 0)
            guard size >= minimumSize else { continue }

            if skipSamples {
                let lowercased = url.lastPathComponent.lowercased()
                guard !skipNamePatterns.contains(where: { lowercased.contains($0) }) else { continue }
            }

            let components = url.standardizedFileURL.pathComponents
            guard components.count > rootComponents.count else { continue }
            let relative = components[rootComponents.count...].joined(separator: "/")
            let parentFolders = Array(components[rootComponents.count..<(components.count - 1)])

            let ref = VideoFileRef(rootID: rootID,
                                   relativePath: relative,
                                   fileName: url.lastPathComponent,
                                   fileSize: size,
                                   modifiedAt: values.contentModificationDate ?? Date())
            let parsed = FilenameParser.parse(fileName: url.lastPathComponent, parentFolders: parentFolders)
            found.append(FoundFile(file: ref, parsed: parsed))
        }
        return found
    }

    /// Группирует найденные файлы: эпизоды одного сериала — в одну карточку, остальное — фильмы.
    static func group(_ files: [FoundFile]) -> [MediaEntry] {
        var shows: [String: MediaEntry] = [:]
        var movies: [MediaEntry] = []

        for item in files {
            let parsed = item.parsed
            if parsed.isEpisode, let season = parsed.season, let episode = parsed.episode {
                let key = normalizedKey(parsed.title)
                var entry = shows[key] ?? MediaEntry(kind: .show,
                                                     parsedTitle: parsed.title,
                                                     parsedYear: parsed.year)
                // Один и тот же эпизод в разных качествах — берём файл покрупнее.
                let sameEpisode: (EpisodeEntry) -> Bool = { candidate in
                    candidate.season == season && candidate.episode == episode
                }
                if let existing = entry.episodes.firstIndex(where: sameEpisode) {
                    let currentSize = entry.episodes[existing].file?.fileSize ?? 0
                    if item.file.fileSize > currentSize {
                        entry.episodes[existing].file = item.file
                    }
                } else {
                    entry.episodes.append(EpisodeEntry(season: season,
                                                       episode: episode,
                                                       title: String(localized: "Эпизод \(episode)"),
                                                       file: item.file))
                }
                if entry.parsedYear == nil { entry.parsedYear = parsed.year }
                shows[key] = entry
            } else {
                movies.append(MediaEntry(kind: .movie,
                                         parsedTitle: parsed.title,
                                         parsedYear: parsed.year,
                                         movieFile: item.file))
            }
        }

        return movies + Array(shows.values)
    }

    static func normalizedKey(_ title: String) -> String {
        title.lowercased()
            .folding(options: [.diacriticInsensitive], locale: nil)
            .replacingOccurrences(of: #"[^\p{L}\p{N}]"#, with: "", options: .regularExpression)
    }
}
