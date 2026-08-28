import SwiftUI

/// Окно проигрывателя: видео на весь экран, стеклянная панель с названием сверху,
/// собственные контролы снизу поверх нативных.
struct PlayerScreen: View {
    @Environment(PlaybackSession.self) private var session
    @Environment(LibraryStore.self) private var store
    @Environment(\.dismissWindow) private var dismissWindow

    @State private var controlsVisible = true
    @State private var hideTask: Task<Void, Never>?
    @State private var window: NSWindow?
    @State private var showingTracks = false

    var body: some View {
        @Bindable var session = session

        ZStack {
            Color.black.ignoresSafeArea()

            videoSurface
                .ignoresSafeArea()
                // Клик по картинке — пауза. Раньше паузу перехватывал сам VLC,
                // и наши контролы об этом не знали.
                .onTapGesture {
                    session.togglePlayPause()
                    revealControls()
                }

            WindowCloseObserver { session.close() }.frame(width: 0, height: 0)
            WindowAccessor(window: $window).frame(width: 0, height: 0)

            if controlsVisible {
                VStack {
                    topBar
                    Spacer()
                    bottomBar
                }
                .padding(20)
                .transition(.opacity)
            }
        }
        .onContinuousHover { phase in
            if case .active = phase { revealControls() }
        }
        .onAppear { revealControls() }
        .onDisappear { hideTask?.cancel() }
        .alert("Не удалось воспроизвести",
               isPresented: Binding(get: { session.errorMessage != nil },
                                    set: { if !$0 { session.dismissError() } })) {
            Button("Понятно", role: .cancel) { session.dismissError() }
        } message: {
            Text(session.errorMessage ?? "")
        }
        .focusable()
        // Фокус нужен ради клавиш, но система рисует вокруг фокусируемой вьюхи
        // синее кольцо — в полноэкранном режиме оно висит рамкой вокруг видео.
        .focusEffectDisabled()
        .onKeyPress(.space) { session.togglePlayPause(); revealControls(); return .handled }
        .onKeyPress(.leftArrow) { session.skip(-10); revealControls(); return .handled }
        .onKeyPress(.rightArrow) { session.skip(10); revealControls(); return .handled }
        .onKeyPress(.escape) {
            if FullScreen.isActive(window) {
                FullScreen.toggle(window)
            } else {
                dismissWindow(id: "player")
            }
            return .handled
        }
        .onKeyPress(.init("f")) { toggleFullScreen(); return .handled }
        .onKeyPress(.init("n")) { session.goToNextEpisode(); return .handled }
        .onKeyPress(.init("p")) { session.goToPreviousEpisode(); return .handled }
        .onKeyPress(.upArrow) { session.skip(60); revealControls(); return .handled }
        .onKeyPress(.downArrow) { session.skip(-60); revealControls(); return .handled }
    }

    @ViewBuilder
    private var videoSurface: some View {
        #if canImport(VLCKit)
        if session.backend == .vlc {
            VLCVideoContainer(engine: session.vlcEngine)
        } else {
            AVPlayerContainer(player: session.avEngine.player)
        }
        #else
        AVPlayerContainer(player: session.avEngine.player)
        #endif
    }

