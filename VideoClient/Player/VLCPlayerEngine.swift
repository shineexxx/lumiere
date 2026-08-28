import AVFoundation
import Foundation
import SwiftUI

// Код компилируется только когда в проект подключён VLCKit
// (Frameworks/VLCKit.xcframework). Без него приложение работает на AVPlayer.
#if canImport(VLCKit)
import VLCKit

/// Движок на VLC: открывает MKV, AVI и прочие контейнеры, недоступные AVFoundation.
@MainActor
final class VLCPlayerEngine: NSObject, PlayerEngine, VLCMediaPlayerDelegate {

    /// Плеер пересоздаётся при смене параметров: буфер и аппаратное декодирование
    /// libVLC читает при инициализации, менять их на лету нельзя.
    private(set) var mediaPlayer: VLCMediaPlayer
    /// Параметры, с которыми создан текущий экземпляр.
    private var activeOptions: EngineOptions

    /// Параметры libVLC, влияющие на создание плеера.
    ///
    /// Аппаратного декодирования здесь нет намеренно: на macOS libVLC всегда
    /// выбирает VideoToolbox, и ни `--avcodec-hw=none`, ни `--dec-dev=none`
    /// этого не меняют (проверено на VLCKit 4.0), а `--no-avcodec-hw` роняет
    /// инициализацию. Переключатель, который ничего не делает, — хуже, чем его отсутствие.
    struct EngineOptions: Equatable {
        var fileCachingMS: Int
        /// AudioDeviceID из CoreAudio; 0 — оставить системное устройство.
        var audioDeviceID: UInt32

        static var current: EngineOptions {
            let stored = PlaybackPreferences.audioDeviceID
            // Устройство могли отключить (наушники, телевизор) — тогда возвращаемся к системному.
            let device = AudioDevices.exists(stored) ? stored : AudioDevices.systemDefaultID
            return EngineOptions(fileCachingMS: PlaybackPreferences.fileCaching, audioDeviceID: device)
        }

        /// Аргументы командной строки libVLC.
        var arguments: [String] {
            var options = [
                "--file-caching=\(fileCachingMS)",
                "--network-caching=\(max(fileCachingMS, 1000))",
            ]
            // Выбор аудиовыхода: VLCKit своего API не даёт, но модуль auhal
            // принимает идентификатор устройства параметром.
            if audioDeviceID != AudioDevices.systemDefaultID {
                options.append("--auhal-audio-device=\(audioDeviceID)")
            }
            return options
        }

        /// Те же параметры на уровне конкретного файла — подстраховка,
        /// если экземпляр плеера переиспользуется.
        var mediaOptions: [String: Any] {
            [
                "file-caching": fileCachingMS,
                "network-caching": max(fileCachingMS, 1000),
            ]
        }
    }

    /// Поверхность вывода создаём сразу и держим сами. Если назначать drawable
    /// уже после старта воспроизведения, VLC играет только звук — видеовыход
    /// к тому моменту инициализирован без окна.
    let videoView = VLCDrawableView()

    var onTimeUpdate: ((Double, Double) -> Void)?
    var onFinished: (() -> Void)?
    var onFailure: ((String) -> Void)?
    var onPlayingChanged: ((Bool) -> Void)?

    private var pendingSeek: Double?
    private var lastReported: Double = -1
    /// Последняя известная позиция и длительность: на момент остановки
    /// VLC уже обнуляет время, а нам нужно понять, доиграли ли до конца.
    private var lastPosition: Double = 0
    private var lastDuration: Double = 0
    private var didReportFinish = false

    override init() {
        let options = EngineOptions.current
        activeOptions = options
        mediaPlayer = VLCMediaPlayer(options: options.arguments)
        super.init()
        // Как только поверхность окажется в окне — запускаем то, что ждало.
        videoView.onReadyForOutput = { [weak self] in self?.startPendingIfReady() }
        attachPlayer()
    }

    private func attachPlayer() {
        mediaPlayer.delegate = self
        mediaPlayer.drawable = videoView
        VLCLogFile.attach(to: mediaPlayer.libraryInstance)
    }

    /// Если настройки изменились, поднимаем новый экземпляр с новыми параметрами.
    private func rebuildIfOptionsChanged() {
        let options = EngineOptions.current
        guard options != activeOptions else { return }
        log.info("Параметры VLC изменились, пересоздаю плеер")
        mediaPlayer.stop()
        mediaPlayer.delegate = nil
        activeOptions = options
        mediaPlayer = VLCMediaPlayer(options: options.arguments)
        attachPlayer()
    }

