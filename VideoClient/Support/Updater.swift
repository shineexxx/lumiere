import Foundation
import Observation
import AppKit

/// Проверяет GitHub Releases и ставит новую версию поверх текущей.
///
/// Sparkle не берём: она требует своей инфраструктуры подписи, а приложение
/// подписывается ad-hoc. Здесь ровно то, что нужно — тег последнего релиза,
/// сравнение версий и подмена бандла с перезапуском.
@Observable
@MainActor
final class Updater {

    /// Репозиторий, из которого берутся релизы.
    static let repository = "shineexxx/lumiere"

    /// Тумблер в настройках: качать обновление сразу или только сообщать о нём.
    static var isAutomatic: Bool {
        get { UserDefaults.standard.object(forKey: "autoUpdateEnabled") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "autoUpdateEnabled") }
    }

    nonisolated struct Release: Sendable, Equatable {
        var version: String
        var tag: String
        var notes: String
        var asset: URL?
        var page: URL
    }

    enum Phase: Equatable {
        case idle
        case checking
        /// Нашли новую версию, но качать не стали (тумблер выключен).
        case available(Release)
        case downloading(Double)
        /// Скачали и подготовили — осталось перезапустить.
        case readyToInstall(Release)
        case upToDate
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    /// Показывать ли окно с сообщением об обновлении.
    var isNoticeVisible = false

    /// Распакованная новая версия, ждущая перезапуска.
    private var stagedApp: URL?

    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    // MARK: - Проверка

    /// Тихая проверка при запуске: молчит, если всё свежее или сеть недоступна.
    func checkOnLaunch() async {
        await check(manual: false)
    }

    func check(manual: Bool) async {
        // Пока качаем — повторная проверка только мешала бы.
        if case .downloading = phase { return }
        await runCheck(manual: manual)
    }

    private func runCheck(manual: Bool) async {
        phase = .checking
        do {
            guard let release = try await latestRelease() else {
                phase = .upToDate
                if manual { isNoticeVisible = true }
                return
            }
            log.info("Доступна версия \(release.version) (сейчас \(self.currentVersion))")
            if Self.isAutomatic, release.asset != nil {
                await download(release)
            } else {
                phase = .available(release)
                isNoticeVisible = true
            }
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            log.error("Проверка обновлений не удалась: \(message)")
            phase = .failed(message)
            if manual { isNoticeVisible = true }
        }
    }

    /// Последний релиз, если он новее текущей версии.
    private func latestRelease() async throws -> Release? {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(Self.repository)/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 20
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw UpdateError.badResponse(code)
        }
        let payload = try JSONDecoder().decode(GitHubRelease.self, from: data)
        guard !payload.draft, !payload.prerelease else { return nil }

        let version = payload.tag_name.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
        guard Self.isNewer(version, than: currentVersion) else { return nil }

        // Нужен zip с приложением; всё остальное в релизе нас не интересует.
        let asset = payload.assets.first { $0.name.hasSuffix(".zip") }
        return Release(version: version,
                       tag: payload.tag_name,
                       notes: payload.body ?? "",
                       asset: asset.flatMap { URL(string: $0.browser_download_url) },
                       page: URL(string: payload.html_url)!)
    }

    /// Сравнение версий по числам: 1.10.0 новее, чем 1.9.9.
    nonisolated static func isNewer(_ candidate: String, than current: String) -> Bool {
        let left = candidate.split(separator: ".").map { Int($0.filter(\.isNumber)) ?? 0 }
        let right = current.split(separator: ".").map { Int($0.filter(\.isNumber)) ?? 0 }
        for index in 0..<max(left.count, right.count) {
            let a = index < left.count ? left[index] : 0
            let b = index < right.count ? right[index] : 0
            if a != b { return a > b }
        }
        return false
    }

    // MARK: - Загрузка и установка

    func download(_ release: Release) async {
        guard let asset = release.asset else {
            phase = .available(release)
            isNoticeVisible = true
            return
        }
        phase = .downloading(0)
        do {
            let archive = try await downloadFile(from: asset)
            defer { try? FileManager.default.removeItem(at: archive) }
            let app = try unpack(archive)
            try validate(app)
            stagedApp = app
            phase = .readyToInstall(release)
            isNoticeVisible = true
            log.info("Обновление \(release.version) распаковано и ждёт перезапуска")
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            log.error("Не удалось поставить обновление: \(message)")
            phase = .failed(message)
            isNoticeVisible = true
        }
    }

    private func downloadFile(from url: URL) async throws -> URL {
        let (temporary, response) = try await URLSession.shared.download(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw UpdateError.badResponse((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("Lumiere-update-\(UUID().uuidString).zip")
        try FileManager.default.moveItem(at: temporary, to: destination)
        return destination
    }

    /// Распаковывает архив релиза и возвращает путь к .app внутри.
    private func unpack(_ archive: URL) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Lumiere-update-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", archive.path, directory.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw UpdateError.unpackFailed }

        let contents = (try? FileManager.default.contentsOfDirectory(at: directory,
                                                                     includingPropertiesForKeys: nil)) ?? []
        guard let app = contents.first(where: { $0.pathExtension == "app" }) else {
            throw UpdateError.noAppInArchive
        }
        return app
    }

    /// Проверяем, что скачали именно наше приложение, а не что-то постороннее.
    private func validate(_ app: URL) throws {
        let plist = app.appending(path: "Contents/Info.plist")
        guard let data = try? Data(contentsOf: plist),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let identifier = info["CFBundleIdentifier"] as? String,
              identifier == Bundle.main.bundleIdentifier else {
            throw UpdateError.foreignBundle
        }
    }

    /// Подменяет бандл и перезапускает приложение.
    ///
    /// Своими руками себя не переписать: пока процесс жив, файлы бандла заняты.
    /// Поэтому подмену делает отдельный скрипт, который ждёт нашего выхода.
    func installAndRestart() {
        guard let staged = stagedApp else { return }
        let current = Bundle.main.bundleURL
        let script = FileManager.default.temporaryDirectory
            .appendingPathComponent("lumiere-update-\(UUID().uuidString).sh")

        let body = Self.installScript(pid: ProcessInfo.processInfo.processIdentifier,
                                      current: current,
                                      staged: staged)
        do {
            try body.write(to: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = [script.path]
            try process.run()
        } catch {
            log.error("Не удалось запустить установщик: \(error.localizedDescription)")
            phase = .failed("Не удалось подменить приложение: \(error.localizedDescription)")
            isNoticeVisible = true
            return
        }
        NSApp.terminate(nil)
    }

    /// Скрипт подмены. Вынесен отдельно, чтобы его можно было прогнать на копии
    /// приложения, а не проверять сразу на живом.
    nonisolated static func installScript(pid: Int32, current: URL, staged: URL) -> String {
        """
        #!/bin/bash
        # Ждём, пока приложение закроется и отпустит свои файлы.
        while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done
        set -e
        rm -rf "\(current.path)"
        /usr/bin/ditto "\(staged.path)" "\(current.path)"
        /usr/bin/xattr -dr com.apple.quarantine "\(current.path)" 2>/dev/null || true
        /usr/bin/codesign --force --deep --sign - "\(current.path)" 2>/dev/null || true
        /usr/bin/open "\(current.path)"
        rm -rf "\(staged.deletingLastPathComponent().path)"
        rm -f "$0"
        """
    }

    func openReleasePage() {
        let url: URL
        switch phase {
        case .available(let release), .readyToInstall(let release): url = release.page
        default: url = URL(string: "https://github.com/\(Self.repository)/releases/latest")!
        }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Тексты для интерфейса

    var noticeTitle: String {
        switch phase {
        case .available(let release): "Доступна версия \(release.version)"
        case .readyToInstall(let release): "Версия \(release.version) готова к установке"
        case .upToDate: "Установлена последняя версия"
        case .failed: "Не удалось проверить обновления"
        default: "Обновление"
        }
    }

    var noticeMessage: String {
        switch phase {
        case .available(let release):
            let notes = release.notes.trimmingCharacters(in: .whitespacesAndNewlines)
            return notes.isEmpty ? "Сейчас установлена \(currentVersion)." : notes
        case .readyToInstall:
            return "Приложение перезапустится и откроется уже в новой версии."
        case .upToDate:
            return "Версия \(currentVersion) — свежее пока нет."
        case .failed(let message):
            return message
        default:
            return ""
        }
    }

    var statusText: String {
        switch phase {
        case .idle: "Ещё не проверялось"
        case .checking: "Проверяю…"
        case .available(let release): "Доступна версия \(release.version)"
        case .downloading: "Качаю обновление…"
        case .readyToInstall(let release): "Версия \(release.version) ждёт перезапуска"
        case .upToDate: "Последняя версия"
        case .failed(let message): message
        }
    }

    var isBusy: Bool {
        switch phase {
        case .checking, .downloading: true
        default: false
        }
    }
}

nonisolated enum UpdateError: LocalizedError {
    case badResponse(Int)
    case unpackFailed
    case noAppInArchive
    case foreignBundle

    var errorDescription: String? {
        switch self {
        case .badResponse(let code) where code == 404:
            "Релизов пока нет — GitHub ответил 404."
        case .badResponse(let code):
            "GitHub ответил кодом \(code)."
        case .unpackFailed:
            "Архив с обновлением не распаковался."
        case .noAppInArchive:
            "В архиве нет приложения."
        case .foreignBundle:
            "В архиве другое приложение — установка отменена."
        }
    }
}

/// Ответ GitHub API. Только те поля, которые используем.
nonisolated struct GitHubRelease: Decodable {
    struct Asset: Decodable {
        var name: String
        var browser_download_url: String
    }
    var tag_name: String
    var html_url: String
    var body: String?
    var draft: Bool
    var prerelease: Bool
    var assets: [Asset]
}
