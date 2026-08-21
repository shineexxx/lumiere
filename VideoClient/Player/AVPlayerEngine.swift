import Foundation
import AVFoundation
import AVKit
import SwiftUI

@MainActor
final class AVPlayerEngine: PlayerEngine {

    let player = AVPlayer()

    var onTimeUpdate: ((Double, Double) -> Void)?
    var onFinished: (() -> Void)?
    var onFailure: ((String) -> Void)?
    var onPlayingChanged: ((Bool) -> Void)?
    private var rateObservation: NSKeyValueObservation?

    private var timeObserver: Any?
    private var statusObservation: NSKeyValueObservation?
    private var endObserver: NSObjectProtocol?
    private var pendingSeek: Double?

    var currentTime: Double {
        let time = player.currentTime().seconds
        return time.isFinite ? time : 0
    }

    var duration: Double {
        guard let item = player.currentItem else { return 0 }
        let value = item.duration.seconds
        return value.isFinite && value > 0 ? value : 0
    }

    var isPlaying: Bool { player.timeControlStatus == .playing }

    init() {
        player.automaticallyWaitsToMinimizeStalling = true
        // Пауза может прийти не от нас — например, от системных медиаклавиш.
        rateObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
            Task { @MainActor in
                self?.onPlayingChanged?(player.timeControlStatus == .playing)
            }
        }
    }

    func load(url: URL, startAt: Double) {
        teardownObservers()

        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let item = AVPlayerItem(asset: asset)
        player.replaceCurrentItem(with: item)
        pendingSeek = startAt > 1 ? startAt : nil

        statusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            Task { @MainActor in
                guard let self else { return }
                switch item.status {
                case .readyToPlay:
                    if let seek = self.pendingSeek {
                        self.pendingSeek = nil
                        self.seek(to: seek)
                    }
                    self.player.play()
                case .failed:
                    let message = item.error?.localizedDescription
                        ?? String(localized: "Системный плеер не смог открыть этот файл.")
                    self.onFailure?(message)
                default:
                    break
                }
            }
        }

        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.onFinished?() }
        }

        // Раз в секунду достаточно: прогресс всё равно пишется на диск с дебаунсом.
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 1, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            Task { @MainActor in
                guard let self else { return }
                let position = time.seconds
                guard position.isFinite else { return }
                self.onTimeUpdate?(position, self.duration)
            }
        }
    }

    func play() { player.play() }
    func pause() { player.pause() }

    func seek(to seconds: Double) {
        let target = CMTime(seconds: max(0, seconds), preferredTimescale: 600)
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func setRate(_ rate: Float) {
        player.rate = rate
    }

    func setVolume(_ volume: Float) {
        player.volume = max(0, min(1, volume))
    }

    func teardown() {
        player.pause()
        teardownObservers()
        player.replaceCurrentItem(with: nil)
    }

    private func teardownObservers() {
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        statusObservation?.invalidate()
        statusObservation = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
    }

    /// Быстрая проверка перед открытием: умеет ли AVFoundation вообще это читать.
    nonisolated static func isPlayable(url: URL) async -> Bool {
        let asset = AVURLAsset(url: url)
        return (try? await asset.load(.isPlayable)) ?? false
    }
}

/// Нативный AVPlayerView: даёт бесплатно дорожки аудио, субтитры, PiP и полноэкранный режим.
struct AVPlayerContainer: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .floating
        view.showsFullScreenToggleButton = true
        view.allowsPictureInPicturePlayback = true
        view.videoGravity = .resizeAspect
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
    }
}
