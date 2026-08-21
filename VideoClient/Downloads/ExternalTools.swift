import Foundation

/// Поиск внешних утилит, которыми пользуется загрузчик.
///
/// Приложение специально собирается без песочницы: из неё нельзя запустить
/// бинарник, лежащий вне бандла, а `yt-dlp` и `ffmpeg` ставятся через Homebrew
/// и обновляются пользователем независимо от приложения.
nonisolated enum ExternalTools {

    /// Где обычно лежат утилиты. PATH у приложения, запущенного из Finder,
    /// урезанный — на него полагаться нельзя.
    private static let searchPaths = [
        "/opt/homebrew/bin",     // Apple Silicon
        "/usr/local/bin",        // Intel и ручная установка
        "/opt/local/bin",        // MacPorts
        "/usr/bin",
    ]

    static func locate(_ name: String) -> URL? {
        for directory in searchPaths {
            let candidate = URL(fileURLWithPath: directory).appending(path: name)
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    static var ytDLP: URL? { locate("yt-dlp") }
    static var ffmpeg: URL? { locate("ffmpeg") }

    static var isReady: Bool { ytDLP != nil }

    /// Чего не хватает — текстом для пользователя.
    static var missingToolsMessage: String? {
        var missing: [String] = []
        if ytDLP == nil { missing.append("yt-dlp") }
        if ffmpeg == nil { missing.append("ffmpeg") }
        guard !missing.isEmpty else { return nil }
        return """
               Не найдено: \(missing.joined(separator: ", ")).

               Установите через Homebrew:
               brew install \(missing.joined(separator: " "))

               yt-dlp скачивает видео, ffmpeg склеивает видео- и аудиодорожки —
               без него качество ограничено тем, что отдаётся одним файлом.
               """
    }

    static func version(of tool: URL) -> String? {
        let process = Process()
        process.executableURL = tool
        process.arguments = ["--version"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "\n").first
            .map(String.init)
    }
}

/// Поддерживаемые источники. Определяем по адресу, чтобы подсказать пользователю,
/// что ссылка вообще подходит, ещё до запуска yt-dlp.
nonisolated enum VideoSource: String, CaseIterable {
    case vk
    case rutube
    case other

    var title: String {
        switch self {
        case .vk: "VK Видео"
        case .rutube: "Rutube"
        case .other: "другой источник"
        }
    }

    static func detect(_ text: String) -> VideoSource? {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              let host = url.host()?.lowercased() else { return nil }
        if host.contains("vk.com") || host.contains("vkvideo.ru") || host.contains("vk.ru") { return .vk }
        if host.contains("rutube.ru") { return .rutube }
        return url.scheme?.hasPrefix("http") == true ? .other : nil
    }

    /// Похоже ли на ссылку с несколькими видео: плейлист, альбом, сезон.
    static func looksLikePlaylist(_ text: String) -> Bool {
        let lowered = text.lowercased()
        return lowered.contains("playlist")
            || lowered.contains("/album")
            || lowered.contains("list=")
            || lowered.contains("/plst/")
    }
}
