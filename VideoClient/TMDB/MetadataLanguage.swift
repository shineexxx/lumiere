import Foundation

/// На каком языке просить у TMDB названия, описания и названия серий.
///
/// По умолчанию язык метаданных идёт за языком интерфейса: переключил систему
/// на английский — карточки тоже стали английскими. Но если язык выбран в
/// настройках явно, дальше побеждает этот выбор, даже когда интерфейс другой:
/// смотреть английский интерфейс с русскими описаниями — вполне нормальное желание.
nonisolated enum MetadataLanguage {

    private static let key = "tmdbLanguage"

    /// Языки, которые предлагаем в настройках.
    static let options = ["ru-RU", "en-US", "uk-UA"]

    /// Явно выбранный язык, либо nil — «как в приложении».
    static var stored: String? {
        get { UserDefaults.standard.string(forKey: key) }
        set {
            if let newValue {
                UserDefaults.standard.set(newValue, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
    }

    /// Язык интерфейса, приведённый к коду TMDB.
    static var automatic: String {
        switch Bundle.main.preferredLocalizations.first?.prefix(2) {
        case "ru": "ru-RU"
        case "uk": "uk-UA"
        default: "en-US"
        }
    }

    /// То, с чем реально уходит запрос.
    static var effective: String { stored ?? automatic }

    /// Человеческое имя языка — на нём же самом, как принято в списках языков.
    static func title(for code: String) -> String {
        switch code {
        case "ru-RU": "Русский"
        case "uk-UA": "Українська"
        default: "English"
        }
    }
}
