import Accelerate
import Foundation

/// Поиск заставок сериала по звуку.
///
/// Заставка в каждой серии — это буквально один и тот же звук, поэтому её можно
/// найти, не понимая содержания: достаточно сравнить серии между собой и взять
/// участок, где звук совпадает. Речь и «в предыдущих сериях» у серий разные,
/// поэтому они под совпадение не попадают.
nonisolated enum AudioFingerprint {

    // 11025 Гц, окно 2048 отсчётов, шаг 512 — примерно 21,5 кадра в секунду.
    static let sampleRate = 11025
    static let windowSize = 2048
    static let hopSize = 256
    static var secondsPerFrame: Double { Double(hopSize) / Double(sampleRate) }

    /// Полосы, по которым берём энергию: 300–4000 Гц, логарифмическая сетка.
    /// Ниже 300 Гц — гул, выше 4000 Гц — то, что первым портится при сжатии.
    static let bandCount = 32

    // MARK: - Декодирование

    /// Достаёт из файла первые `seconds` секунд звука: моно, 11 кГц, без видео.
    static func decode(path: String, seconds: Int) throws -> [Float] {
        guard let ffmpeg = ExternalTools.ffmpeg else { throw IntroError.noFFmpeg }
        let process = Process()
        process.executableURL = ffmpeg
        process.arguments = [
            "-v", "error", "-i", path,
            "-t", String(seconds),
            "-vn", "-ac", "1", "-ar", String(sampleRate),
            "-f", "s16le", "-",
        ]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()

        var data = Data()
        while true {
            let chunk = pipe.fileHandleForReading.availableData
            if chunk.isEmpty { break }
            data.append(chunk)
        }
        process.waitUntilExit()

        return data.withUnsafeBytes { raw -> [Float] in
            let samples = raw.bindMemory(to: Int16.self)
            var result = [Float](repeating: 0, count: samples.count)
            for index in 0..<samples.count {
                result[index] = Float(samples[index]) / 32768
            }
            return result
        }
    }

    // MARK: - Отпечаток

    /// Границы полос в номерах спектральных корзин.
    private static let bandEdges: [Int] = {
        let low = 300.0, high = 4000.0
        let binWidth = Double(sampleRate) / Double(windowSize)
        return (0...bandCount).map { index in
            let ratio = Double(index) / Double(bandCount)
            let frequency = low * pow(high / low, ratio)
            return max(1, Int(frequency / binWidth))
        }
    }()

    /// Один кадр — 32 бита. Бит показывает, как изменилась разница энергий
    /// соседних полос по сравнению с прошлым кадром: такой признак не зависит
    /// ни от громкости, ни от общего тембра.
    static func compute(samples: [Float]) -> [UInt32] {
        guard samples.count > windowSize else { return [] }
        let log2n = vDSP_Length(log2(Float(windowSize)))
        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return [] }
        defer { vDSP_destroy_fftsetup(setup) }

        var window = [Float](repeating: 0, count: windowSize)
        vDSP_hann_window(&window, vDSP_Length(windowSize), Int32(vDSP_HANN_NORM))

        let frameCount = (samples.count - windowSize) / hopSize
        var previous = [Float](repeating: 0, count: bandCount)
        var fingerprints: [UInt32] = []
        fingerprints.reserveCapacity(frameCount)

        var real = [Float](repeating: 0, count: windowSize / 2)
        var imaginary = [Float](repeating: 0, count: windowSize / 2)
        var magnitudes = [Float](repeating: 0, count: windowSize / 2)
        var windowed = [Float](repeating: 0, count: windowSize)

        for frame in 0..<frameCount {
            let start = frame * hopSize
            vDSP_vmul(Array(samples[start..<start + windowSize]), 1, window, 1, &windowed, 1, vDSP_Length(windowSize))

            real.withUnsafeMutableBufferPointer { realPtr in
                imaginary.withUnsafeMutableBufferPointer { imagPtr in
                    var split = DSPSplitComplex(realp: realPtr.baseAddress!, imagp: imagPtr.baseAddress!)
                    windowed.withUnsafeBufferPointer { input in
                        input.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: windowSize / 2) {
                            vDSP_ctoz($0, 2, &split, 1, vDSP_Length(windowSize / 2))
                        }
                    }
                    vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                    vDSP_zvmags(&split, 1, &magnitudes, 1, vDSP_Length(windowSize / 2))
                }
            }

            // Энергия по полосам.
            var energies = [Float](repeating: 0, count: bandCount)
            for band in 0..<bandCount {
                let from = bandEdges[band], to = min(bandEdges[band + 1], magnitudes.count)
                guard to > from else { continue }
                var sum: Float = 0
                vDSP_sve(Array(magnitudes[from..<to]), 1, &sum, vDSP_Length(to - from))
                energies[band] = log10f(sum + 1e-9)
            }

            var bits: UInt32 = 0
            if frame > 0 {
                for band in 0..<(bandCount - 1) {
                    let now = energies[band] - energies[band + 1]
                    let before = previous[band] - previous[band + 1]
                    if now - before > 0 { bits |= (1 << UInt32(band)) }
                }
            }
            previous = energies
            fingerprints.append(bits)
        }
        return fingerprints
    }

    // MARK: - Сверка двух серий

    struct Segment {
        /// Кадры, а не секунды: в секунды переводим на выходе.
        var startInA: Int
        var startInB: Int
        var length: Int
        var errorRate: Double

        var seconds: (start: Double, end: Double) {
            (Double(startInA) * secondsPerFrame, Double(startInA + length) * secondsPerFrame)
        }
    }

    /// Ищет самый длинный участок, где звук двух серий совпадает.
    ///
    /// Точные совпадения отпечатков брать нельзя: заставка в разных сериях
    /// начинается в произвольном месте, окна не совпадают по фазе, и биты
    /// расходятся даже у одного и того же звука. Поэтому идём в лоб — считаем
    /// ошибку по битам для всех сдвигов, но сначала на прореженных отпечатках,
    /// а найденные кандидаты уточняем на полном разрешении.
    static func commonSegment(_ a: [UInt32], _ b: [UInt32],
                              minimumSeconds: Double = 15,
                              maximumErrorRate: Double = 0.34) -> Segment? {
        guard !a.isEmpty, !b.isEmpty else { return nil }

        let stride = 4
        let coarseA = Swift.stride(from: 0, to: a.count, by: stride).map { a[$0] }
        let coarseB = Swift.stride(from: 0, to: b.count, by: stride).map { b[$0] }

        // Грубый проход. Сдвиг оцениваем не средней ошибкой по всему перекрытию —
        // заставка в полминуты внутри двенадцати минут среднее почти не двигает,
        // и верный сдвиг тонет среди случайных. Берём лучшее окно: минимальную
        // ошибку на отрезке длиной с искомую заставку.
        let windowFrames = max(4, Int(minimumSeconds / secondsPerFrame) / stride)
        var scored: [(offset: Int, error: Double)] = []
        let minimumCoarse = windowFrames
        for offset in -(coarseB.count - minimumCoarse)...(coarseA.count - minimumCoarse) {
            let from = max(0, offset)
            let to = min(coarseA.count, coarseB.count + offset)
            guard to - from >= windowFrames else { continue }

            var windowSum = 0
            var minimumSum = Int.max
            for indexA in from..<to {
                windowSum += (coarseA[indexA] ^ coarseB[indexA - offset]).nonzeroBitCount
                if indexA - from >= windowFrames {
                    let leaving = indexA - windowFrames
                    windowSum -= (coarseA[leaving] ^ coarseB[leaving - offset]).nonzeroBitCount
                }
                if indexA - from >= windowFrames - 1 {
                    minimumSum = min(minimumSum, windowSum)
                }
            }
            guard minimumSum != Int.max else { continue }
            scored.append((offset, Double(minimumSum) / Double(windowFrames * 32)))
        }
        guard !scored.isEmpty else { return nil }

        // На полном разрешении проверяем два десятка лучших сдвигов.
        // Грубый проход знает сдвиг с точностью до шага прореживания, а на полном
        // разрешении даже четверть кадра расфазировки поднимает ошибку по битам.
        // Поэтому вокруг каждого кандидата проверяем соседние сдвиги.
        let coarseCandidates = scored.sorted { $0.error < $1.error }.prefix(12).map { $0.offset * stride }
        let candidates = coarseCandidates.flatMap { base in
            (-stride...stride).map { base + $0 }
        }
        let minimumFrames = Int(minimumSeconds / secondsPerFrame)
        let smoothing = Int(1.0 / secondsPerFrame)
        var best: Segment?

        for offset in candidates {
            let from = max(0, offset)
            let to = min(a.count, b.count + offset)
            guard to - from > minimumFrames else { continue }

            // Ошибка по битам, сглаженная секундным окном, по всему перекрытию.
            var smoothed = [Double](repeating: 1, count: to - from)
            var windowSum = 0.0
            for indexA in from..<to {
                let local = indexA - from
                windowSum += Double((a[indexA] ^ b[indexA - offset]).nonzeroBitCount) / 32
                if local >= smoothing {
                    windowSum -= Double((a[indexA - smoothing] ^ b[indexA - smoothing - offset]).nonzeroBitCount) / 32
                }
                if local >= smoothing - 1 {
                    smoothed[local - smoothing + 1] = windowSum / Double(smoothing)
                }
            }

            // Ядро: самый длинный отрезок со строгим порогом.
            var run = 0, runStart = 0, coreStart = -1, coreLength = 0
            for local in 0..<smoothed.count {
                if smoothed[local] < maximumErrorRate {
                    if run == 0 { runStart = local }
                    run += 1
                    if run > coreLength { coreLength = run; coreStart = runStart }
                } else {
                    run = 0
                }
            }
            guard coreLength > minimumFrames else { continue }

            // Расширение. У заставки края всегда хуже середины: там наложены
            // концовка предыдущей сцены и первые реплики. Поэтому от ядра
            // расходимся с мягким порогом, разрешая короткие провалы.
            let looseRate = maximumErrorRate + 0.08
            let allowedGap = Int(2.0 / secondsPerFrame)
            var start = coreStart, end = coreStart + coreLength - 1
            var gap = 0
            var index = start - 1
            while index >= 0 {
                if smoothed[index] < looseRate { start = index; gap = 0 }
                else { gap += 1; if gap > allowedGap { break } }
                index -= 1
            }
            gap = 0
            index = end + 1
            while index < smoothed.count {
                if smoothed[index] < looseRate { end = index; gap = 0 }
                else { gap += 1; if gap > allowedGap { break } }
                index += 1
            }

            let length = end - start + 1
            if length > (best?.length ?? 0) {
                let absoluteStart = from + start
                best = Segment(startInA: absoluteStart, startInB: absoluteStart - offset,
                               length: length, errorRate: smoothed[coreStart])
            }
        }
        return best
    }
}


