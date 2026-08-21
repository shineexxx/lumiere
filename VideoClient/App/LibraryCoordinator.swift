import Foundation
import Observation

/// Оркестрирует сканирование папок и загрузку метаданных.
/// Держит очередь карточек, ожидающих подтверждения совпадения.
@Observable
@MainActor
final class LibraryCoordinator {

    private let store: LibraryStore
    private let access: FolderAccess
    let client: TMDBClient

    /// Карточки, которым подобран кандидат и которые ждут подтверждения пользователя.
    struct PendingMatch: Identifiable {
        var id: UUID { entry.id }
        var entry: MediaEntry
        var candidates: [MatchCandidate]
    }

    private(set) var pending: [PendingMatch] = []
    var isMatching = false
    var lastError: String?

    /// Настройка: подтверждать каждое совпадение или принимать уверенные автоматически.
    var autoAcceptConfident: Bool {
        didSet { UserDefaults.standard.set(autoAcceptConfident, forKey: "autoAcceptConfident") }
    }

    init(store: LibraryStore, access: FolderAccess, client: TMDBClient) {
        self.store = store
        self.access = access
        self.client = client
        self.autoAcceptConfident = UserDefaults.standard.bool(forKey: "autoAcceptConfident")
    }

    // MARK: - Сканирование

    func addFolder() async {
        guard let root = access.pickFolder() else { return }
        store.addRoot(root)
        await scan(roots: [root])
    }

    func rescanAll() async {
        await scan(roots: store.roots)
    }

    func scan(roots: [LibraryRoot]) async {
        store.isBusy = true
        defer { store.isBusy = false; store.statusMessage = nil }

        let known = store.knownFileKeys
        var newEntries: [MediaEntry] = []

        for root in roots {
            guard let url = access.url(for: root) else {
                lastError = String(localized: "Папка недоступна:\n\(root.displayPath)\n\nПроверьте, подключён ли диск и на месте ли папка. Если она переехала — уберите её в настройках и добавьте заново.")
                continue
            }
            store.statusMessage = String(localized: "Сканирую \(url.lastPathComponent)…")
            let rootID = root.id
            let found = await Task.detached(priority: .userInitiated) {
                LibraryScanner.scan(rootURL: url, rootID: rootID)
            }.value

            let fresh = found.filter { !known.contains("\($0.file.rootID.uuidString)|\($0.file.relativePath)") }
            newEntries.append(contentsOf: LibraryScanner.group(fresh))
        }

        guard !newEntries.isEmpty else {
            store.statusMessage = String(localized: "Новых файлов не найдено")
            try? await Task.sleep(for: .seconds(2))
            return
        }

        // Эпизоды уже известного сериала подклеиваем к существующей карточке.
        var addedEntries: [MediaEntry] = []
        for entry in newEntries {
            if entry.kind == .show,
               let existingIndex = store.entries.firstIndex(where: {
                   $0.kind == .show &&
                   LibraryScanner.normalizedKey($0.parsedTitle) == LibraryScanner.normalizedKey(entry.parsedTitle)
               }) {
                var existing = store.entries[existingIndex]
                // Серия могла уже быть в карточке как метаданные с TMDB (без файла).
                // Тогда прикрепляем файл к ней, а не заводим вторую строку «Эпизод N».
                for fresh in entry.episodes {
                    if let index = existing.episodes.firstIndex(where: {
                        $0.season == fresh.season && $0.episode == fresh.episode
                    }) {
                        let currentSize = existing.episodes[index].file?.fileSize ?? 0
                        if (fresh.file?.fileSize ?? 0) > currentSize {
                            existing.episodes[index].file = fresh.file
                        }
                    } else {
                        existing.episodes.append(fresh)
                    }
                }
                existing.episodes.sort { ($0.season, $0.episode) < ($1.season, $1.episode) }
                store.upsert(existing)
                if let tmdbID = existing.tmdbID {
                    // Дозагружаем метаданные только для новых серий.
                    if let filled = await refreshedEpisodes(for: existing, showID: tmdbID) {
                        store.upsert(filled)
                    }
                }
            } else {
                store.upsert(entry)
                addedEntries.append(entry)
            }
        }

        store.collapseDuplicateEpisodes()
        store.statusMessage = String(localized: "Добавлено: \(addedEntries.count)")
        await matchMetadata(for: addedEntries)
    }

