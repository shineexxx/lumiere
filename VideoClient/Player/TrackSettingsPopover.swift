import SwiftUI

/// Панель тонкой настройки текущего воспроизведения: дорожки, субтитры, задержки.
/// Работает только на VLC — у него есть доступ к дорожкам контейнера.
struct TrackSettingsPopover: View {
    @Environment(PlaybackSession.self) private var session

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            #if canImport(VLCKit)
            if session.backend == .vlc {
                vlcControls
            } else {
                unavailable
            }
            #else
            unavailable
            #endif
        }
        .frame(width: 330)
    }

    private var unavailable: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Настройки дорожек недоступны")
                .font(.headline)
            Text("Дорожки и субтитры доступны при воспроизведении через VLC.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(16)
    }

    #if canImport(VLCKit)
    @ViewBuilder
    private var vlcControls: some View {
        let engine = session.vlcEngine

        Form {
            Section("Звук") {
                let audio = engine.audioTracks
                if audio.isEmpty {
                    Text("Дорожек нет").foregroundStyle(.secondary)
                } else {
                    Picker("Дорожка", selection: Binding(
                        get: { audio.first(where: \.isSelected)?.id ?? audio.first?.id ?? "" },
                        set: { engine.selectAudioTrack(id: $0) }
                    )) {
                        ForEach(audio) { track in
                            Text(track.name).tag(track.id)
                        }
                    }
                }
                DelayStepper(title: String(localized: "Задержка звука"),
                             value: Binding(get: { engine.audioDelay },
                                            set: { engine.audioDelay = $0 }))
            }

            Section("Субтитры") {
                let subs = engine.subtitleTracks
                Picker("Дорожка", selection: Binding(
                    get: { subs.first(where: \.isSelected)?.id ?? "" },
                    set: { engine.selectSubtitleTrack(id: $0.isEmpty ? nil : $0) }
                )) {
                    Text("Выключены").tag("")
                    ForEach(subs) { track in
                        Text(track.name).tag(track.id)
                    }
                }
                DelayStepper(title: String(localized: "Задержка субтитров"),
                             value: Binding(get: { engine.subtitleDelay },
                                            set: { engine.subtitleDelay = $0 }))
            }

            Section("Изображение") {
                Picker("Пропорции", selection: Binding(
                    get: { PlaybackPreferences.aspectRatio },
                    set: {
                        PlaybackPreferences.aspectRatio = $0
                        engine.setAspectRatio($0.isEmpty ? nil : $0)
                    }
                )) {
                    Text("Как в источнике").tag("")
                    Text("16:9").tag("16:9")
                    Text("4:3").tag("4:3")
                    Text("21:9").tag("21:9")
                    Text("1:1").tag("1:1")
                }
                Picker("Деинтерлейсинг", selection: Binding(
                    get: { PlaybackPreferences.deinterlace },
                    set: {
                        PlaybackPreferences.deinterlace = $0
                        engine.setDeinterlace($0.isEmpty ? nil : $0)
                    }
                )) {
                    Text("Выключен").tag("")
                    Text("Blend").tag("blend")
                    Text("Bob").tag("bob")
                    Text("Yadif").tag("yadif")
                    Text("Yadif 2x").tag("yadif2x")
                }
            }
        }
        .formStyle(.grouped)
        .frame(height: 380)
    }
    #endif
}

/// Шаг ±0.1 с для задержек — привычная в плеерах величина.
struct DelayStepper: View {
    let title: String
    @Binding var value: Double

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Button { value -= 0.1 } label: { Image(systemName: "minus") }
                .buttonStyle(.borderless)
            Text(String(format: "%+.1f с", value))
                .font(.callout.monospacedDigit())
                .frame(width: 62)
            Button { value += 0.1 } label: { Image(systemName: "plus") }
                .buttonStyle(.borderless)
            Button { value = 0 } label: { Image(systemName: "arrow.counterclockwise") }
                .buttonStyle(.borderless)
                .help("Сбросить")
        }
    }
}

/// Настройки воспроизведения, которые должны переживать перезапуск.
nonisolated enum PlaybackPreferences {
    static var aspectRatio: String {
        get { UserDefaults.standard.string(forKey: "videoAspectRatio") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "videoAspectRatio") }
    }

    static var deinterlace: String {
        get { UserDefaults.standard.string(forKey: "videoDeinterlace") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "videoDeinterlace") }
    }

    /// Устройство вывода звука (AudioDeviceID). 0 — как в системе.
    static var audioDeviceID: UInt32 {
        get { UInt32(UserDefaults.standard.object(forKey: "audioOutputDeviceID") as? Int ?? 0) }
        set { UserDefaults.standard.set(Int(newValue), forKey: "audioOutputDeviceID") }
    }

    /// Размер сетевого/дискового кэша VLC в миллисекундах.
    static var fileCaching: Int {
        get { UserDefaults.standard.object(forKey: "vlcFileCaching") as? Int ?? 300 }
        set { UserDefaults.standard.set(newValue, forKey: "vlcFileCaching") }
    }

    /// Пропускать заново открытый файл на сохранённую позицию.
    static var rememberPosition: Bool {
        get { UserDefaults.standard.object(forKey: "rememberPosition") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "rememberPosition") }
    }

    /// Автоматически включать следующую серию.
    static var autoPlayNext: Bool {
        get { UserDefaults.standard.object(forKey: "autoPlayNext") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "autoPlayNext") }
    }

    /// Пропускать найденную заставку самому, не дожидаясь нажатия кнопки.
    /// По умолчанию выключено: первую серию сезона обычно смотрят с заставкой.
    static var autoSkipIntro: Bool {
        get { UserDefaults.standard.bool(forKey: "autoSkipIntro") }
        set { UserDefaults.standard.set(newValue, forKey: "autoSkipIntro") }
    }
}
