import SwiftUI

@main
struct VideoClientApp: App {

    @State private var store: LibraryStore
    @State private var access: FolderAccess
    @State private var session: PlaybackSession
    @State private var coordinator: LibraryCoordinator
    @State private var sync: WatchSync
    @State private var downloads = DownloadManager()
    @State private var updater = Updater()

    init() {
        // Перенос данных из контейнера песочницы должен произойти до чтения библиотеки.
        LegacyMigration.run()
        let store = LibraryStore()
        let access = FolderAccess()
        let client = TMDBClient()
        _store = State(initialValue: store)
        _access = State(initialValue: access)
        _session = State(initialValue: PlaybackSession(store: store, access: access))
        _coordinator = State(initialValue: LibraryCoordinator(store: store, access: access, client: client))
        _sync = State(initialValue: WatchSync(store: store))
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(store)
                .environment(access)
                .environment(session)
                .environment(coordinator)
                .environment(sync)
                .environment(downloads)
                .environment(updater)
                .frame(minWidth: 940, minHeight: 620)
                .task {
                    // После загрузки сразу подхватываем новые файлы в библиотеку.
                    downloads.onFinished = { Task { await coordinator.rescanAll() } }
                    await updater.checkOnLaunch()
                }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1280, height: 820)
        .commands { menuCommands }

        Window("Проигрыватель", id: "player") {
            PlayerScreen()
                .environment(session)
                .environment(store)
                .frame(minWidth: 640, minHeight: 380)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1100, height: 640)

        Settings {
            SettingsView()
                .environment(store)
                .environment(coordinator)
                .environment(sync)
                .environment(updater)
        }
    }

    /// Меню приложения. Системные пункты (Файл, Правка, Окно) переводятся сами
    /// благодаря русской локализации бандла — здесь только наши команды.
    @CommandsBuilder
    private var menuCommands: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Добавить папку…") {
                Task { await coordinator.addFolder() }
            }
            .keyboardShortcut("o", modifiers: .command)

            Button("Обновить библиотеку") {
                Task { await coordinator.rescanAll() }
            }
            .keyboardShortcut("r", modifiers: .command)

            Divider()

            Button("Пересобрать карточки из имён файлов") {
                Task { await coordinator.rebuildFromFilenames() }
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])

            Button("Обновить метаданные на текущем языке") {
                Task { await coordinator.refreshMetadata() }
            }
            .keyboardShortcut("r", modifiers: [.command, .option])

            Button("Найти заставки в сериалах") {
                Task { await coordinator.detectIntrosInLibrary() }
            }
            .disabled(coordinator.isDetectingIntros)
        }

        // Поиск. ⌃F просили специально; ⌘F оставлен как привычный синоним.
        CommandGroup(after: .textEditing) {
            Divider()
            Button("Найти") {
                NotificationCenter.default.post(name: .focusSearch, object: false)
            }
            .keyboardShortcut("f", modifiers: .control)

            Button("Найти в TMDB") {
                NotificationCenter.default.post(name: .focusSearch, object: true)
            }
            .keyboardShortcut("f", modifiers: [.command, .shift])
        }

        CommandMenu("Воспроизведение") {
            Button(session.isPlaying ? "Пауза" : "Продолжить") {
                session.togglePlayPause()
            }
            .keyboardShortcut(.space, modifiers: [])
            .disabled(session.item == nil)

            Divider()

            Button("Назад на 10 секунд") { session.skip(-10) }
                .keyboardShortcut(.leftArrow, modifiers: [])
                .disabled(session.item == nil)
            Button("Вперёд на 10 секунд") { session.skip(10) }
                .keyboardShortcut(.rightArrow, modifiers: [])
                .disabled(session.item == nil)
            Button("Назад на минуту") { session.skip(-60) }
                .keyboardShortcut(.downArrow, modifiers: [])
                .disabled(session.item == nil)
            Button("Вперёд на минуту") { session.skip(60) }
                .keyboardShortcut(.upArrow, modifiers: [])
                .disabled(session.item == nil)

            Divider()

            Button("Предыдущая серия") { session.goToPreviousEpisode() }
                .keyboardShortcut("p", modifiers: [])
                .disabled(!session.canGoToPreviousEpisode)
            Button("Следующая серия") { session.goToNextEpisode() }
                .keyboardShortcut("n", modifiers: [])
                .disabled(!session.canGoToNextEpisode)

            Divider()

            Menu("Скорость") {
                ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { value in
                    Button(String(format: "%.2gx", value)) { session.setRate(Float(value)) }
                }
            }
            .disabled(session.item == nil)
        }

        // Пункт «Перейти в полноэкранный режим» система добавляет в меню «Вид» сама,
        // вместе с ⌃⌘F. Свой дубль с тем же сочетанием перехватывал команду
        // и полноэкранный режим переставал работать — поэтому его здесь нет.

        CommandGroup(after: .appInfo) {
            Button("Проверить обновления…") {
                Task { await updater.check(manual: true) }
            }
            .disabled(updater.isBusy)
        }

        CommandGroup(replacing: .help) {
            Button("Открыть TMDB") {
                if let url = URL(string: "https://www.themoviedb.org") {
                    NSWorkspace.shared.open(url)
                }
            }
        }
    }
}
