import Foundation
import Observation

/// Загружает видео по ссылке через yt-dlp: одиночные ролики и целые плейлисты.
@Observable
@MainActor
final class DownloadManager {

    // MARK: - Модель задания

    enum Status: Equatable {
        case waiting
        case probing
        case running
        case finished
        case failed(String)
        case cancelled

        var isActive: Bool {
            switch self {
            case .waiting, .probing, .running: true
            default: false
            }
        }
    }

    struct Job: Identifiable {
        let id = UUID()
        var url: String
        var source: VideoSource
        /// Как назвать результат: фильм или сезон сериала.
        var naming: Naming
        var destination: URL
        var title: String
        var videoURLs: [String] = []
        var status: Status = .waiting
        /// Прогресс текущего файла, 0…1.
        var progress: Double = 0
        var speed: String?
        var eta: String?
        /// Для плейлистов: какой по счёту элемент качается.
        var itemIndex: Int?
        var itemCount: Int?
        var downloadedFiles: [String] = []
        var startedAt = Date()

        var isPlaylist: Bool {
            if case .series = naming { return true }
            return !videoURLs.isEmpty || (itemCount.map { $0 > 1 } ?? false)
        }

        var subtitle: String {
            switch status {
            case .waiting: return String(localized: "В очереди")
            case .probing: return String(localized: "Читаю ссылку…")
            case .running:
                var parts: [String] = []
                if let itemIndex, let itemCount { parts.append("\(itemIndex) из \(itemCount)") }
                if let speed { parts.append(speed) }
                if let eta { parts.append(String(localized: "осталось \(eta)")) }
                return parts.isEmpty ? String(localized: "Загрузка…") : parts.joined(separator: " · ")
            case .finished:
                return downloadedFiles.isEmpty
                    ? "Готово"
                    : String(localized: "Готово · \(Plural.files(downloadedFiles.count))")
            case .failed(let message): return message
            case .cancelled: return String(localized: "Отменено")
            }
        }
    }

    /// Как формировать имена файлов.
    enum Naming: Equatable {
        case movie
        case series(show: String, season: Int, startEpisode: Int)
    }

    private(set) var jobs: [Job] = []
    /// Вызывается после успешной загрузки — библиотека пересканирует папку.
    @ObservationIgnored var onFinished: (() -> Void)?

    private var processes: [UUID: Process] = [:]

    var hasActiveJobs: Bool { jobs.contains { $0.status.isActive } }

    /// Имя папки сезона на диске. Оно же показывается в подсказке под формой,
    /// поэтому берётся из одного места: подсказка и то, что окажется в Finder,
    /// должны совпадать.
    nonisolated static func seasonFolder(_ season: Int) -> String {
        String(localized: "Сезон \(season)")
    }

    nonisolated static func seriesFolder(_ show: String) -> String {
        let name = FileRenamer.sanitize(show)
        return name.isEmpty ? String(localized: "Без названия") : name
    }

    // MARK: - Разбор ссылки

    struct Probe {
        var title: String
        var itemCount: Int
        var isPlaylist: Bool
        var entries: [String]
        var videoURLs: [String] = []
        var season: Int?
    }

    /// Спрашивает у yt-dlp, что находится по ссылке, не начиная загрузку.
    /// Нужно, чтобы показать название и понять, плейлист это или одно видео.
    nonisolated static func probe(url: String) async throws -> Probe {
        guard let tool = ExternalTools.ytDLP else { throw DownloadError.toolMissing }

        if let playlist = VKPlaylist(url) {
            return try await playlist.probe()
        }

        let output = try await runCapturing(tool: tool, arguments: [
            "--dump-single-json",
            "--flat-playlist",
            "--no-warnings",
            url,
        ])

        guard let data = output.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DownloadError.probeFailed(String(localized: "Не удалось прочитать ответ yt-dlp"))
        }

