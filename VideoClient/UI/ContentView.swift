import SwiftUI

extension Notification.Name {
    /// Меню «Найти» просит окно поставить курсор в строку поиска.
    /// object == true означает «именно в общий поиск по TMDB».
    static let focusSearch = Notification.Name("LumiereFocusSearch")
}

enum LibraryFilter: Hashable, Identifiable {
    case home
    case continueWatching
    case discover
    case downloads
    case available
    case all
    case movies
    case shows
    case favorites
    case finished
    case needsMatch

    var id: Self { self }

    var title: String {
        switch self {
        case .home: String(localized: "Главная")
        case .continueWatching: String(localized: "Продолжить смотреть")
        case .discover: String(localized: "Новое и рекомендации")
        case .downloads: String(localized: "Загрузки")
        case .available: String(localized: "Доступно к просмотру")
        case .all: String(localized: "Вся библиотека")
        case .movies: String(localized: "Фильмы")
        case .shows: String(localized: "Сериалы")
        case .favorites: String(localized: "Избранное")
        case .finished: String(localized: "Просмотрено")
        case .needsMatch: String(localized: "Требуют уточнения")
        }
    }

    var symbol: String {
        switch self {
        case .home: "house"
        case .continueWatching: "play.circle"
        case .discover: "sparkles"
        case .downloads: "arrow.down.circle"
        case .available: "internaldrive"
        case .all: "square.grid.2x2"
        case .movies: "film"
        case .shows: "tv"
        case .favorites: "heart"
        case .finished: "checkmark.circle"
        case .needsMatch: "questionmark.circle"
        }
    }
}

enum SortOrder: String, CaseIterable, Identifiable {
    case recentlyAdded
    case title
    case year
    case rating

    var id: String { rawValue }

    var label: String {
        switch self {
        case .recentlyAdded: String(localized: "Недавно добавленные")
        case .title: String(localized: "По названию")
        case .year: String(localized: "По году")
        case .rating: String(localized: "По рейтингу")
        }
    }
}

struct ContentView: View {
    @Environment(LibraryStore.self) private var store
    @Environment(LibraryCoordinator.self) private var coordinator
    @Environment(PlaybackSession.self) private var session
    @Environment(Updater.self) private var updater
    @Environment(\.openWindow) private var openWindow

    @State private var filter: LibraryFilter = .home
    @State private var selection: UUID?
    /// Строка в правом верхнем углу — ищет по всему каталогу TMDB.
    @State private var globalQuery = ""
    /// Строка внутри раздела библиотеки — фильтрует только то, что уже добавлено.
    @State private var libraryQuery = ""
    /// Каждое нажатие ⌃F в разделе библиотеки увеличивает счётчик, и сетка
    /// ставит курсор в свою строку поиска.
    @State private var libraryFocusToken = 0
    @State private var sort: SortOrder = .recentlyAdded
    @State private var showingMatchSheet = false
    @State private var window: NSWindow?
    @State private var showingModelNotice = false

    @FocusState private var globalSearchFocused: Bool

    /// В этих разделах на экране обычная сетка библиотеки — значит, у поиска
    /// есть своя строка, и ⌃F должен вести туда.
    private var showsLibraryGrid: Bool {
        selection == nil
            && globalQuery.isEmpty
            && ![.home, .discover, .downloads].contains(filter)
            && !(store.roots.isEmpty && store.entries.isEmpty)
    }