nonisolated enum IntroError: LocalizedError {
    case noFFmpeg

    var errorDescription: String? {
        String(localized: "Для поиска заставок нужен ffmpeg: brew install ffmpeg")
    }
}

/// Находит заставки, сравнивая серии одного сезона между собой.
///
/// Заставка — единственный кусок, который в сериях звучит одинаково: речь,
/// музыка сцен и «в предыдущих сериях» у каждой серии свои. Поэтому её видно
/// без всякого понимания содержания, простым сравнением звука.
/// Проверено на 4 сезоне «Очень странных дел»: находится отрезок в 59 секунд,
/// который начинается на титрах и заканчивается на карточке эпизода.
nonisolated enum IntroDetector {

    struct Found: Sendable {
        var start: Double
        var end: Double
    }

    static var isAvailable: Bool { ExternalTools.ffmpeg != nil }

    /// Сколько минут от начала серии просматриваем. Заставка бывает и после
    /// длинного холодного открытия, но не дальше двенадцатой минуты.
    static let searchMinutes = 12

    /// Считает заставки для серий одного сезона.
    /// Возвращает границы для тех файлов, где нашлось согласованное совпадение.
    static func detect(files: [URL],
                       onProgress: (@Sendable (Int, Int) -> Void)? = nil) -> [URL: Found] {
        guard files.count >= 2 else { return [:] }

        var prints: [(url: URL, fingerprint: [UInt32])] = []
        for (index, url) in files.enumerated() {
            onProgress?(index, files.count)
            guard let samples = try? AudioFingerprint.decode(path: url.path,
                                                             seconds: searchMinutes * 60) else { continue }
            let fingerprint = AudioFingerprint.compute(samples: samples)
            guard !fingerprint.isEmpty else { continue }
            prints.append((url, fingerprint))
        }
        guard prints.count >= 2 else { return [:] }

        // Каждая пара даёт по отрезку каждой из двух серий.
        var candidates: [URL: [Found]] = [:]
        for i in 0..<prints.count {
            for j in (i + 1)..<prints.count {
                guard let segment = AudioFingerprint.commonSegment(prints[i].fingerprint,
                                                                   prints[j].fingerprint) else { continue }
                let step = AudioFingerprint.secondsPerFrame
                let length = Double(segment.length) * step
                let first = Double(segment.startInA) * step
                let second = Double(segment.startInB) * step
                candidates[prints[i].url, default: []].append(Found(start: first, end: first + length))
                candidates[prints[j].url, default: []].append(Found(start: second, end: second + length))
            }
        }

        // Медиана по парам: одна случайная сработка не сдвинет результат.
        var result: [URL: Found] = [:]
        for (url, found) in candidates {
            let starts = found.map(\.start).sorted()
            let ends = found.map(\.end).sorted()
            let start = starts[starts.count / 2]
            let end = ends[ends.count / 2]
            guard end - start >= 20 else { continue }
            result[url] = Found(start: start, end: end)
        }
        return result
    }
}