    var currentTime: Double { Double(mediaPlayer.time.intValue) / 1000 }

    /// Длительность, вычитанная из файла в обход VLC.
    private var probedDuration: Double = 0

    /// Длительность ролика.
    ///
    /// У части файлов VLC сообщает длину 0 — так бывает у рипов, где в контейнере
    /// нет длительности (проверено на скачанных сериях: media.length = 0, а время
    /// идёт). Без длины ползунок стоит на нуле, а прогресс просмотра не пишется
    /// вовсе, поэтому берём её откуда получится: у VLC, у AVFoundation, а в
    /// последнюю очередь — из доли воспроизведения.
    var duration: Double {
        let length = Double(mediaPlayer.media?.length.intValue ?? 0) / 1000
        if length > 0 { return length }
        if lastDuration > 0 { return lastDuration }
        if probedDuration > 0 { return probedDuration }
        // Оценка по доле: она грубая и осмысленна только после первых процентов.
        let position = Double(mediaPlayer.position)
        let time = currentTime
        guard position > 0.02, time > 0 else { return 0 }
        return time / position
    }

    /// Спрашивает длительность у AVFoundation: для mp4 и mov она есть почти всегда,
    /// даже когда VLC её не отдаёт.
    private func probeDuration(of url: URL) {
        probedDuration = 0
        Task { [weak self] in
            let asset = AVURLAsset(url: url)
            guard let value = try? await asset.load(.duration) else { return }
            let seconds = CMTimeGetSeconds(value)
            guard seconds.isFinite, seconds > 0 else { return }
            await MainActor.run { self?.probedDuration = seconds }
        }
    }

    var isPlaying: Bool { mediaPlayer.isPlaying }

    /// Что ждёт появления окна, чтобы начать играть.
    private var pendingStart: (url: URL, startAt: Double)?

    func load(url: URL, startAt: Double) {
        rebuildIfOptionsChanged()
        didReportFinish = false
        lastReported = -1
        lastPosition = 0
        lastDuration = 0

        probeDuration(of: url)
        pendingStart = (url, startAt)
        startPendingIfReady()
    }

    /// Запускает воспроизведение только когда поверхность вывода уже в окне
    /// и имеет размер.
    ///
    /// Без этой проверки приложение падало: окно плеера SwiftUI открывает
    /// асинхронно, play() успевал сработать раньше, VLC создавал OpenGL-контекст
    /// на вьюхе без окна — и первый же кадр валил процесс через assert
    /// в `vout_display_opengl_Prepare` (GL_INVALID_FRAMEBUFFER_OPERATION,
    /// GL_OUT_OF_MEMORY). Воспроизводится стабильно, если звать play() до окна.
    private func startPendingIfReady() {
        guard let pending = pendingStart else { return }
        guard videoView.window != nil,
              videoView.bounds.width > 0, videoView.bounds.height > 0 else { return }
        pendingStart = nil

        let media: VLCMedia? = VLCMedia(url: pending.url)
        media?.addOptions(activeOptions.mediaOptions)
        mediaPlayer.media = media
        pendingSeek = pending.startAt > 1 ? pending.startAt : nil
        mediaPlayer.play()
    }

    func play() {
        // Нажали «играть» до того, как окно появилось — стартуем, когда сможем.
        guard pendingStart == nil else { return startPendingIfReady() }
        mediaPlayer.play()
    }

    func pause() { if mediaPlayer.isPlaying { mediaPlayer.pause() } }

    func seek(to seconds: Double) {
        mediaPlayer.time = VLCTime(int: Int32(seconds * 1000))
    }

    func setRate(_ rate: Float) { mediaPlayer.rate = rate }

    func setVolume(_ volume: Float) {
        mediaPlayer.audio?.volume = Int32(max(0, min(1, volume)) * 100)
    }

    func teardown() {
        pendingStart = nil
        mediaPlayer.stop()
        // Делегата не сбрасываем: движок переиспользуется при следующем запуске,
        // и без делегата не было бы ни прогресса, ни события окончания.
        mediaPlayer.media = nil
        pendingSeek = nil
    }

    // MARK: - Дорожки и тонкая настройка

    struct Track: Identifiable, Hashable {
        var id: String
        var name: String
        var isSelected: Bool
    }

    var audioTracks: [Track] {
        mediaPlayer.audioTracks.map { Track(id: $0.trackId, name: $0.trackName, isSelected: $0.isSelected) }
    }

