import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            TMDBSettings()
                .tabItem { Label("TMDB", systemImage: "key") }
            LibrarySettings()
                .tabItem { Label("Библиотека", systemImage: "folder") }
            PlaybackSettings()
                .tabItem { Label("Воспроизведение", systemImage: "play.rectangle") }
            SyncSettings()
                .tabItem { Label("Синхронизация", systemImage: "icloud") }
            UpdateSettings()
                .tabItem { Label("Обновления", systemImage: "arrow.down.circle") }
        }
        .frame(width: 540, height: 430)
    }
}

struct TMDBSettings: View {
    @Environment(LibraryCoordinator.self) private var coordinator

    @State private var key = TMDBKeyStore.key ?? ""
    /// nil — «как в приложении»; иначе явно выбранный язык метаданных.
    @State private var language: String? = MetadataLanguage.stored
    @State private var checkState: CheckState = .idle

    enum CheckState: Equatable {
        case idle, checking, ok, failed(String)
    }

    var body: some View {
        Form {
            Section {
                SecureField("API-ключ", text: $key)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Button("Сохранить и проверить") { saveAndCheck() }
                        .disabled(key.trimmingCharacters(in: .whitespaces).isEmpty || checkState == .checking)
                    switch checkState {
                    case .idle: EmptyView()
                    case .checking: ProgressView().controlSize(.small)
                    case .ok: Label("Ключ работает", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green).font(.callout)
                    case .failed(let message): Label(message, systemImage: "xmark.circle.fill")
                            .foregroundStyle(.red).font(.callout).lineLimit(2)
                    }
                }
                Button("Перенести ключ из связки ключей") {
                    if let imported = TMDBKeyStore.importFromKeychain() {
                        key = imported
                        saveAndCheck()
                    } else {
                        checkState = .failed(String(localized: "В связке ключей ключа не нашлось"))
                    }
                }
                .font(.callout)
            } header: {
                Text("Ключ TMDB")
            } footer: {
                Text("""
                     Ключ бесплатный: themoviedb.org → Settings → API. Подходит и короткий ключ v3, и длинный токен v4.

                     Хранится в настройках приложения открытым текстом, а не в связке ключей: \
                     приложение подписывается ad-hoc, и после каждой пересборки связка \
                     требовала бы пароль отдельным окном. Кнопка выше переносит ключ, \
                     если он остался в связке с прошлых версий.
                     """)
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Picker("Язык", selection: $language) {
                    Text("Как в приложении").tag(String?.none)
                    Divider()
                    ForEach(MetadataLanguage.options, id: \.self) { code in
                        Text(MetadataLanguage.title(for: code)).tag(String?.some(code))
                    }
                }
                .onChange(of: language) { _, value in
                    MetadataLanguage.stored = value
                    Task { await coordinator.client.setLanguage(MetadataLanguage.effective) }
                }
            } header: {
                Text("Язык метаданных")
            } footer: {
                Text(language == nil
                     ? "Сейчас: \(MetadataLanguage.title(for: MetadataLanguage.automatic)) — как язык приложения. Смените язык приложения, и описания сменятся вместе с ним."
                     : "Выбран явно и не будет меняться вместе с языком приложения.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Toggle("Принимать уверенные совпадения без подтверждения",
                       isOn: Binding(get: { coordinator.autoAcceptConfident },
                                     set: { coordinator.autoAcceptConfident = $0 }))
                Button("Повторить поиск для неопознанных") {
                    Task { await coordinator.retryUnmatched() }
                }
            } header: {
                Text("Сопоставление")
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private func saveAndCheck() {
        let trimmed = key.trimmingCharacters(in: .whitespaces)
        TMDBKeyStore.key = trimmed
        checkState = .checking
        Task {
            await coordinator.client.setKey(trimmed)
            switch await coordinator.client.validateKey() {
            case .success:
                checkState = .ok
            case .failure(let error):
                checkState = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            }
        }
    }
}

struct LibrarySettings: View {
    @Environment(LibraryStore.self) private var store
    @Environment(LibraryCoordinator.self) private var coordinator
    @State private var cacheSize: Int64 = 0
    @AppStorage("minimumFileSizeMB") private var minimumSizeMB = 50
    @AppStorage("skipSampleFiles") private var skipSamples = true
    @AppStorage(FileRenamer.defaultsKey) private var renameOnMatch = true
    @State private var showRenameAllConfirm = false

    var body: some View {
        Form {
            Section("Папки") {
                if store.roots.isEmpty {
                    Text("Папки не добавлены").foregroundStyle(.secondary)
                }
                ForEach(store.roots) { root in
                    HStack {
                        Text(root.displayPath)
                            .font(.callout)
                            .lineLimit(1)
                            .truncationMode(.head)
                        Spacer()
                        Button("Убрать", role: .destructive) { store.removeRoot(root) }
                            .buttonStyle(.borderless)
                    }
                }
                Button("Добавить папку…") { Task { await coordinator.addFolder() } }
            }

            Section {
                Picker("Не добавлять файлы мельче", selection: $minimumSizeMB) {
                    Text("без ограничения").tag(0)
                    Text("10 МБ").tag(10)
                    Text("50 МБ").tag(50)
                    Text("200 МБ").tag(200)
                }
                Toggle("Пропускать sample и трейлеры по имени", isOn: $skipSamples)
            } header: {
                Text("Что попадает в библиотеку")
            } footer: {
                Text("Вложенные папки обходятся на любую глубину. Если что-то не нашлось — чаще всего файл не прошёл по размеру. После изменения нажмите «Обновить библиотеку» (⌘R).")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Toggle("Переименовывать файлы по данным TMDB", isOn: $renameOnMatch)
                Button("Переименовать всё уже опознанное…") { showRenameAllConfirm = true }
                    .disabled(store.entries.allSatisfy { $0.tmdbID == nil })
            } header: {
                Text("Имена файлов")
            } footer: {
                Text("""
                     Фильм → «Название (Год).mkv»
                     Серия → «Сериал (Год) - S04E07 - Название серии.mkv»
                     Файлы переименовываются на диске в той же папке, без перемещений. \
                     Операция необратима — прежние имена не сохраняются.
                     """)
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Button("Пересобрать карточки из имён файлов") {
                    Task { await coordinator.rebuildFromFilenames() }
                }
            } header: {
                Text("Обслуживание")
            } footer: {
                Text("Перечитывает имена уже добавленных файлов текущим парсером и заново группирует их: серии одного сериала сливаются в одну карточку. Метаданные и прогресс просмотра сохраняются.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Кэш постеров") {
                LabeledContent("Занято на диске",
                               value: ByteCountFormatter.string(fromByteCount: cacheSize, countStyle: .file))
                Button("Очистить кэш") {
                    Task {
                        await ImageCache.shared.clear()
                        cacheSize = await ImageCache.shared.diskSize()
                    }
                }
            }

            Section("Данные") {
                LabeledContent("Карточек", value: "\(store.entries.count)")
                LabeledContent("Файлов", value: "\(store.entries.reduce(0) { $0 + $1.allFiles.count })")
                Button("Показать файл библиотеки в Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([LibraryStore.defaultURL()])
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .task { cacheSize = await ImageCache.shared.diskSize() }
        .confirmationDialog("Переименовать файлы на диске?",
                            isPresented: $showRenameAllConfirm) {
            Button("Переименовать", role: .destructive) {
                Task { await coordinator.renameAllMatched() }
            }
            Button("Отмена", role: .cancel) {}
        } message: {
            let count = store.entries.filter { $0.tmdbID != nil }.reduce(0) { $0 + $1.allFiles.count }
            Text("Будет затронуто файлов: \(count). Прежние имена не сохраняются.")
        }
    }
}

struct SyncSettings: View {
    @Environment(WatchSync.self) private var sync
    @Environment(LibraryStore.self) private var store
    @State private var importResult: String?

    var body: some View {
        @Bindable var sync = sync

        Form {
            Section {
                Toggle("Синхронизировать через iCloud", isOn: $sync.isEnabled)
                LabeledContent("Состояние", value: sync.statusText)
                HStack {
                    Button("Отправить сейчас") { sync.push() }
                        .disabled(!sync.isEnabled || !sync.isCloudAvailable)
                    Button("Забрать из iCloud") { sync.pull() }
                        .disabled(!sync.isEnabled || !sync.isCloudAvailable)
                }
            } header: {
                Text("iCloud")
            } footer: {
                Text("""
                     Синхронизируются только отметки о просмотре и позиции — сами файлы и папки остаются на этом Маке. \
                     При совпадении записей побеждает более свежая, а отметка «просмотрено» никогда не снимается автоматически.

                     Требуется вход в iCloud и подпись приложения с вашей учётной записью разработчика в Xcode. \
                     При подписи «для локального запуска» контейнер iCloud не выдаётся — используйте экспорт в файл ниже.
                     """)
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("Записей о просмотре", value: "\(store.watch.count)")
                HStack {
                    Button("Экспортировать в файл…") { exportToFile() }
                    Button("Импортировать из файла…") { importFromFile() }
                }
                if let importResult {
                    Text(importResult).font(.callout).foregroundStyle(.secondary)
                }
            } header: {
                Text("Резервная копия")
            } footer: {
                Text("Файл с историей просмотров работает всегда, без iCloud и учётной записи разработчика. Импорт сливает данные, а не заменяет их.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private func exportToFile() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = String(localized: "Lumiere-просмотрено.json")
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try sync.exportData().write(to: url, options: .atomic)
            importResult = String(localized: "Сохранено: \(url.lastPathComponent)")
        } catch {
            importResult = String(localized: "Не удалось сохранить: \(error.localizedDescription)")
        }
    }

    private func importFromFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let merged = try sync.importData(Data(contentsOf: url))
            importResult = merged > 0
                ? String(localized: "Добавлено или обновлено записей: \(merged)")
                : String(localized: "Новых записей не найдено — всё уже было в библиотеке")
        } catch {
            importResult = String(localized: "Не удалось прочитать файл: \(error.localizedDescription)")
        }
    }
}

struct PlaybackSettings: View {
    @AppStorage("rememberPosition") private var rememberPosition = true
    @AppStorage("autoPlayNext") private var autoPlayNext = true
    @AppStorage("resumeMinimumSeconds") private var resumeMinimum = 15
    @AppStorage("resumeRewindSeconds") private var resumeRewind = 8
    @AppStorage("videoAspectRatio") private var aspectRatio = ""
    @AppStorage("videoDeinterlace") private var deinterlace = ""
    @AppStorage("vlcFileCaching") private var fileCaching = 300
    @AppStorage("audioOutputDeviceID") private var audioDeviceID = 0
    @State private var devices: [AudioDevices.Device] = []

    var body: some View {
        Form {
            Section {
                LabeledContent("Движок", value: PlaybackBackend.vlcAvailable ? "VLC" : String(localized: "AVPlayer (системный)"))
            } header: {
                Text("Движок")
            } footer: {
                Text(PlaybackBackend.vlcAvailable
                     ? "Всё воспроизведение идёт через VLC — один движок для любых форматов, одинаковые дорожки и субтитры."
                     : "VLCKit не подключён, доступен только системный AVPlayer. MKV, AVI и MPEG-TS открываться не будут — см. README.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Toggle("Продолжать с места остановки", isOn: $rememberPosition)
                Toggle("Автоматически включать следующую серию", isOn: $autoPlayNext)
                Picker("Продолжать, если посмотрено больше", selection: $resumeMinimum) {
                    Text("5 секунд").tag(5)
                    Text("15 секунд").tag(15)
                    Text("30 секунд").tag(30)
                    Text("1 минуты").tag(60)
                }
                Picker("Отматывать назад при продолжении", selection: $resumeRewind) {
                    Text("не отматывать").tag(0)
                    Text("5 секунд").tag(5)
                    Text("8 секунд").tag(8)
                    Text("15 секунд").tag(15)
                }
            } header: {
                Text("Возобновление")
            } footer: {
                Text("Досмотренным файл считается на \(Int(WatchRules.finishedThreshold * 100))% длительности.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Picker("Устройство вывода", selection: $audioDeviceID) {
                    Text("Как в системе").tag(0)
                    ForEach(devices) { device in
                        Text(device.isDefault ? String(localized: "\(device.name) — системное") : device.name)
                            .tag(Int(device.id))
                    }
                }
                Button("Обновить список") { devices = AudioDevices.outputDevices() }
                    .font(.callout)
            } header: {
                Text("Звук")
            } footer: {
                Text("Звук пойдёт на выбранное устройство, даже если в системе выбрано другое. Применяется со следующего запуска файла. Если устройство отключить, приложение само вернётся к системному.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Picker("Пропорции по умолчанию", selection: $aspectRatio) {
                    Text("Как в источнике").tag("")
                    Text("16:9").tag("16:9")
                    Text("4:3").tag("4:3")
                    Text("21:9").tag("21:9")
                }
                Picker("Деинтерлейсинг", selection: $deinterlace) {
                    Text("Выключен").tag("")
                    Text("Blend").tag("blend")
                    Text("Bob").tag("bob")
                    Text("Yadif").tag("yadif")
                    Text("Yadif 2x").tag("yadif2x")
                }
                LabeledContent("Аппаратное декодирование", value: "VideoToolbox")
                Picker("Размер буфера", selection: $fileCaching) {
                    Text("минимальный (100 мс)").tag(100)
                    Text("обычный (300 мс)").tag(300)
                    Text("увеличенный (1 с)").tag(1000)
                    Text("максимальный (3 с)").tag(3000)
                }
            } header: {
                Text("Видеопоток")
            } footer: {
                Text("Деинтерлейсинг нужен для старых телезаписей с чересстрочной развёрткой. Буфер побольше помогает при чтении с сетевого диска — он задаётся при создании плеера и применяется со следующего запуска файла. Аппаратное декодирование на macOS всегда идёт через VideoToolbox: отключить его средствами VLC не удаётся, поэтому переключателя нет. Дорожки и задержки настраиваются прямо в плеере.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("Пробел", value: String(localized: "Пауза / продолжить"))
                LabeledContent("← →", value: String(localized: "Перемотка на 10 секунд"))
                LabeledContent("↑ ↓", value: String(localized: "Перемотка на минуту"))
                LabeledContent("N / P", value: String(localized: "Следующая / предыдущая серия"))
                LabeledContent("F", value: String(localized: "Весь экран"))
                LabeledContent("Esc", value: String(localized: "Выйти из полного экрана или закрыть плеер"))
                LabeledContent("⌘O", value: String(localized: "Добавить папку"))
                LabeledContent("⌘R", value: String(localized: "Обновить библиотеку"))
                LabeledContent("⇧⌘R", value: String(localized: "Пересобрать карточки из имён файлов"))
                LabeledContent("⌃⌘F", value: String(localized: "Весь экран (системное)"))
            } header: {
                Text("Горячие клавиши")
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}


/// Вкладка «Обновления»: тумблер автообновления и ручная проверка.
struct UpdateSettings: View {
    @Environment(Updater.self) private var updater
    @State private var isAutomatic = Updater.isAutomatic

    var body: some View {
        Form {
            Section {
                Toggle("Обновлять автоматически", isOn: $isAutomatic)
                    .onChange(of: isAutomatic) { _, value in Updater.isAutomatic = value }
                LabeledContent("Установлена версия", value: updater.currentVersion)
                LabeledContent("Состояние", value: updater.statusText)
                HStack {
                    Button("Проверить сейчас") {
                        Task { await updater.check(manual: true) }
                    }
                    .disabled(updater.isBusy)
                    if updater.isBusy { ProgressView().controlSize(.small) }
                    Spacer()
                    Button("Открыть страницу релизов") { updater.openReleasePage() }
                }
            } header: {
                Text("Обновления")
            } footer: {
                Text("""
                Приложение смотрит релизы на github.com/\(Updater.repository) при каждом запуске.
                С включённым тумблером новая версия скачивается сама и ждёт перезапуска — \
                установка идёт только по вашей кнопке, чтобы не прерывать просмотр. \
                С выключенным приложение просто сообщает, что вышла новая версия.
                """)
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(.vertical, 8)
    }
}
