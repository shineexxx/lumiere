import Foundation
import Observation
import OSLog

nonisolated let log = Logger(subsystem: "com.arseny.Lumiere", category: "app")

/// Снимок библиотеки, который пишется на диск.
nonisolated struct LibrarySnapshot: Codable {
    /// 1 — прогресс хранился по идентификатору файла;
    /// 2 — по идентификатору карточки/серии, чтобы переживать удаление файла.
    static let currentVersion = 2

    var version: Int = LibrarySnapshot.currentVersion
    var roots: [LibraryRoot] = []
    var entries: [MediaEntry] = []
    var watch: [UUID: WatchState] = [:]
}

@Observable
final class LibraryStore {

    private(set) var roots: [LibraryRoot] = []
    private(set) var entries: [MediaEntry] = []
    private(set) var watch: [UUID: WatchState] = [:]

    /// Показываем в UI, пока идёт сканирование/загрузка метаданных.
    var statusMessage: String?
    var isBusy: Bool = false

    /// Вызывается при изменении истории просмотров — на это подписана синхронизация.
    @ObservationIgnored var onWatchChanged: (() -> Void)?

    private let fileURL: URL
    private var saveTask: Task<Void, Never>?

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? Self.defaultURL()
        load()
    }

    nonisolated static func defaultURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Lumiere", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("library.json")
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        do {
            let snapshot = try JSONDecoder.videoClient.decode(LibrarySnapshot.self, from: data)
            roots = snapshot.roots
            entries = snapshot.entries
            watch = snapshot.version < 2
                ? Self.migrateWatchToStableKeys(snapshot.watch, entries: snapshot.entries)
                : snapshot.watch
            if snapshot.version < LibrarySnapshot.currentVersion { scheduleSave() }
            // Библиотеки, где дубли серий успели накопиться, чиним при открытии.
            collapseDuplicateEpisodes()
        } catch {
            log.error("Не удалось прочитать библиотеку: \(error.localizedDescription)")
        }
    }

    /// Переносит прогресс со старых ключей (идентификатор файла) на новые
    /// (идентификатор карточки или серии). Нужно один раз при обновлении формата.
    private nonisolated static func migrateWatchToStableKeys(_ old: [UUID: WatchState],
                                                             entries: [MediaEntry]) -> [UUID: WatchState] {
        var migrated: [UUID: WatchState] = [:]
        for entry in entries {
            if let file = entry.movieFile, let state = old[file.id] {
                migrated[entry.watchKey] = state
            }
            for episode in entry.episodes {
                if let file = episode.file, let state = old[file.id] {
                    migrated[episode.id] = state
                }
            }
        }
        log.info("Прогресс перенесён на стабильные ключи: \(migrated.count) записей")
        return migrated
    }

    /// Сохранение с дебаунсом — прогресс просмотра пишется часто.
    func scheduleSave() {
        saveTask?.cancel()
        let snapshot = LibrarySnapshot(roots: roots, entries: entries, watch: watch)
        let url = fileURL
        saveTask = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            await Self.write(snapshot, to: url)
        }
    }

    func saveNow() {
        saveTask?.cancel()
        let snapshot = LibrarySnapshot(roots: roots, entries: entries, watch: watch)
        let url = fileURL
        Task.detached(priority: .userInitiated) {
            await Self.write(snapshot, to: url)
        }
    }

    private nonisolated static func write(_ snapshot: LibrarySnapshot, to url: URL) async {
        do {
            let data = try JSONEncoder.videoClient.encode(snapshot)
            let tmp = url.appendingPathExtension("tmp")
            try data.write(to: tmp, options: .atomic)
            _ = try? FileManager.default.replaceItemAt(url, withItemAt: tmp)
        } catch {
            log.error("Не удалось сохранить библиотеку: \(error.localizedDescription)")
        }
    }

    // MARK: - Roots

    func addRoot(_ root: LibraryRoot) {
        guard !roots.contains(where: { $0.displayPath == root.displayPath }) else { return }
        roots.append(root)
        scheduleSave()
    }

    func removeRoot(_ root: LibraryRoot) {
        roots.removeAll { $0.id == root.id }
        let removed = entries.filter { $0.allFiles.contains { $0.rootID == root.id } }
        for entry in removed { watch.removeValue(forKey: entry.id) }
        entries.removeAll { entry in entry.allFiles.allSatisfy { $0.rootID == root.id } }
        scheduleSave()
    }

    func root(id: UUID) -> LibraryRoot? { roots.first { $0.id == id } }

    // MARK: - Entries

    func entry(id: UUID) -> MediaEntry? { entries.first { $0.id == id } }

    func upsert(_ entry: MediaEntry) {
        if let index = entries.firstIndex(where: { $0.id == entry.id }) {
            entries[index] = entry
        } else {
            entries.append(entry)
        }
        scheduleSave()
    }

    /// Схлопывает серии с одинаковыми номером сезона и серии в одну.
    ///
    /// Такие дубли появлялись, когда файл серии приезжал в библиотеку уже после
    /// того, как карточка обзавелась списком серий с TMDB: скачанный файл
    /// добавлялся отдельной строкой «Эпизод 9» рядом с настоящей девятой серией.
    /// За основу берём запись с файлом, недостающее забираем у второй, а отметку
    /// о просмотре переносим на выжившую — иначе история просмотра потерялась бы.
    @discardableResult
    func collapseDuplicateEpisodes() -> Int {
        var collapsed = 0
        for index in entries.indices where entries[index].kind == .show {
            var byNumber: [String: EpisodeEntry] = [:]
            var order: [String] = []
            var collapsedHere = 0
            for episode in entries[index].episodes {
                let key = "\(episode.season)|\(episode.episode)"
                guard var kept = byNumber[key] else {
                    byNumber[key] = episode
                    order.append(key)
                    continue
                }
                collapsed += 1
                collapsedHere += 1
                // Побеждает запись с файлом: именно её id уже мог получить прогресс
                // при воспроизведении.
                if kept.file == nil, episode.file != nil {
                    var winner = episode
                    winner.absorb(kept)
                    transferWatch(from: kept.id, to: winner.id)
                    kept = winner
                } else {
                    kept.absorb(episode)
                    transferWatch(from: episode.id, to: kept.id)
                }
                byNumber[key] = kept
            }
            guard collapsedHere > 0 else { continue }
            entries[index].episodes = order.compactMap { byNumber[$0] }
                .sorted { ($0.season, $0.episode) < ($1.season, $1.episode) }
        }
        if collapsed > 0 {
            log.info("Схлопнуто дублей серий: \(collapsed)")
            scheduleSave()
        }
        return collapsed
    }

    /// Переносит отметку о просмотре с исчезающей серии на остающуюся.
    /// Если отметки есть у обеих — оставляем более продвинутую.
    private func transferWatch(from old: UUID, to new: UUID) {
        guard old != new, let state = watch.removeValue(forKey: old) else { return }
        guard let existing = watch[new] else {
            watch[new] = state
            return
        }
        var merged = existing.lastPlayedAt >= state.lastPlayedAt ? existing : state
        merged.isFinished = existing.isFinished || state.isFinished
        merged.playCount = max(existing.playCount, state.playCount)
        watch[new] = merged
    }

    func update(id: UUID, _ mutate: (inout MediaEntry) -> Void) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        mutate(&entries[index])
        scheduleSave()
    }

    /// Полностью заменяет набор карточек. Прогресс просмотра не трогаем —
    /// он привязан к идентификаторам файлов, которые при пересборке сохраняются.
    func replaceEntries(_ newEntries: [MediaEntry]) {
        entries = newEntries
        scheduleSave()
    }

    func delete(id: UUID) {
        entries.removeAll { $0.id == id }
        watch.removeValue(forKey: id)
        scheduleSave()
    }

    /// Уже известные файлы — чтобы повторное сканирование не плодило дубликаты.
    var knownFileKeys: Set<String> {
        var keys = Set<String>()
        for entry in entries {
            for file in entry.allFiles { keys.insert("\(file.rootID.uuidString)|\(file.relativePath)") }
        }
        return keys
    }

    // MARK: - Watch tracking

    // Ключ прогресса — идентификатор карточки (для фильма) или серии.
    // К файлу он не привязан: удалили файл — отметка о просмотре осталась.

    func watchState(for key: UUID) -> WatchState? { watch[key] }

    func recordProgress(key: UUID, position: Double, duration: Double) {
        var state = watch[key] ?? WatchState()
        state.position = position
        state.duration = duration
        state.lastPlayedAt = Date()
        if duration > 0, position / duration >= WatchRules.finishedThreshold, !state.isFinished {
            state.isFinished = true
            state.playCount += 1
        }
        watch[key] = state
        scheduleSave()
        onWatchChanged?()
    }

    func setFinished(key: UUID, _ finished: Bool) {
        var state = watch[key] ?? WatchState()
        state.isFinished = finished
        state.lastPlayedAt = Date()
        if finished {
            state.playCount = max(1, state.playCount)
            if state.duration > 0 { state.position = state.duration }
        } else {
            state.position = 0
        }
        watch[key] = state
        scheduleSave()
        onWatchChanged?()
    }

    func resetProgress(key: UUID) {
        watch.removeValue(forKey: key)
        scheduleSave()
        onWatchChanged?()
    }

    /// Позиция, с которой стоит продолжить (nil — начинать сначала).
    func resumePosition(for key: UUID) -> Double? {
        guard let state = watch[key], state.hasResumablePosition else { return nil }
        return max(0, state.position - WatchRules.resumeRewind)
    }

    // MARK: - Derived collections

    func isFinished(_ entry: MediaEntry) -> Bool {
        let keys = entry.watchKeys
        guard !keys.isEmpty else { return false }
        return keys.allSatisfy { watch[$0]?.isFinished == true }
    }

    func progressFraction(_ entry: MediaEntry) -> Double {
        let keys = entry.watchKeys
        guard !keys.isEmpty else { return 0 }
        switch entry.kind {
        case .movie:
            return watch[keys[0]]?.fraction ?? 0
        case .show:
            let watched = keys.filter { watch[$0]?.isFinished == true }.count
            return Double(watched) / Double(keys.count)
        }
    }

    /// Сливает историю просмотров с чужой копией (iCloud или файл).
    /// Побеждает более свежая запись; «просмотрено» не снимается — отметку,
    /// заработанную на другом устройстве, терять нельзя.
    @discardableResult
    func mergeWatch(_ incoming: [UUID: WatchState]) -> Int {
        var changed = 0
        for (key, remote) in incoming {
            guard let local = watch[key] else {
                watch[key] = remote
                changed += 1
                continue
            }
            var merged = local.lastPlayedAt >= remote.lastPlayedAt ? local : remote
            merged.isFinished = local.isFinished || remote.isFinished
            merged.playCount = max(local.playCount, remote.playCount)
            if merged != local {
                watch[key] = merged
                changed += 1
            }
        }
        if changed > 0 { scheduleSave() }
        return changed
    }

    /// Сколько серий сериала просмотрено.
    func watchedEpisodeCount(_ entry: MediaEntry) -> Int {
        entry.episodes.count { watch[$0.id]?.isFinished == true }
    }

    /// Что показать в «Продолжить смотреть». Файл может отсутствовать —
    /// тогда карточка всё равно видна, но включить её нельзя.
    struct ContinueItem: Identifiable, Hashable {
        var id: UUID { key }
        var key: UUID
        var entry: MediaEntry
        var episode: EpisodeEntry?
        var state: WatchState

        var file: VideoFileRef? { episode?.file ?? entry.movieFile }
        var isAvailable: Bool { file != nil }
    }

    var continueWatching: [ContinueItem] {
        var items: [ContinueItem] = []
        for entry in entries {
            switch entry.kind {
            case .movie:
                guard let state = watch[entry.watchKey], state.isInProgress else { continue }
                items.append(ContinueItem(key: entry.watchKey, entry: entry, episode: nil, state: state))
            case .show:
                let ordered = entry.episodes.sorted { ($0.season, $0.episode) < ($1.season, $1.episode) }
                // Незаконченная серия важнее следующей по порядку.
                if let current = ordered.first(where: { watch[$0.id]?.isInProgress == true }) {
                    items.append(ContinueItem(key: current.id, entry: entry, episode: current,
                                              state: watch[current.id] ?? WatchState()))
                } else if ordered.contains(where: { watch[$0.id]?.isFinished == true }),
                          // Следующей предлагаем ту, что вышла и есть на диске.
                          let next = ordered.first(where: {
                              watch[$0.id]?.isFinished != true && $0.isAvailable && !$0.isUpcoming
                          }) {
                    items.append(ContinueItem(key: next.id, entry: entry, episode: next,
                                              state: watch[next.id] ?? WatchState()))
                }
            }
        }
        return items.sorted { $0.state.lastPlayedAt > $1.state.lastPlayedAt }
    }

    /// Следующая серия для автоперехода: пропускаем те, которых нет на диске.
    func nextEpisode(after episode: EpisodeEntry, in entry: MediaEntry) -> EpisodeEntry? {
        let ordered = entry.episodes.sorted { ($0.season, $0.episode) < ($1.season, $1.episode) }
        guard let index = ordered.firstIndex(where: { $0.id == episode.id }) else { return nil }
        return ordered[(index + 1)...].first { $0.isAvailable }
    }
}

// MARK: - Coders

extension JSONDecoder {
    nonisolated static let videoClient: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

extension JSONEncoder {
    nonisolated static let videoClient: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
}
