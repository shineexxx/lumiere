import Foundation
import Observation
import SwiftUI

/// Что сейчас играет. Держит движок, пишет прогресс в библиотеку, умеет переходить к следующей серии.
@Observable
@MainActor
final class PlaybackSession {

    struct Item: Equatable {
        var entryID: UUID
        var file: VideoFileRef
        var title: String
        var subtitle: String?
        var episodeID: UUID?
        /// Куда писать прогресс: серия — по своему id, фильм — по id карточки.
        var watchKey: UUID
    }

    private(set) var item: Item?
    private(set) var backend: PlaybackBackend = .av
    var errorMessage: String?
    /// Файл, который предлагаем открыть во внешнем плеере, когда сами не можем.
    var externalPlayerURL: URL?
    /// Что играем сейчас — нужно, чтобы переоткрыть файл другим движком.
    private var currentURL: URL?
    private var didFallBackToVLC = false

    var currentTime: Double = 0
    var duration: Double = 0
    var isPlaying: Bool = false
    var rate: Float = 1.0

    /// Показывать ли окно плеера.
    var isPresented: Bool = false

    let avEngine = AVPlayerEngine()
    #if canImport(VLCKit)
    let vlcEngine = VLCPlayerEngine()
    #endif

    private unowned let store: LibraryStore
    private unowned let access: FolderAccess

    init(store: LibraryStore, access: FolderAccess) {
        self.store = store
        self.access = access
        wire(avEngine)
        #if canImport(VLCKit)
        wire(vlcEngine)
        #endif
    }

    private var engine: any PlayerEngine {
        #if canImport(VLCKit)
        if backend == .vlc { return vlcEngine }
        #endif
        return avEngine
    }

    private func wire(_ engine: some PlayerEngine) {
        engine.onTimeUpdate = { [weak self] position, duration in
            guard let self, let item = self.item else { return }
            self.currentTime = position
            self.duration = duration
            self.isPlaying = self.engine.isPlaying
            self.store.recordProgress(key: item.watchKey, position: position, duration: duration)
        }
        engine.onFinished = { [weak self] in
            guard let self, let item = self.item else { return }
            self.store.setFinished(key: item.watchKey, true)
            self.isPlaying = false
            self.playNextEpisodeIfAvailable()
        }
        // Паузу может поставить сам движок (клик по видео, медиаклавиши) —
        // без этого иконка в контролах расходилась с реальностью.
        engine.onPlayingChanged = { [weak self] playing in
            guard let self, self.item != nil else { return }
            self.isPlaying = playing
            if !playing { self.flushProgress() }
        }
        engine.onFailure = { [weak self] message in
            guard let self else { return }
            // AVFoundation не осилила файл — пробуем VLC, прежде чем ругаться.
            // Определение формата по содержимому ловит не всё: бывают экзотические
            // кодеки внутри вполне обычного контейнера.
            if self.retryWithVLC() { return }
            self.errorMessage = message
        }
    }

    // MARK: - Запуск

    func play(entry: MediaEntry, episode: EpisodeEntry? = nil, restart: Bool = false, preferred: PlaybackBackend = .av) {
        // Если серию не указали — берём первую доступную по порядку.
        let fallbackEpisode = entry.episodes
            .sorted { ($0.season, $0.episode) < ($1.season, $1.episode) }
            .first { $0.isAvailable }
        let target = episode ?? (entry.kind == .show ? fallbackEpisode : nil)
        let file = target?.file ?? entry.movieFile

        guard let file else {
            errorMessage = entry.kind == .show
                ? "Ни одна серия «\(entry.displayTitle)» не скачана.\n\n"
                    + "Карточка показывает данные с TMDB — добавьте файлы в папку библиотеки и нажмите ⌘R."
                : "Файл для «\(entry.displayTitle)» не найден в библиотеке.\n\n"
                    + "Карточка показывает данные с TMDB. Добавьте файл в папку библиотеки и нажмите ⌘R."
            return
        }
        guard let url = access.fileURL(for: file, roots: store.roots) else {
            errorMessage = "Нет доступа к файлу. Возможно, диск отключён или папку нужно добавить заново."
            return
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            errorMessage = "Файл не найден на диске:\n\(url.path)\n\n"
                + "Возможно, он был перемещён или удалён. Карточка и отметка о просмотре сохранятся."
            return
        }

        // Заведомо неоткрываемый формат — не показываем пустое окно плеера,
        // а честно объясняем, что происходит, и предлагаем внешний плеер.
        if let reason = PlaybackSupport.blockingReason(for: file, url: url) {
            errorMessage = reason
            externalPlayerURL = url
            return
        }

        stopEngineOnly()
        currentURL = url
        didFallBackToVLC = false
        backend = PlaybackSupport.recommendedBackend(for: file, url: url, preferred: preferred)

        let watchKey = target?.id ?? entry.watchKey
        let start = (restart || !PlaybackPreferences.rememberPosition)
            ? 0
            : (store.resumePosition(for: watchKey) ?? 0)
        item = Item(entryID: entry.id,
                    file: file,
                    title: entry.displayTitle,
                    subtitle: target.map { "\($0.displayCode) · \($0.title)" },
                    episodeID: target?.id,
                    watchKey: watchKey)
        currentTime = start
        duration = 0
        isPlaying = true
        isPresented = true
        engine.setRate(rate)
        engine.load(url: url, startAt: start)
        applyVideoPreferences()
    }