    var subtitleTracks: [Track] {
        mediaPlayer.textTracks.map { Track(id: $0.trackId, name: $0.trackName, isSelected: $0.isSelected) }
    }

    var videoTracks: [Track] {
        mediaPlayer.videoTracks.map { Track(id: $0.trackId, name: $0.trackName, isSelected: $0.isSelected) }
    }

    func selectAudioTrack(id: String) {
        mediaPlayer.audioTracks.first { $0.trackId == id }?.isSelectedExclusively = true
    }

    func selectSubtitleTrack(id: String?) {
        guard let id else {
            mediaPlayer.textTracks.forEach { $0.isSelected = false }
            return
        }
        mediaPlayer.textTracks.first { $0.trackId == id }?.isSelectedExclusively = true
    }

    /// Задержка субтитров в секундах (VLC хранит в микросекундах).
    var subtitleDelay: Double {
        get { Double(mediaPlayer.currentVideoSubTitleDelay) / 1_000_000 }
        set { mediaPlayer.currentVideoSubTitleDelay = Int(newValue * 1_000_000) }
    }

    /// Задержка звука в секундах.
    var audioDelay: Double {
        get { Double(mediaPlayer.currentAudioPlaybackDelay) / 1_000_000 }
        set { mediaPlayer.currentAudioPlaybackDelay = Int(newValue * 1_000_000) }
    }

    /// Соотношение сторон: nil — как в источнике.
    func setAspectRatio(_ ratio: String?) {
        mediaPlayer.videoAspectRatio = ratio
    }

    /// Фильтр деинтерлейсинга: nil — выключен.
    func setDeinterlace(_ filter: String?) {
        mediaPlayer.setDeinterlaceFilter(filter)
    }

    // MARK: - VLCMediaPlayerDelegate

    nonisolated func mediaPlayerTimeChanged(_ notification: Notification) {
        Task { @MainActor in
            let total = duration
            // Длительность известна не сразу — перематываем, когда VLC готов.
            if let seek = pendingSeek, total > 0 {
                pendingSeek = nil
                self.seek(to: seek)
                return
            }
            let position = currentTime
            lastPosition = position
            lastDuration = total
            guard abs(position - lastReported) >= 1 else { return }
            lastReported = position
            onTimeUpdate?(position, total)
        }
    }

    /// В VLCKit 4 состояния «доиграл до конца» нет — есть только остановка.
    /// Отличаем финал от ручной остановки по тому, где мы были в момент стопа.
    nonisolated func mediaPlayerStateChanged(_ newState: VLCMediaPlayerState) {
        Task { @MainActor in
            switch newState {
            case .stopping, .stopped:
                guard !didReportFinish, lastDuration > 0 else { return }
                let fraction = lastPosition / lastDuration
                if fraction >= WatchRules.finishedThreshold {
                    didReportFinish = true
                    onFinished?()
                }
            case .error:
                onFailure?(String(localized: "VLC не смог открыть этот файл."))
            case .playing:
                onPlayingChanged?(true)
            case .paused:
                // Паузу мог поставить и сам VLC (клик по видео) — иконка в контролах
                // должна это отражать.
                onPlayingChanged?(false)
            default:
                break
            }
        }
    }

    nonisolated func mediaPlayerLengthChanged(_ length: Int64) {
        Task { @MainActor in
            lastDuration = Double(length) / 1000
        }
    }
}

/// Поверхность отрисовки VLC, которая сообщает, когда её можно использовать.
///
/// «Можно» — это когда вьюха попала в окно и получила размер: до этого
/// OpenGL-контекст создавать не на чем, и VLC валит процесс на первом кадре.
final class VLCDrawableView: NSView {
    var onReadyForOutput: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) не используется") }

    var isReadyForOutput: Bool {
        window != nil && bounds.width > 0 && bounds.height > 0
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if isReadyForOutput { onReadyForOutput?() }
    }

    override func layout() {
        super.layout()
        // Окно может появиться раньше, чем вьюха получит ненулевой размер.
        if isReadyForOutput { onReadyForOutput?() }
    }
}

/// Поверхность отрисовки VLC.
struct VLCVideoContainer: NSViewRepresentable {
    let engine: VLCPlayerEngine

    func makeNSView(context: Context) -> NSView {
        // Отдаём готовую поверхность движка, а не создаём новую.
        engine.videoView
    }

    func updateNSView(_ view: NSView, context: Context) {}
}
#endif
