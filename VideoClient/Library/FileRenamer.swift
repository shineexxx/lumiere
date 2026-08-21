import Foundation

/// Переименовывает файлы на диске по метаданным TMDB.
/// Работает только внутри той же папки — файлы никогда не перемещаются между каталогами.
@MainActor
struct FileRenamer {

    static let defaultsKey = "renameFilesOnMatch"

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: defaultsKey) as? Bool ?? true
    }

    struct Outcome {
        var renamed: Int = 0
        var skipped: Int = 0
        var failures: [String] = []
    }

    let access: FolderAccess
    let roots: [LibraryRoot]

    // MARK: - Имена

    /// Фильм: `Название (Год).ext`
    static func movieName(for entry: MediaEntry, extension ext: String) -> String {
        var name = sanitize(entry.displayTitle)
        if let year = entry.displayYear { name += " (\(year))" }
        return name + "." + ext
    }

    /// Серия: `Сериал (Год) - S04E07 - Название серии.ext`
    static func episodeName(for entry: MediaEntry, episode: EpisodeEntry, extension ext: String) -> String {
        var name = sanitize(entry.displayTitle)
        if let year = entry.displayYear { name += " (\(year))" }
        name += " - \(episode.code)"
        // Заглушку «Эпизод 7» в имя не тащим — она ничего не добавляет к коду серии.
        let title = sanitize(episode.title)
        if !title.isEmpty, title != String(localized: "Эпизод \(episode.episode)") {
            name += " - " + title
        }
        return name + "." + ext
    }

    /// Убирает символы, недопустимые в именах файлов macOS, и подрезает длину.
    nonisolated static func sanitize(_ raw: String) -> String {
        var text = raw
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: " -")
            .replacingOccurrences(of: "\n", with: " ")
        text = text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Точка в конце ломает отображение расширения в Finder.
        while text.hasSuffix(".") { text.removeLast() }
        // Запас под « - S04E07 - » и расширение.
        if text.count > 120 { text = String(text.prefix(120)).trimmingCharacters(in: .whitespaces) }
        return text
    }

    // MARK: - Применение

    /// Переименовывает все файлы карточки и возвращает обновлённую карточку.
    /// Идентификаторы файлов сохраняются, поэтому прогресс просмотра не теряется.
    func rename(entry: MediaEntry) -> (entry: MediaEntry, outcome: Outcome) {
        var updated = entry
        var outcome = Outcome()

        switch entry.kind {
        case .movie:
            guard var file = updated.movieFile else { return (updated, outcome) }
            let target = Self.movieName(for: updated, extension: file.fileExtension)
            apply(target: target, to: &file, outcome: &outcome)
            updated.movieFile = file

        case .show:
            for index in updated.episodes.indices {
                let episode = updated.episodes[index]
                // Серии без файла существуют только как метаданные — переименовывать нечего.
                guard var file = episode.file else { continue }
                let target = Self.episodeName(for: updated, episode: episode, extension: file.fileExtension)
                apply(target: target, to: &file, outcome: &outcome)
                updated.episodes[index].file = file
            }
        }
        return (updated, outcome)
    }

    private func apply(target: String, to file: inout VideoFileRef, outcome: inout Outcome) {
        guard target != file.fileName else { outcome.skipped += 1; return }
        guard let currentURL = access.fileURL(for: file, roots: roots) else {
            outcome.failures.append(String(localized: "\(file.fileName): нет доступа к папке"))
            return
        }
        guard FileManager.default.fileExists(atPath: currentURL.path) else {
            outcome.failures.append(String(localized: "\(file.fileName): файл не найден"))
            return
        }

        let directory = currentURL.deletingLastPathComponent()
        let finalName = uniqueName(target, in: directory, currentPath: currentURL.path)
        let destination = directory.appending(path: finalName)

        do {
            try FileManager.default.moveItem(at: currentURL, to: destination)
        } catch {
            outcome.failures.append("\(file.fileName): \(error.localizedDescription)")
            return
        }

        // Путь относительно корня меняется только в последнем компоненте.
        var components = file.relativePath.split(separator: "/").map(String.init)
        components.removeLast()
        components.append(finalName)
        file.relativePath = components.joined(separator: "/")
        file.fileName = finalName
        outcome.renamed += 1
    }

    /// Если такое имя уже занято другим файлом — добавляем счётчик.
    private func uniqueName(_ name: String, in directory: URL, currentPath: String) -> String {
        let fm = FileManager.default
        var candidate = name
        let stem = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var counter = 2
        while fm.fileExists(atPath: directory.appending(path: candidate).path),
              directory.appending(path: candidate).path != currentPath {
            candidate = "\(stem) (\(counter)).\(ext)"
            counter += 1
            if counter > 99 { return name }
        }
        return candidate
    }
}