        let title = (json["title"] as? String) ?? String(localized: "Без названия")
        let entries = (json["entries"] as? [[String: Any]]) ?? []
        let isPlaylist = (json["_type"] as? String) == "playlist" || !entries.isEmpty
        return Probe(title: title,
                     itemCount: isPlaylist ? max(entries.count, 1) : 1,
                     isPlaylist: isPlaylist,
                     entries: entries.compactMap { $0["title"] as? String })
    }

    // MARK: - Постановка в очередь

    func enqueue(url: String, naming: Naming, destination: URL, probe: Probe) {
        var job = Job(url: url,
                      source: VideoSource.detect(url) ?? .other,
                      naming: naming,
                      destination: destination,
                      title: probe.title,
                      videoURLs: probe.videoURLs)
        job.itemCount = probe.itemCount
        jobs.insert(job, at: 0)
        Task { await run(job.id) }
    }

    func cancel(_ id: UUID) {
        if let process = processes[id], process.isRunning { process.terminate() }
        processes[id] = nil
        update(id) { $0.status = .cancelled }
    }

    func clearFinished() {
        jobs.removeAll { !$0.status.isActive }
    }

    // MARK: - Выполнение

    private func run(_ id: UUID) async {
        guard let job = jobs.first(where: { $0.id == id }), job.status == .waiting else { return }
        guard let tool = ExternalTools.ytDLP else {
            update(id) { $0.status = .failed(String(localized: "yt-dlp не найден — установите его через Homebrew")) }
            return
        }

        update(id) { $0.status = .running }

        let process = Process()
        process.executableURL = tool
        process.arguments = Self.arguments(for: job)
        process.currentDirectoryURL = job.destination

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        processes[id] = process

        // Вывод читаем событиями, а не блокирующим циклом: раньше цикл крутился
        // на главном потоке и подвешивал весь интерфейс до конца загрузки.
        let lines: AsyncStream<String>
        do {
            lines = try Self.start(process: process, pipe: pipe)
        } catch {
            processes[id] = nil
            update(id) { $0.status = .failed(error.localizedDescription) }
            return
        }
        var errorMessage: String?
        for await line in lines {
            errorMessage = Self.errorMessage(in: line) ?? errorMessage
            apply(line: line, to: id, resolvedPlaylist: !job.videoURLs.isEmpty)
        }
        let status = process.terminationStatus

        processes[id] = nil

        update(id) { job in
            guard job.status != .cancelled else { return }
            if status == 0 {
                job.status = .finished
                job.progress = 1
            } else {
                job.status = .failed(errorMessage ?? String(localized: "yt-dlp завершился с кодом \(status)"))
            }
        }

        if status == 0 || jobs.contains(where: { $0.id == id && !$0.downloadedFiles.isEmpty }) { onFinished?() }
    }

    /// Запускает процесс и отдаёт его вывод построчно, не блокируя вызывающий поток.
    private static func start(process: Process, pipe: Pipe) throws -> AsyncStream<String> {
        try process.run()
        let (lines, output) = AsyncStream.makeStream(of: String.self)
        DispatchQueue.global(qos: .utility).async {
            let handle = pipe.fileHandleForReading
            var buffer = LineBuffer()
            while let data = try? handle.read(upToCount: 16_384), !data.isEmpty {
                for line in buffer.append(data) { output.yield(line) }
            }
            if let last = buffer.flush() { output.yield(last) }

            process.waitUntilExit()
            output.finish()
        }
        return lines
    }

    /// Аргументы yt-dlp. Шаблон имени задаём сами, чтобы файлы сразу ложились
    /// в том виде, который понимает сканер библиотеки.
    nonisolated static func arguments(for job: Job) -> [String] {
        var args = [
            "--newline",            // прогресс отдельными строками, а не перезаписью
            "--no-warnings",
            "--no-mtime",           // дата файла — момент загрузки, а не публикации
            // --restrict-filenames намеренно не используем: он транслитерирует
            // кириллицу, и поиск в TMDB по такому названию уже ничего не находит.
            "-f", "bestvideo*+bestaudio/best",
        ]

        if let ffmpeg = ExternalTools.ffmpeg {
            args += ["--ffmpeg-location", ffmpeg.path, "--merge-output-format", "mp4"]
        }

        let resolvedPlaylist = !job.videoURLs.isEmpty
        if resolvedPlaylist {
            // Порядок ссылок задаёт номера серий. При ошибке оставляем следующие
            // серии в очереди yt-dlp незагруженными, чтобы их номера не сдвинулись.
            args += ["--no-playlist", "--abort-on-error", "--no-simulate", "--progress",
                     "--print", "before_dl:LUMIERE_VIDEO_START:%(id)s",
                     "--print", "after_move:LUMIERE_VIDEO_FILE:%(filepath)s"]
        }

        switch job.naming {
        case .movie:
            if !resolvedPlaylist { args.append("--no-playlist") }
            let template = resolvedPlaylist ? "%(title)s [%(id)s].%(ext)s" : "%(title)s.%(ext)s"
            args += ["-o", template]

        case .series(let show, let season, let startEpisode):
            // autonumber даёт сквозную нумерацию серий с нужного места.
            let safeShow = Self.seriesFolder(show).replacingOccurrences(of: "%", with: "%%")
            let seasonCode = String(format: "%02d", season)
            // Раскладываем по папкам «Сериал / Сезон N»: так содержимое понятно
            // и в Finder, без нашего приложения. yt-dlp создаёт папки сам.
            if !resolvedPlaylist { args.append("--yes-playlist") }
            args += [
                "--autonumber-start", String(startEpisode),
                "-o", "\(safeShow)/\(Self.seasonFolder(season))/\(safeShow) - S\(seasonCode)E%(autonumber)02d.%(ext)s",
            ]
        }

        args += resolvedPlaylist ? job.videoURLs : [job.url]
        return args
    }

    // MARK: - Разбор вывода

    private func apply(line: String, to id: UUID, resolvedPlaylist: Bool) {
        if resolvedPlaylist, line.hasPrefix("LUMIERE_VIDEO_START:") {
            update(id) {
                $0.itemIndex = ($0.itemIndex ?? 0) + 1
                $0.progress = 0
                $0.speed = nil
                $0.eta = nil
            }
        }
        // [download]  42.7% of  1.31GiB at  8.42MiB/s ETA 01:12
        if let percent = Self.match(line, #"\[download\]\s+([\d.]+)%"#).flatMap(Double.init) {
            update(id) { $0.progress = percent / 100 }
        }
        if let speed = Self.match(line, #"at\s+([\d.]+\s*[KMG]iB/s)"#) {
            update(id) { $0.speed = speed.replacingOccurrences(of: "iB/s", with: String(localized: "Б/с")) }
        }
        if let eta = Self.match(line, #"ETA\s+([\d:]+)"#) {
            update(id) { $0.eta = eta }
        }
        // [download] Downloading item 3 of 12
        if let index = Self.match(line, #"Downloading item (\d+) of"#).flatMap(Int.init),
           let total = Self.match(line, #"Downloading item \d+ of (\d+)"#).flatMap(Int.init) {
            update(id) {
                $0.itemIndex = index
                $0.itemCount = total
                $0.progress = 0
            }
        }
        // [download] Destination: Severance - S02E01.mp4  /  [Merger] Merging formats into "..."
        let name = resolvedPlaylist
            ? Self.match(line, #"^LUMIERE_VIDEO_FILE:(.+)$"#)
            : Self.match(line, #"\[download\] Destination:\s+(.+)$"#)
                ?? Self.match(line, #"Merging formats into "(.+)""#)
        if let name {
            let file = (name as NSString).lastPathComponent
            update(id) { job in
                if !job.downloadedFiles.contains(file) { job.downloadedFiles.append(file) }
            }
        }
    }

    private nonisolated static func errorMessage(in line: String) -> String? {
        guard line.contains("ERROR:") else { return nil }
        return line
            .replacingOccurrences(of: "ERROR:", with: "")
            .trimmingCharacters(in: .whitespaces)
    }

    private nonisolated static func match(_ text: String, _ pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range]).trimmingCharacters(in: .whitespaces)
    }

    private func update(_ id: UUID, _ mutate: (inout Job) -> Void) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        mutate(&jobs[index])
    }

    // MARK: - Вспомогательное

    /// Разовый запуск утилиты со сбором вывода — для чтения метаданных.
    ///
    /// Оба канала читаем событиями и одновременно. Последовательное чтение
    /// до конца сначала одного, потом другого приводило к взаимной блокировке:
    /// процесс останавливался, заполнив буфер второго канала, а мы ждали EOF первого.
    /// Плюс жёсткий таймаут — yt-dlp может зависнуть на недоступном сайте.
    private nonisolated static func runCapturing(tool: URL,
                                                 arguments: [String],
                                                 timeout: Duration = .seconds(90)) async throws -> String {
        let process = Process()
        process.executableURL = tool
        process.arguments = arguments

        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors

        let outputBox = DataBox()
        let errorBox = DataBox()
        output.fileHandleForReading.readabilityHandler = { outputBox.append($0.availableData) }
        errors.fileHandleForReading.readabilityHandler = { errorBox.append($0.availableData) }

        // Сторож: если утилита не ответила за отведённое время, снимаем её.
        let watchdog = Task {
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled, process.isRunning else { return }
            process.terminate()
        }
        defer { watchdog.cancel() }

        let status: Int32 = await withCheckedContinuation { continuation in
            let finished = OnceFlag()
            process.terminationHandler = { process in
                output.fileHandleForReading.readabilityHandler = nil
                errors.fileHandleForReading.readabilityHandler = nil
                if let tail = try? output.fileHandleForReading.readToEnd() { outputBox.append(tail) }
                if let tail = try? errors.fileHandleForReading.readToEnd() { errorBox.append(tail) }
                guard finished.claim() else { return }
                continuation.resume(returning: process.terminationStatus)
            }
            do {
                try process.run()
            } catch {
                guard finished.claim() else { return }
                continuation.resume(returning: -1)
            }
        }

        guard status == 0 else {
            if watchdog.isCancelled == false, process.terminationReason == .uncaughtSignal {
                throw DownloadError.probeFailed(String(localized: "превышено время ожидания — сайт не ответил"))
            }
            let message = errorBox.text
                .split(separator: "\n").last.map(String.init) ?? String(localized: "неизвестная ошибка")
            throw DownloadError.probeFailed(message)
        }
        return outputBox.text
    }
}

enum DownloadError: LocalizedError {
    case toolMissing
    case probeFailed(String)

    var errorDescription: String? {
        switch self {
        case .toolMissing:
            String(localized: "yt-dlp не найден. Установите его: brew install yt-dlp")
        case .probeFailed(let detail):
            String(localized: "Не удалось разобрать ссылку: \(detail)")
        }
    }
}
