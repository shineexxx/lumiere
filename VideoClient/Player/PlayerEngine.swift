import Foundation
import SwiftUI

/// Абстракция над движком воспроизведения, чтобы AVFoundation и VLC были взаимозаменяемы.
@MainActor
protocol PlayerEngine: AnyObject {
    var currentTime: Double { get }
    var duration: Double { get }
    var isPlaying: Bool { get }

    func load(url: URL, startAt: Double)
    func play()
    func pause()
    func seek(to seconds: Double)
    func setRate(_ rate: Float)
    func setVolume(_ volume: Float)
    func teardown()

    /// Вызывается примерно раз в секунду — используется для сохранения позиции.
    var onTimeUpdate: ((Double, Double) -> Void)? { get set }
    /// Файл доигран до конца.
    var onFinished: (() -> Void)? { get set }
    /// Движок не смог открыть файл.
    var onFailure: ((String) -> Void)? { get set }
    /// Воспроизведение началось или встало на паузу — в том числе не по нашей команде.
    var onPlayingChanged: ((Bool) -> Void)? { get set }
}

nonisolated enum PlaybackBackend: String, CaseIterable, Identifiable, Codable {
    case av
    case vlc

    var id: String { rawValue }

    var title: String {
        switch self {
        case .av: "AVPlayer (системный)"
        case .vlc: "VLC"
        }
    }

    static var vlcAvailable: Bool {
        #if canImport(VLCKit)
        return true
        #else
        return false
        #endif
    }
}

nonisolated enum PlaybackSupport {
    /// Контейнеры, которые AVFoundation штатно не открывает.
    static let unsupportedByAV: Set<String> = ["mkv", "avi", "wmv", "flv", "webm", "ogv", "vob", "divx", "3gp", "ts", "m2ts", "mpg", "mpeg"]

    /// Формат контейнера, определённый по содержимому файла.
    /// Расширению верить нельзя: рипы сплошь и рядом лежат в «.mp4»,
    /// внутри которого на самом деле MPEG-TS или Matroska.
    enum Container {
        case mp4
        case matroska
        case avi
        case mpegTS
        case flv
        case unknown

        var playableByAV: Bool { self == .mp4 }

        var name: String {
            switch self {
            case .mp4: "MP4/MOV"
            case .matroska: "Matroska (MKV)"
            case .avi: "AVI"
            case .mpegTS: "MPEG-TS"
            case .flv: "FLV"
            case .unknown: "неизвестный формат"
            }
        }
    }

    /// Читает сигнатуру в начале файла. Дёшево: несколько сотен байт.
    static func detectContainer(at url: URL) -> Container {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return .unknown }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 1024), data.count >= 12 else { return .unknown }
        let bytes = [UInt8](data)

        // Matroska/WebM: EBML-заголовок.
        if bytes.starts(with: [0x1A, 0x45, 0xDF, 0xA3]) { return .matroska }
        // AVI: RIFF....AVI␣
        if bytes.starts(with: [0x52, 0x49, 0x46, 0x46]),
           bytes.count >= 12, Array(bytes[8..<12]) == [0x41, 0x56, 0x49, 0x20] { return .avi }
        // FLV
        if bytes.starts(with: [0x46, 0x4C, 0x56]) { return .flv }
        // MPEG-TS: пакеты по 188 байт, каждый начинается с 0x47.
        if bytes[0] == 0x47, bytes.count > 188, bytes[188] == 0x47 { return .mpegTS }
        // MP4/MOV: box-заголовок на 4-м байте.
        if bytes.count >= 8 {
            let box = String(decoding: bytes[4..<8], as: UTF8.self)
            if ["ftyp", "moov", "mdat", "free", "skip", "wide", "pnot"].contains(box) { return .mp4 }
        }
        return .unknown
    }

    /// Движок один — VLC, если он собран в приложение. Так поведение предсказуемо:
    /// одинаковые контролы, дорожки и субтитры для любого файла.
    /// AVPlayer остаётся только запасным вариантом для сборки без VLCKit.
    static func recommendedBackend(for file: VideoFileRef,
                                   url: URL?,
                                   preferred: PlaybackBackend) -> PlaybackBackend {
        PlaybackBackend.vlcAvailable ? .vlc : .av
    }

    /// Можно ли вообще открыть файл имеющимися средствами.
    static func canPlay(_ file: VideoFileRef, url: URL? = nil) -> Bool {
        if PlaybackBackend.vlcAvailable { return true }
        if let url { return detectContainer(at: url).playableByAV }
        return !unsupportedByAV.contains(file.fileExtension)
    }

    /// Причина, по которой файл не откроется. nil — всё в порядке.
    /// Показывается вместо пустого окна плеера.
    static func blockingReason(for file: VideoFileRef, url: URL? = nil) -> String? {
        guard !canPlay(file, url: url) else { return nil }
        let format = url.map { detectContainer(at: $0).name } ?? ".\(file.fileExtension)"
        return """
               Формат «\(format)» не поддерживается встроенным плеером macOS.

               Файл: \(file.fileName)

               Что можно сделать:
               • Открыть файл во внешнем плеере (например, VLC) — кнопка ниже
               • Подключить VLCKit к приложению, тогда такие файлы будут открываться здесь
               • Сконвертировать файл в .mp4 или .m4v
               """
    }
}