    private var topBar: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(session.item?.title ?? "")
                    .font(.headline)
                if let subtitle = session.item?.subtitle {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button {
                dismissWindow(id: "player")
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 26, height: 26)
            }
            .buttonStyle(.plain)
            .help("Закрыть плеер (Esc)")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
        .frame(maxWidth: 720)
    }

    private var bottomBar: some View {
        VStack(spacing: 10) {
            Scrubber(current: session.currentTime,
                     duration: session.duration) { session.seek(to: $0) }

            HStack(spacing: 16) {
                Text(TimeFormat.clock(session.currentTime))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)

                Spacer()

                if session.canGoToPreviousEpisode {
                    Button { session.goToPreviousEpisode() } label: {
                        Image(systemName: "backward.end.fill").font(.title3)
                    }
                    .buttonStyle(.plain)
                    .help("Предыдущая серия (P)")
                }

                Button { session.skip(-10) } label: {
                    Image(systemName: "gobackward.10").font(.title3)
                }
                .buttonStyle(.plain)

                Button { session.togglePlayPause() } label: {
                    Image(systemName: session.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title)
                        .frame(width: 34)
                }
                .buttonStyle(.plain)

                Button { session.skip(10) } label: {
                    Image(systemName: "goforward.10").font(.title3)
                }
                .buttonStyle(.plain)

                if session.canGoToNextEpisode {
                    Button { session.goToNextEpisode() } label: {
                        Image(systemName: "forward.end.fill").font(.title3)
                    }
                    .buttonStyle(.plain)
                    .help("Следующая серия (N)")
                }

                Spacer()

                Menu {
                    ForEach([0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { value in
                        Button {
                            session.setRate(Float(value))
                        } label: {
                            Label(String(format: "%.2fx", value),
                                  systemImage: abs(Double(session.rate) - value) < 0.01 ? "checkmark" : "")
                        }
                    }
                } label: {
                    Text(String(format: "%.2gx", Double(session.rate)))
                        .font(.caption.monospacedDigit())
                }
                .menuStyle(.borderlessButton)
                .frame(width: 52)

                Button { showingTracks = true } label: {
                    Image(systemName: "captions.bubble").font(.body)
                }
                .buttonStyle(.plain)
                .help("Дорожки и субтитры")
                .popover(isPresented: $showingTracks, arrowEdge: .bottom) {
                    TrackSettingsPopover().environment(session)
                }

                Button { toggleFullScreen() } label: {
                    Image(systemName: FullScreen.isActive(window)
                          ? "arrow.down.right.and.arrow.up.left"
                          : "arrow.up.left.and.arrow.down.right")
                        .font(.body)
                }
                .buttonStyle(.plain)
                .help("Весь экран (F)")

                Text("−" + TimeFormat.clock(max(0, session.duration - session.currentTime)))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .glassEffect(.regular, in: .rect(cornerRadius: 22))
        .frame(maxWidth: 720)
    }

    private func toggleFullScreen() {
        FullScreen.toggle(window)
    }

    private func revealControls() {
        withAnimation(.easeOut(duration: 0.18)) { controlsVisible = true }
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, session.isPlaying else { return }
            withAnimation(.easeIn(duration: 0.4)) { controlsVisible = false }
            // Вместе с контролами убираем курсор: в полноэкранном режиме
            // стрелка посреди кадра мешает. Система вернёт его сама,
            // как только мышь двинется, — и тогда покажутся и контролы.
            if FullScreen.isActive(window) {
                NSCursor.setHiddenUntilMouseMoves(true)
            }
        }
    }
}

/// Полоса перемотки с перетаскиванием.
struct Scrubber: View {
    let current: Double
    let duration: Double
    let onSeek: (Double) -> Void

    @State private var dragFraction: Double?

    private var fraction: Double {
        if let dragFraction { return dragFraction }
        guard duration > 0 else { return 0 }
        return min(1, max(0, current / duration))
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.tertiary).frame(height: 5)
                Capsule().fill(Color.accentColor)
                    .frame(width: geo.size.width * fraction, height: 5)
                Circle()
                    .fill(.white)
                    .frame(width: dragFraction == nil ? 11 : 15)
                    .shadow(radius: 2)
                    .offset(x: geo.size.width * fraction - (dragFraction == nil ? 5.5 : 7.5))
            }
            .frame(height: 16)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard duration > 0 else { return }
                        dragFraction = min(1, max(0, value.location.x / geo.size.width))
                    }
                    .onEnded { _ in
                        if let dragFraction, duration > 0 { onSeek(dragFraction * duration) }
                        dragFraction = nil
                    }
            )
            .animation(.easeOut(duration: 0.15), value: dragFraction == nil)
        }
        .frame(height: 16)
    }
}

nonisolated enum TimeFormat {
    static func clock(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded())
        let hours = total / 3600, minutes = (total % 3600) / 60, secs = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%d:%02d", minutes, secs)
    }

    /// «2 ч 18 мин» для длительности фильма.
    static func runtime(minutes: Int) -> String {
        let hours = minutes / 60, mins = minutes % 60
        if hours > 0 && mins > 0 { return String(localized: "\(hours) ч \(mins) мин") }
        if hours > 0 { return String(localized: "\(hours) ч") }
        return String(localized: "\(mins) мин")
    }
}