    // MARK: - Метаданные

    func matchMetadata(for entries: [MediaEntry]) async {
        guard await client.hasKey else {
            lastError = String(localized: "Добавьте API-ключ TMDB в настройках, чтобы подтянуть постеры и описания.")
            return
        }
        isMatching = true
        defer { isMatching = false; store.statusMessage = nil }

        let matcher = Matcher(client: client)
        for (index, entry) in entries.enumerated() {
            store.statusMessage = String(localized: "Ищу в TMDB: \(entry.parsedTitle) (\(index + 1)/\(entries.count))")
            do {
                let candidates = try await matcher.candidates(for: entry)
                guard let best = candidates.first else {
                    store.update(id: entry.id) { $0.matchState = .unmatched }
                    continue
                }
                if autoAcceptConfident, best.score >= Matcher.confidentThreshold {
                    let updated = try await matcher.apply(candidate: best, to: entry)
                    store.upsert(renameIfEnabled(updated))
                } else {
                    store.update(id: entry.id) { $0.matchState = .suggested }
                    if let current = store.entry(id: entry.id) {
                        pending.append(PendingMatch(entry: current, candidates: candidates))
                    }
                }
            } catch {
                lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                // Ключ неверный — дальше пробовать бессмысленно.
                if case TMDBError.unauthorized = error { break }
                if case TMDBError.missingKey = error { break }
            }
        }
    }

