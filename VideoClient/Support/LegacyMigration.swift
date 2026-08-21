import Foundation

/// Переносит данные приложения, оставшиеся от прежних имён и режимов работы.
///
/// История такая:
/// 1. Приложение звалось VideoClient и работало в песочнице — всё лежало
///    в `~/Library/Containers/com.arseny.VideoClient/Data/`.
/// 2. Песочницу пришлось снять, чтобы запускать yt-dlp из Homebrew, — данные
///    переехали в обычные папки пользователя, но под тем же именем VideoClient.
/// 3. Приложение переименовано в Lumière, а вместе с ним сменились имя папки
///    и идентификатор бандла (то есть и домен настроек).
///
/// Каждый шаг выполняется один раз и только если в новом месте ещё пусто,
/// поэтому повторный запуск ничего не портит.
nonisolated enum LegacyMigration {

    private static let doneKey = "didMigrateToLumiere"

    private static var home: URL { URL(fileURLWithPath: NSHomeDirectory()) }

    /// Где искать данные прежних версий — от самой старой к самой свежей.
    private static var legacyLibraryFiles: [URL] {
        [
            home.appending(path: "Library/Containers/com.arseny.VideoClient/Data/Library/Application Support/VideoClient/library.json"),
            home.appending(path: "Library/Application Support/VideoClient/library.json"),
        ]
    }

    private static var legacyPreferences: [URL] {
        [
            home.appending(path: "Library/Containers/com.arseny.VideoClient/Data/Library/Preferences/com.arseny.VideoClient.plist"),
            home.appending(path: "Library/Preferences/com.arseny.VideoClient.plist"),
        ]
    }

    static func run() {
        guard !UserDefaults.standard.bool(forKey: doneKey) else { return }

        // Настройки переносим первыми: библиотека при старте уже читает пороги оттуда.
        migrateDefaults()
        migrateLibraryFile()

        UserDefaults.standard.set(true, forKey: doneKey)
    }

    /// Значения из прежних настроек — только те, которых ещё нет в текущих,
    /// чтобы не затирать то, что пользователь успел поменять после перехода.
    private static func migrateDefaults() {
        let defaults = UserDefaults.standard
        var moved = 0

        // Идём от старого к новому: более свежие значения перекрывают древние.
        for plist in legacyPreferences {
            guard let stored = NSDictionary(contentsOf: plist) as? [String: Any] else { continue }
            for (key, value) in stored {
                // Служебные ключи системы переносить не нужно.
                guard !key.hasPrefix("NS"), !key.hasPrefix("Apple"), !key.hasPrefix("com.apple") else { continue }
                guard defaults.object(forKey: key) == nil else { continue }
                defaults.set(value, forKey: key)
                moved += 1
            }
        }
        if moved > 0 { log.info("Перенесено настроек из прежних версий: \(moved)") }
    }

    /// Библиотеку копируем, а не перемещаем: прежний файл остаётся резервной копией.
    private static func migrateLibraryFile() {
        let fm = FileManager.default
        let destination = LibraryStore.defaultURL()

        // Если библиотека уже на новом месте и непустая — ничего не трогаем.
        if let attributes = try? fm.attributesOfItem(atPath: destination.path),
           (attributes[.size] as? Int ?? 0) > 2 {
            return
        }

        // Берём самый свежий из найденных файлов прежних версий.
        guard let source = legacyLibraryFiles.last(where: { fm.fileExists(atPath: $0.path) }) else { return }

        do {
            try? fm.removeItem(at: destination)
            try fm.copyItem(at: source, to: destination)
            log.info("Библиотека перенесена из \(source.path)")
        } catch {
            log.error("Не удалось перенести библиотеку: \(error.localizedDescription)")
        }
    }
}
