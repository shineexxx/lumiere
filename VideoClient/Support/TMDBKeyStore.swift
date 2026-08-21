import Foundation

/// Хранилище API-ключа TMDB.
///
/// Ключ лежит в обычных настройках приложения, а не в связке ключей.
/// Причина практическая: приложение подписывается ad-hoc, и при каждой пересборке
/// подпись меняется — связка считает программу новой и на каждом запуске требует
/// пароль модальным окном. Ключ TMDB бесплатный и только для чтения каталога,
/// поэтому цена такого хранения невелика, а неудобство от диалога — велико.
///
/// Файл настроек: ~/Library/Containers/com.arseny.VideoClient/Data/Library/Preferences
nonisolated enum TMDBKeyStore {

    private static let defaultsKey = "tmdbAPIKey"

    static var key: String? {
        get {
            let value = UserDefaults.standard.string(forKey: defaultsKey)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return (value?.isEmpty ?? true) ? nil : value
        }
        set {
            let trimmed = newValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if trimmed.isEmpty {
                UserDefaults.standard.removeObject(forKey: defaultsKey)
            } else {
                UserDefaults.standard.set(trimmed, forKey: defaultsKey)
            }
        }
    }

    /// Разовый перенос ключа из связки ключей — для тех, у кого он остался там.
    /// Вызовет системный запрос пароля: связка не отдаёт запись приложению
    /// с изменившейся подписью без подтверждения.
    @discardableResult
    static func importFromKeychain() -> String? {
        guard let existing = Keychain.get(TMDBClient.keychainAccount),
              !existing.isEmpty else { return nil }
        key = existing
        return existing
    }
}
