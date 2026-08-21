import Foundation
import Observation

/// Синхронизация отметок о просмотре между устройствами через iCloud.
///
/// Используем NSUbiquitousKeyValueStore: истории просмотров — это компактные записи
/// (идентификатор → позиция и флаг), их объём укладывается в лимит хранилища,
/// а настройка не требует схемы и серверной части.
///
/// Слияние — по времени последнего просмотра: выигрывает более свежая запись.
/// Так ничего не теряется, даже если смотрели на двух устройствах параллельно.
@Observable
@MainActor
final class WatchSync {

    static let defaultsKey = "iCloudWatchSync"
    /// iCloud KV-хранилище ограничено 1 МБ на всё; следим, чтобы не упереться.
    private static let payloadKey = "watchStates.v2"
    private static let sizeLimit = 900_000

    enum Status: Equatable {
        case off
        case unavailable(String)
        case idle
        case syncing
        case synced(Date)
        case failed(String)
    }

    private(set) var status: Status = .off
    private(set) var lastMergedCount = 0

    var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: Self.defaultsKey)
            if isEnabled { start() } else { stop() }
        }
    }

    private unowned let store: LibraryStore
    private let cloud = NSUbiquitousKeyValueStore.default
    private var observer: NSObjectProtocol?
    private var pushTask: Task<Void, Never>?

    init(store: LibraryStore) {
        self.store = store
        self.isEnabled = UserDefaults.standard.bool(forKey: Self.defaultsKey)
        if isEnabled { start() }
        store.onWatchChanged = { [weak self] in self?.schedulePush() }
    }

    /// Отправку откладываем: во время просмотра прогресс меняется каждую секунду,
    /// и слать это в облако с той же частотой незачем.
    func schedulePush() {
        guard isEnabled, isCloudAvailable else { return }
        pushTask?.cancel()
        pushTask = Task {
            try? await Task.sleep(for: .seconds(20))
            guard !Task.isCancelled else { return }
            push()
        }
    }

    /// Доступен ли iCloud. Мало войти в учётную запись — приложению нужно право
    /// на KV-хранилище, а оно выдаётся только при подписи с командой разработчика.
    /// synchronize() возвращает false, когда права нет, — на это и опираемся.
    var isCloudAvailable: Bool {
        FileManager.default.ubiquityIdentityToken != nil && cloud.synchronize()
    }

    /// Почему синхронизация недоступна — текстом для настроек.
    var unavailabilityReason: String? {
        if FileManager.default.ubiquityIdentityToken == nil {
            return String(localized: "Не выполнен вход в iCloud на этом Маке.")
        }
        if !cloud.synchronize() {
            return String(localized: "Приложение собрано с подписью «для локального запуска», поэтому доступа к iCloud нет. Выберите свою команду разработчика в Xcode и подключите права из Lumiere-iCloud.entitlements — или пользуйтесь экспортом в файл, он работает всегда.")
        }
        return nil
    }

    // MARK: - Жизненный цикл

    func start() {
        guard isEnabled else { return }
        if let reason = unavailabilityReason {
            status = .unavailable(reason)
            return
        }
        observer = NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: cloud,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.pull() }
        }
        cloud.synchronize()
        pull()
        status = .idle
    }

    func stop() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        status = .off
    }

    // MARK: - Обмен

    /// Забирает данные из облака и сливает с локальными.
    func pull() {
        guard isEnabled, isCloudAvailable else { return }
        guard let data = cloud.data(forKey: Self.payloadKey) else {
            status = .idle
            return
        }
        do {
            let remote = try JSONDecoder.videoClient.decode([UUID: WatchState].self, from: data)
            lastMergedCount = store.mergeWatch(remote)
            status = .synced(Date())
        } catch {
            status = .failed(String(localized: "Не удалось прочитать данные из iCloud: \(error.localizedDescription)"))
        }
    }

    /// Отправляет локальные данные в облако (предварительно слив с удалёнными).
    func push() {
        guard isEnabled, isCloudAvailable else { return }
        status = .syncing
        // Сначала подтягиваем чужие изменения, чтобы не затереть их своей записью.
        pull()
        do {
            let data = try JSONEncoder.videoClient.encode(store.watch)
            guard data.count < Self.sizeLimit else {
                status = .failed(String(localized: "История просмотров переросла лимит iCloud (1 МБ). Синхронизация приостановлена — воспользуйтесь экспортом в файл."))
                return
            }
            cloud.set(data, forKey: Self.payloadKey)
            cloud.synchronize()
            status = .synced(Date())
        } catch {
            status = .failed(String(localized: "Не удалось отправить данные в iCloud: \(error.localizedDescription)"))
        }
    }

    // MARK: - Экспорт и импорт

    /// Файл с историей просмотров — работает всегда, независимо от iCloud.
    func exportData() throws -> Data {
        try JSONEncoder.videoClient.encode(store.watch)
    }

    @discardableResult
    func importData(_ data: Data) throws -> Int {
        let imported = try JSONDecoder.videoClient.decode([UUID: WatchState].self, from: data)
        let merged = store.mergeWatch(imported)
        lastMergedCount = merged
        return merged
    }

    var statusText: String {
        switch status {
        case .off: String(localized: "Выключена")
        case .unavailable(let reason): reason
        case .idle: String(localized: "Готова к синхронизации")
        case .syncing: String(localized: "Синхронизация…")
        case .synced(let date): String(localized: "Синхронизировано в \(date.formatted(date: .omitted, time: .shortened))")
        case .failed(let message): message
        }
    }
}