    /// Пользователь выбрал вариант в листе подтверждения.
    func confirm(candidate: MatchCandidate, for entryID: UUID) async {
        guard let entry = store.entry(id: entryID) else { return }
        do {
            let updated = try await Matcher(client: client).apply(candidate: candidate, to: entry)
            store.upsert(renameIfEnabled(updated))
        } catch {
            lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        pending.removeAll { $0.id == entryID }
    }

    /// Переименовывает файлы карточки по метаданным TMDB, если это включено в настройках.
    @discardableResult
    func renameIfEnabled(_ entry: MediaEntry) -> MediaEntry {
        guard FileRenamer.isEnabled, entry.tmdbID != nil else { return entry }
        let renamer = FileRenamer(access: access, roots: store.roots)
        let (updated, outcome) = renamer.rename(entry: entry)
        if outcome.renamed > 0 { renamedCount += outcome.renamed }
        if !outcome.failures.isEmpty {
            lastError = String(localized: "Не удалось переименовать:") + "\n" + outcome.failures.prefix(5).joined(separator: "\n")
        }
        return updated
    }

    /// Сколько файлов переименовано за сессию — показываем в статусе.
    private(set) var renamedCount = 0

    /// Переименовать всё, что уже опознано, — по кнопке в настройках.
    func renameAllMatched() async {
        store.isBusy = true
        defer { store.isBusy = false; store.statusMessage = nil }
        let renamer = FileRenamer(access: access, roots: store.roots)
        var total = 0
        var failures: [String] = []
        for entry in store.entries where entry.tmdbID != nil {
            store.statusMessage = String(localized: "Переименовываю: \(entry.displayTitle)")
            let (updated, outcome) = renamer.rename(entry: entry)
            total += outcome.renamed
            failures.append(contentsOf: outcome.failures)
            if outcome.renamed > 0 { store.upsert(updated) }
        }
        store.statusMessage = String(localized: "Переименовано файлов: \(total)")
        if !failures.isEmpty {
            lastError = "Не удалось переименовать:\n" + failures.prefix(8).joined(separator: "\n")
        }
        try? await Task.sleep(for: .seconds(2))
    }

    func skipMatch(for entryID: UUID) {
        store.update(id: entryID) { $0.matchState = .skipped }
        pending.removeAll { $0.id == entryID }
    }

    func skipAllPending() {
        for item in pending { store.update(id: item.id) { $0.matchState = .skipped } }
        pending.removeAll()
    }

    /// Ручной поиск из экрана карточки — «это не тот фильм».
    /// Ищет и фильмы, и сериалы: тип, угаданный по имени файла, часто неверен.
    func search(query: String, kind: MediaKind?) async -> [MatchCandidate] {
        do {
            return try await Matcher(client: client).search(title: query, year: nil, preferring: kind)
        } catch {
            lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return []
        }
    }

    /// Перечитывает метаданные всех подтверждённых карточек на текущем языке.
    ///
    /// Нужно после смены языка: у карточек, добавленных раньше, названия и описания
    /// остаются такими, какими их скачали. Файлы, серии и отметки о просмотре
    /// не трогаются — обновляются только тексты, постеры и состав.
    func refreshMetadata() async {
        guard await client.hasKey else {
            lastError = String(localized: "Добавьте API-ключ TMDB в настройках, чтобы подтянуть постеры и описания.")
            return
        }
        let targets = store.entries.filter { $0.tmdbID != nil }
        guard !targets.isEmpty else { return }

        store.isBusy = true
        defer { store.isBusy = false; store.statusMessage = nil }

        let matcher = Matcher(client: client)
        var updatedCount = 0
        for (index, entry) in targets.enumerated() {
            guard let tmdbID = entry.tmdbID else { continue }
            store.statusMessage = String(localized: "Обновляю метаданные: \(entry.displayTitle) (\(index + 1)/\(targets.count))")
            do {
                let refreshed = try await matcher.apply(candidate: MatchCandidate(entry: entry, tmdbID: tmdbID),
                                                        to: entry)
                store.upsert(refreshed)
                updatedCount += 1
            } catch {
                lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                if case TMDBError.unauthorized = error { break }
                if case TMDBError.missingKey = error { break }
            }
        }
        store.saveNow()
        store.statusMessage = String(localized: "Метаданные обновлены: \(updatedCount)")
    }

    // MARK: - Рекомендации

    /// Полки рекомендаций: их показывают и «Главная», и «Новое и рекомендации».
    /// Держим в одном месте, чтобы при каждом переключении раздела не ходить в TMDB заново.
    private(set) var shelves: [Recommender.Shelf] = []
    private(set) var isLoadingShelves = false
    private(set) var shelvesError: String?
    private var shelvesLoadedAt: Date?

    /// Час — разумный срок: подборки TMDB меняются медленно, а история просмотров
    /// за сеанс может измениться, поэтому force обновляет немедленно.
    private static let shelvesLifetime: TimeInterval = 3600

    func loadShelves(force: Bool = false) async {
        if !force, !shelves.isEmpty, let loadedAt = shelvesLoadedAt,
           Date().timeIntervalSince(loadedAt) < Self.shelvesLifetime {
            return
        }
        guard !isLoadingShelves else { return }
        isLoadingShelves = true
        defer { isLoadingShelves = false }

        guard await client.hasKey else {
            shelvesError = String(localized: "Не задан API-ключ TMDB. Откройте Настройки (⌘,) и добавьте ключ.")
            return
        }
        let taste = Recommender.taste(entries: store.entries, watch: store.watch)
        let result = await Recommender(client: client).shelves(taste: taste)
        if result.isEmpty {
            shelvesError = String(localized: "TMDB не вернул подборок. Проверьте соединение и попробуйте ещё раз.")
        } else {
            shelves = result
            shelvesError = nil
            shelvesLoadedAt = Date()
        }
    }

    /// Глобальный поиск по всему каталогу TMDB — строка в правом верхнем углу.
    /// Ошибку возвращаем вызывающему, а не через общий алерт: при поиске по мере
    /// набора модальное окно на каждый сетевой сбой было бы невыносимо.
    func searchEverything(query: String) async throws -> [MatchCandidate] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [] }
        return try await client.searchMulti(text).compactMap(MatchCandidate.init(multi:))
    }

    /// Перечитывает имена всех уже добавленных файлов текущим парсером и заново
    /// собирает карточки: серии одного сериала сливаются в одну, метаданные и
    /// прогресс просмотра сохраняются (идентификаторы файлов не меняются).
    func rebuildFromFilenames() async {
        store.isBusy = true
        defer { store.isBusy = false; store.statusMessage = nil }
        store.statusMessage = String(localized: "Перечитываю имена файлов…")

        // Запоминаем, какие метаданные уже подтверждены — по файлам, а не по карточке.
        var metadataByFile: [UUID: MediaEntry] = [:]
        for entry in store.entries where entry.tmdbID != nil {
            for file in entry.allFiles { metadataByFile[file.id] = entry }
        }

        let found: [LibraryScanner.FoundFile] = store.entries.flatMap { entry in
            entry.allFiles.map { file in
                let components = file.relativePath.split(separator: "/").map(String.init)
                let parents = Array(components.dropLast())
                return LibraryScanner.FoundFile(
                    file: file,
                    parsed: FilenameParser.parse(fileName: file.fileName, parentFolders: parents)
                )
            }
        }

        var rebuilt = LibraryScanner.group(found)

        // Возвращаем метаданные тем группам, где хотя бы один файл был опознан раньше.
        for index in rebuilt.indices {
            let files = rebuilt[index].allFiles
            guard let source = files.compactMap({ metadataByFile[$0.id] }).first else { continue }
            let episodes = rebuilt[index].episodes
            let movieFile = rebuilt[index].movieFile
            let kind = rebuilt[index].kind
            var merged = source
            merged.id = rebuilt[index].id
            merged.parsedTitle = rebuilt[index].parsedTitle
            merged.parsedYear = rebuilt[index].parsedYear
            merged.kind = kind
            merged.episodes = episodes
            merged.movieFile = movieFile
            rebuilt[index] = merged
        }

        store.replaceEntries(rebuilt)

        // Для сериалов дозагружаем названия серий, которых раньше не было.
        let matcher = Matcher(client: client)
        for entry in rebuilt where entry.kind == .show && entry.tmdbID != nil {
            store.statusMessage = String(localized: "Обновляю серии: \(entry.displayTitle)")
            if let filled = await refreshedEpisodes(for: entry, showID: entry.tmdbID!) {
                store.upsert(filled)
            }
        }

        store.statusMessage = String(localized: "Готово: \(Plural.items(rebuilt.count))")
        try? await Task.sleep(for: .seconds(2))
    }

    /// Перечитывает список серий сериала целиком: сначала берём перечень сезонов,
    /// затем каждый сезон. Так в карточке оказываются и не скачанные серии.
    func refreshedEpisodes(for entry: MediaEntry, showID: Int) async -> MediaEntry? {
        let matcher = Matcher(client: client)
        let seasons = (try? await client.showDetail(id: showID).seasons) ?? []
        return try? await matcher.fillEpisodes(in: entry, showID: showID, allSeasons: seasons)
    }

    /// Готовит карточку для просмотра, ничего не сохраняя в библиотеку.
    /// Нужно, чтобы из рекомендаций можно было заглянуть в описание и состав,
    /// не засоряя библиотеку тем, что ещё не решил смотреть.
    func preview(for candidate: MatchCandidate) async -> MediaEntry? {
        let stub = MediaEntry(kind: candidate.kind,
                              parsedTitle: candidate.title,
                              parsedYear: candidate.year)
        do {
            return try await Matcher(client: client).apply(candidate: candidate, to: stub)
        } catch {
            lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return nil
        }
    }

    /// Добавляет карточку прямо из TMDB, без файлов на диске.
    /// Так в библиотеке можно вести список того, что посмотрел где-то ещё,
    /// или отметить будущее к просмотру.
    func addFromTMDB(_ candidate: MatchCandidate) async -> MediaEntry? {
        if let existing = store.entries.first(where: { $0.tmdbID == candidate.id && $0.kind == candidate.kind }) {
            return existing
        }
        let stub = MediaEntry(kind: candidate.kind,
                              parsedTitle: candidate.title,
                              parsedYear: candidate.year)
        do {
            let filled = try await Matcher(client: client).apply(candidate: candidate, to: stub)
            store.upsert(filled)
            return filled
        } catch {
            lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return nil
        }
    }

    /// Повторить поиск метаданных для карточек без совпадения.
    func retryUnmatched() async {
        let targets = store.entries.filter { $0.matchState == .unmatched || $0.matchState == .suggested }
        await matchMetadata(for: targets)
    }

    func enqueueForConfirmation(_ entry: MediaEntry, candidates: [MatchCandidate]) {
        pending.removeAll { $0.id == entry.id }
        pending.append(PendingMatch(entry: entry, candidates: candidates))
    }
}