    /// Пропорции и деинтерлейсинг — сохранённые пользовательские настройки.
    private func applyVideoPreferences() {
        #if canImport(VLCKit)
        guard backend == .vlc else { return }
        let ratio = PlaybackPreferences.aspectRatio
        let filter = PlaybackPreferences.deinterlace
        vlcEngine.setAspectRatio(ratio.isEmpty ? nil : ratio)
        vlcEngine.setDeinterlace(filter.isEmpty ? nil : filter)
        #endif
    }

    /// Переоткрывает текущий файл через VLC. Возвращает false, если это невозможно.
    @discardableResult
    private func retryWithVLC() -> Bool {
        guard PlaybackBackend.vlcAvailable, backend == .av, !didFallBackToVLC,
              let url = currentURL else { return false }
        didFallBackToVLC = true
        let resumeAt = currentTime
        log.info("AVPlayer не открыл файл, переключаюсь на VLC")
        avEngine.teardown()
        backend = .vlc
        engine.setRate(rate)
        engine.load(url: url, startAt: resumeAt)
        isPlaying = true
        return true
    }

    func playNextEpisodeIfAvailable() {
        guard PlaybackPreferences.autoPlayNext else { return }
        guard let item, let entry = store.entry(id: item.entryID), entry.kind == .show,
              let episodeID = item.episodeID,
              let current = entry.episodes.first(where: { $0.id == episodeID }),
              let next = store.nextEpisode(after: current, in: entry) else {
            return
        }
        play(entry: entry, episode: next, restart: true, preferred: backend)
    }

    // MARK: - Навигация по сериям

    /// Текущая карточка, если это сериал.
    private var currentShow: (entry: MediaEntry, episode: EpisodeEntry)? {
        guard let item, let entry = store.entry(id: item.entryID), entry.kind == .show,
              let episodeID = item.episodeID,
              let episode = entry.episodes.first(where: { $0.id == episodeID }) else { return nil }
        return (entry, episode)
    }

    var canGoToNextEpisode: Bool { nextEpisodeTarget != nil }
    var canGoToPreviousEpisode: Bool { previousEpisodeTarget != nil }

    private var nextEpisodeTarget: EpisodeEntry? {
        guard let current = currentShow else { return nil }
        return store.nextEpisode(after: current.episode, in: current.entry)
    }

    private var previousEpisodeTarget: EpisodeEntry? {
        guard let current = currentShow else { return nil }
        let ordered = current.entry.episodes.sorted { ($0.season, $0.episode) < ($1.season, $1.episode) }
        guard let index = ordered.firstIndex(where: { $0.id == current.episode.id }) else { return nil }
        return ordered[..<index].last { $0.isAvailable }
    }

    func goToNextEpisode() {
        guard let current = currentShow, let next = nextEpisodeTarget else { return }
        play(entry: current.entry, episode: next, restart: true)
    }

    func goToPreviousEpisode() {
        guard let current = currentShow, let previous = previousEpisodeTarget else { return }
        play(entry: current.entry, episode: previous, restart: true)
    }

    // MARK: - Управление

    func togglePlayPause() {
        if engine.isPlaying {
            engine.pause()
            isPlaying = false
            flushProgress()
        } else {
            engine.play()
            isPlaying = true
        }
    }

    func seek(to seconds: Double) {
        engine.seek(to: seconds)
        currentTime = seconds
    }

    func skip(_ delta: Double) {
        seek(to: max(0, min(duration > 0 ? duration : .greatestFiniteMagnitude, currentTime + delta)))
    }

    func setRate(_ newRate: Float) {
        rate = newRate
        engine.setRate(newRate)
    }

    func close() {
        flushProgress()
        stopEngineOnly()
        item = nil
        isPresented = false
        errorMessage = nil
    }

    func dismissError() {
        errorMessage = nil
        externalPlayerURL = nil
    }

    /// Отдаёт файл системе — откроется плеером, назначенным для этого типа.
    func openExternally() {
        guard let externalPlayerURL else { return }
        NSWorkspace.shared.open(externalPlayerURL)
        dismissError()
    }

    private func flushProgress() {
        guard let item, currentTime > 0, duration > 0 else { return }
        store.recordProgress(key: item.watchKey, position: currentTime, duration: duration)
        store.saveNow()
    }

    private func stopEngineOnly() {
        avEngine.teardown()
        #if canImport(VLCKit)
        vlcEngine.teardown()
        #endif
        isPlaying = false
    }
}