    var body: some View {
        NavigationSplitView {
            SidebarView(filter: $filter)
                .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 300)
        } detail: {
            detailColumn
        }
        // Окна с .hiddenTitleBar не получают поддержку полноэкранного режима сами:
        // без fullScreenPrimary системные способы его включить (fn+F, ⌃⌘F,
        // пункт меню «Вид») просто ничего не делают.
        .background { WindowAccessor(window: $window).frame(width: 0, height: 0) }
        .searchable(text: $globalQuery, placement: .toolbar, prompt: "Поиск по всему TMDB")
        .searchFocused($globalSearchFocused)
        .toolbar { toolbarContent }
        // ⌃F из меню приходит сюда: в разделе библиотеки ведём в её собственную
        // строку, во всех остальных — в общий поиск по TMDB.
        .onReceive(NotificationCenter.default.publisher(for: .focusSearch)) { note in
            let wantsGlobal = (note.object as? Bool) ?? false
            if wantsGlobal || !showsLibraryGrid {
                globalSearchFocused = true
            } else {
                libraryFocusToken += 1
            }
        }
        .task {
            // Встроенная модель — необязательное улучшение разбора заголовков.
            // Если её нет, говорим об этом ровно один раз за всё время.
            TitleAI.shared.checkAvailability()
            if TitleAI.shared.shouldWarnUser { showingModelNotice = true }
        }
        .alert("Встроенная модель macOS недоступна", isPresented: $showingModelNotice) {
            Button("Понятно") { TitleAI.shared.markWarningShown() }
        } message: {
            Text(TitleAI.shared.unavailabilityMessage)
        }
        // Выбор раздела в сайдбаре закрывает открытую карточку —
        // иначе новый раздел оказывался бы «под» ней.
        .onChange(of: filter) { _, _ in
            selection = nil
        }
        .onChange(of: coordinator.pending.count) { _, count in
            if count > 0 { showingMatchSheet = true }
        }
        .onChange(of: session.isPresented) { _, presented in
            if presented { openWindow(id: "player") }
        }
        .sheet(isPresented: $showingMatchSheet) {
            MatchSheet()
                .environment(coordinator)
                .frame(minWidth: 780, minHeight: 560)
        }
        .alert("Что-то пошло не так",
               isPresented: Binding(get: { coordinator.lastError != nil },
                                    set: { if !$0 { coordinator.lastError = nil } })) {
            Button("Понятно", role: .cancel) { coordinator.lastError = nil }
        } message: {
            Text(coordinator.lastError ?? "")
        }
        // Сообщение об обновлении: что именно предлагаем — зависит от того,
        // успели ли мы уже скачать новую версию.
        .alert(updater.noticeTitle, isPresented: Bindable(updater).isNoticeVisible) {
            updateButtons
        } message: {
            Text(updater.noticeMessage)
        }
        // Ошибки воспроизведения показываем здесь: окно плеера в таких случаях
        // не открывается, и без этого пользователь не увидел бы ничего.
        .alert("Не удалось открыть видео",
               isPresented: Binding(get: { session.errorMessage != nil && !session.isPresented },
                                    set: { if !$0 { session.dismissError() } })) {
            if session.externalPlayerURL != nil {
                Button("Открыть во внешнем плеере") { session.openExternally() }
            }
            Button("Понятно", role: .cancel) { session.dismissError() }
        } message: {
            Text(session.errorMessage ?? "")
        }
    }

    @ViewBuilder
    private var updateButtons: some View {
        switch updater.phase {
        case .readyToInstall:
            Button("Перезапустить и обновить") { updater.installAndRestart() }
            Button("Позже", role: .cancel) {}
        case .available(let release):
            if release.asset != nil {
                Button("Обновить") { Task { await updater.download(release) } }
            }
            Button("Что нового") { updater.openReleasePage() }
            Button("Позже", role: .cancel) {}
        default:
            Button("Понятно", role: .cancel) {}
        }
    }

    @ViewBuilder
    private var detailColumn: some View {
        // Общий поиск важнее текущего раздела: набрал запрос — видишь выдачу.
        if !globalQuery.trimmingCharacters(in: .whitespaces).isEmpty {
            GlobalSearchView(query: globalQuery) { entry in
                globalQuery = ""
                selection = entry.id
            }
        } else if let selection, let entry = store.entry(id: selection) {
            DetailView(entry: entry, onBack: { self.selection = nil })
                .id(entry.id)
        } else if filter == .home {
            HomeView(onSelect: { selection = $0.id },
                     onOpenFilter: { filter = $0 })
        } else if filter == .discover {
            DiscoverView(onSelect: { selection = $0.id })
        } else if filter == .downloads {
            DownloadsView()
        } else if store.roots.isEmpty && store.entries.isEmpty {
            EmptyLibraryView()
        } else {
            LibraryGridView(entries: visibleEntries,
                            filter: filter,
                            query: $libraryQuery,
                            focusToken: libraryFocusToken,
                            onSelect: { selection = $0.id })
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            if selection != nil {
                Button {
                    selection = nil
                } label: {
                    Label("К библиотеке", systemImage: "chevron.left")
                }
                .help("Вернуться к библиотеке")
            }
        }

        ToolbarItem(placement: .principal) {
            if store.isBusy || coordinator.isMatching, let status = store.statusMessage {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(status).font(.callout).foregroundStyle(.secondary)
                }
            }
        }

        ToolbarItemGroup(placement: .primaryAction) {
            if !coordinator.pending.isEmpty {
                Button {
                    showingMatchSheet = true
                } label: {
                    Label("Подтвердить \(coordinator.pending.count)", systemImage: "questionmark.circle")
                }
                .help("Есть карточки, ожидающие подтверждения совпадения")
            }

            Menu {
                Picker("Сортировка", selection: $sort) {
                    ForEach(SortOrder.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.inline)
            } label: {
                Label("Сортировка", systemImage: "arrow.up.arrow.down")
            }

            Button {
                Task { await coordinator.addFolder() }
            } label: {
                Label("Добавить папку", systemImage: "folder.badge.plus")
            }
            .help("Добавить папку с видео (⌘O)")

            Button {
                Task { await coordinator.rescanAll() }
            } label: {
                Label("Обновить", systemImage: "arrow.clockwise")
            }
            .disabled(store.roots.isEmpty || store.isBusy)
            .help("Пересканировать папки (⌘R)")
        }
    }

    // MARK: - Выборка

    private var visibleEntries: [MediaEntry] {
        var items: [MediaEntry]
        switch filter {
        case .all: items = store.entries
        case .movies: items = store.entries.filter { $0.kind == .movie }
        case .shows: items = store.entries.filter { $0.kind == .show }
        case .favorites: items = store.entries.filter(\.isFavorite)
        case .finished: items = store.entries.filter { store.isFinished($0) }
        case .needsMatch: items = store.entries.filter { $0.matchState != .confirmed }
        case .continueWatching: items = store.continueWatching.map(\.entry)
        case .available: items = store.entries.filter(\.isAvailable)
        // Эти разделы рисуют свои витрины и через общую сетку не проходят.
        case .home, .discover, .downloads: items = store.entries
        }

        if !libraryQuery.isEmpty {
            let needle = LibraryScanner.normalizedKey(libraryQuery)
            items = items.filter {
                LibraryScanner.normalizedKey($0.displayTitle).contains(needle)
                    || LibraryScanner.normalizedKey($0.originalTitle ?? "").contains(needle)
            }
        }

        // «Продолжить смотреть» уже отсортировано по дате просмотра.
        guard filter != .continueWatching else { return items }

        switch sort {
        case .recentlyAdded: return items.sorted { $0.addedAt > $1.addedAt }
        case .title: return items.sorted { $0.displayTitle.localizedCompare($1.displayTitle) == .orderedAscending }
        case .year: return items.sorted { ($0.displayYear ?? 0) > ($1.displayYear ?? 0) }
        case .rating: return items.sorted { ($0.rating ?? 0) > ($1.rating ?? 0) }
        }
    }
}

struct EmptyLibraryView: View {
    @Environment(LibraryCoordinator.self) private var coordinator

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "film.stack")
                .font(.system(size: 56, weight: .thin))
                .foregroundStyle(.tertiary)
            Text("Библиотека пуста")
                .font(.title2.weight(.semibold))
            Text("Добавьте папку с фильмами или сериалами — приложение просканирует её\nи подтянет постеры, описания и рейтинги с TMDB.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button {
                Task { await coordinator.addFolder() }
            } label: {
                Label("Добавить папку", systemImage: "folder.badge.plus")
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
    }
}
