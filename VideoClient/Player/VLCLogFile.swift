import Foundation

#if canImport(VLCKit)
import VLCKit

/// Пишет журнал libVLC в файл рядом с остальными логами приложения.
///
/// Нужен не для красоты: 2 августа 2026 приложение упало внутри вывода видео
/// VLC (assert `GL_OUT_OF_MEMORY` в vout_helper.c) — воспроизвести это на стенде
/// не удалось, а из отчёта о падении видно только сам assert. Файл рядом
/// позволяет в следующий раз увидеть, что libVLC делал за секунды до падения.
enum VLCLogFile {

    /// ~/Library/Logs/Lumiere/vlc.log
    static var url: URL {
        let directory = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/Lumiere", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("vlc.log")
    }

    private static var handle: FileHandle?

    /// Подключает файловый логгер к экземпляру библиотеки VLC.
    /// Уровень — предупреждения и ошибки: полный debug пишет десятки мегабайт за фильм.
    static func attach(to library: VLCLibrary?) {
        guard let library else { return }
        guard let handle = sharedHandle() else { return }
        let logger = VLCFileLogger(fileHandle: handle)
        logger.level = .warning
        library.loggers = [logger]
    }

    private static func sharedHandle() -> FileHandle? {
        if let handle { return handle }
        let url = url
        // Файл держим маленьким: интересны последние минуты, а не вся история.
        if let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int,
           size > 4_000_000 {
            try? FileManager.default.removeItem(at: url)
        }
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        guard let opened = try? FileHandle(forWritingTo: url) else { return nil }
        opened.seekToEndOfFile()
        handle = opened
        return opened
    }
}
#endif
