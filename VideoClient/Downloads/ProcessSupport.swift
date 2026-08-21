import Foundation

/// Собирает поток байтов от процесса в законченные строки.
/// Обработчик чтения вызывается на служебной очереди, поэтому доступ под замком.
nonisolated final class LineBuffer: @unchecked Sendable {
    private var storage = ""
    private let lock = NSLock()

    /// Добавляет кусок вывода и возвращает строки, которые уже завершены.
    func append(_ chunk: String) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        storage += chunk
        var lines: [String] = []
        while let newline = storage.firstIndex(of: "\n") {
            lines.append(String(storage[..<newline]))
            storage.removeSubrange(...newline)
        }
        return lines
    }

    /// Остаток без перевода строки — забираем в самом конце.
    func flush() -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard !storage.isEmpty else { return nil }
        let tail = storage
        storage = ""
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

/// Последнее сообщение об ошибке, записанное из фонового обработчика.
nonisolated final class ErrorBox: @unchecked Sendable {
    private var storage: String?
    private let lock = NSLock()

    func set(_ message: String) {
        lock.lock()
        storage = message
        lock.unlock()
    }

    var value: String? {
        lock.lock()
        defer { lock.unlock() }
        return storage
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
