import Foundation

/// Собирает поток байтов от процесса в законченные строки.
nonisolated struct LineBuffer {
    private var storage = Data()

    /// Добавляет кусок вывода и возвращает строки, которые уже завершены.
    mutating func append(_ chunk: Data) -> [String] {
        storage.append(chunk)
        var lines: [String] = []
        while let newline = storage.firstIndex(of: 0x0A) {
            let line = storage[..<newline]
            lines.append(String(decoding: line.last == 0x0D ? line.dropLast() : line, as: UTF8.self))
            storage.removeSubrange(...newline)
        }
        return lines
    }

    /// Остаток без перевода строки — забираем в самом конце.
    mutating func flush() -> String? {
        guard !storage.isEmpty else { return nil }
        let tail = String(decoding: storage, as: UTF8.self)
        storage.removeAll()
        return tail
    }
}

/// Гарантирует, что продолжение возобновят ровно один раз.
/// Обработчик завершения процесса и ветка ошибки запуска могут сработать оба.
nonisolated final class OnceFlag: @unchecked Sendable {
    private var used = false
    private let lock = NSLock()

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !used else { return false }
        used = true
        return true
    }
}

/// Накапливает данные из канала процесса.
nonisolated final class DataBox: @unchecked Sendable {
    private var storage = Data()
    private let lock = NSLock()

    func append(_ data: Data) {
        lock.lock()
        storage.append(data)
        lock.unlock()
    }

    var value: Data {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    var text: String { String(decoding: value, as: UTF8.self) }
}
