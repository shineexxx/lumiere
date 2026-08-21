import Foundation
import AppKit

/// Хранит и раздаёт доступ к пользовательским папкам через security-scoped bookmarks.
/// В песочнице URL сам по себе бесполезен — нужен bookmark, сохранённый при выборе папки.
@Observable
final class FolderAccess {

    /// Активные security-scoped ресурсы: rootID → URL, по которому вызван startAccessing.
    private var opened: [UUID: URL] = [:]

    /// Закрывает все открытые security-scoped ресурсы. Вызывается при выходе из приложения.
    func releaseAll() {
        for url in opened.values { url.stopAccessingSecurityScopedResource() }
        opened.removeAll()
    }

    /// Открывает системный диалог выбора папки и делает из неё LibraryRoot.
    func pickFolder() -> LibraryRoot? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "Добавить")
        panel.message = String(localized: "Выберите папку с фильмами или сериалами")
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        guard let bookmark = try? url.bookmarkData(options: .withSecurityScope,
                                                   includingResourceValuesForKeys: nil,
                                                   relativeTo: nil) else {
            log.error("Не удалось создать bookmark для \(url.path)")
            return nil
        }
        return LibraryRoot(displayPath: url.path, bookmark: bookmark)
    }

    /// Возвращает URL корня и, если нужно, начинает security-scoped доступ.
    /// Доступ держим открытым на всё время работы приложения — так проще, чем
    /// балансировать start/stop вокруг каждого чтения.
    @discardableResult
    func url(for root: LibraryRoot) -> URL? {
        if let existing = opened[root.id] { return existing }

        // Закладка разрешается только у того приложения, которое её создало.
        // После переименования (сменился идентификатор бандла) и выхода из песочницы
        // старые закладки перестали открываться — но вне песочницы они и не нужны.
        var stale = false
        if let url = try? URL(resolvingBookmarkData: root.bookmark,
                              options: .withSecurityScope,
                              relativeTo: nil,
                              bookmarkDataIsStale: &stale) {
            if url.startAccessingSecurityScopedResource() { opened[root.id] = url }
            if FileManager.default.isReadableFile(atPath: url.path) { return url }
        }

        // Запасной путь: обычный путь, сохранённый при добавлении папки.
        let direct = URL(fileURLWithPath: root.displayPath)
        guard FileManager.default.isReadableFile(atPath: direct.path) else {
            log.error("Папка недоступна: \(root.displayPath)")
            return nil
        }
        return direct
    }

    func release(_ root: LibraryRoot) {
        opened.removeValue(forKey: root.id)?.stopAccessingSecurityScopedResource()
    }

    /// Полный URL файла: корень + относительный путь.
    func fileURL(for file: VideoFileRef, roots: [LibraryRoot]) -> URL? {
        guard let root = roots.first(where: { $0.id == file.rootID }),
              let rootURL = url(for: root) else { return nil }
        return rootURL.appending(path: file.relativePath)
    }
}
