import Foundation

#if canImport(FoundationModels)
import FoundationModels
#endif

/// Запасной разбор заголовка встроенной в macOS языковой моделью.
///
/// Основной разбор делают регулярные выражения — они мгновенные и предсказуемые.
/// Модель подключается только там, где они принципиально бессильны: название
/// внутри фразы, описание вместо заголовка, реклама канала в начале.
/// Ошибка модели не страшна: её результат всё равно уходит на проверку в TMDB.
@MainActor
final class TitleAI {

    static let shared = TitleAI()

    /// Что удалось вытащить из заголовка.
    struct Guess: Equatable {
        var title: String
        var year: Int?
        var season: Int?
        var episode: Int?
    }

    enum Availability: Equatable {
        case available
        case notSupported(String)

        var isAvailable: Bool { self == .available }
    }

    private(set) var availability: Availability = .notSupported("Модель ещё не проверялась")
    private var didCheck = false

    /// Пользователя предупреждаем один раз за всё время, а не при каждом запуске.
    private static let warnedKey = "didWarnAboutOnDeviceModel"

    var shouldWarnUser: Bool {
        guard !availability.isAvailable else { return false }
        return !UserDefaults.standard.bool(forKey: Self.warnedKey)
    }

    func markWarningShown() {
        UserDefaults.standard.set(true, forKey: Self.warnedKey)
    }

    var unavailabilityMessage: String {
        guard case .notSupported(let reason) = availability else { return "" }
        return """
               \(reason)

               Это не мешает работе: названия разбираются обычным способом, \
               а если что-то определилось неверно — в карточке есть «Уточнить в TMDB…».
               """
    }

    // MARK: - Проверка доступности

    func checkAvailability() {
        guard !didCheck else { return }
        didCheck = true

        #if canImport(FoundationModels)
        switch SystemLanguageModel.default.availability {
        case .available:
            availability = .available
        case .unavailable(let reason):
            availability = .notSupported(Self.describe(reason))
        @unknown default:
            availability = .notSupported("Встроенная модель недоступна на этом Маке.")
        }
        #else
        availability = .notSupported("Эта сборка собрана без поддержки встроенной модели macOS.")
        #endif
    }

    #if canImport(FoundationModels)
    private static func describe(_ reason: SystemLanguageModel.Availability.UnavailableReason) -> String {
        switch reason {
        case .deviceNotEligible:
            "Этот Мак не поддерживает встроенную языковую модель Apple."
        case .appleIntelligenceNotEnabled:
            "Apple Intelligence выключен. Включите его в Системных настройках, "
            + "если хотите, чтобы приложение разбирало сложные заголовки роликов."
        case .modelNotReady:
            "Модель Apple Intelligence ещё загружается — попробуйте позже."
        @unknown default:
            "Встроенная модель недоступна."
        }
    }
    #endif

    // MARK: - Разбор

    /// Пытается вытащить название из заголовка, с которым не справились регулярки.
    /// Возвращает nil, если модель недоступна или ответила бессмыслицей.
    func guess(from rawTitle: String) async -> Guess? {
        checkAvailability()
        guard availability.isAvailable else { return nil }

        #if canImport(FoundationModels)
        let instructions = """
            Ты извлекаешь название фильма или сериала из заголовка видеоролика.
            Заголовки бывают замусорены рекламой канала, качеством видео и лишними словами.
            Верни только само название произведения, без слов «смотреть», «онлайн»,
            «в хорошем качестве», без указания качества и озвучки.
            Если в заголовке есть год выхода — верни его. Если года нет, верни 0.
            Если это серия сериала — верни номер сезона и серии, иначе 0.
            Ничего не выдумывай: если названия в заголовке нет, верни его пустым.
            """

        do {
            let session = LanguageModelSession(instructions: instructions)
            let response = try await session.respond(to: "Заголовок: \(rawTitle)",
                                                     generating: ExtractedTitle.self)
            let result = response.content
            let title = result.title.trimmingCharacters(in: .whitespacesAndNewlines)

            // Отсекаем очевидную бессмыслицу: пустое или выдуманное длиннее исходника.
            guard !title.isEmpty, title.count <= rawTitle.count + 10 else { return nil }

            return Guess(title: title,
                         year: (1900...2100).contains(result.year) ? result.year : nil,
                         season: result.season > 0 ? result.season : nil,
                         episode: result.episode > 0 ? result.episode : nil)
        } catch {
            log.error("Встроенная модель не смогла разобрать заголовок: \(error.localizedDescription)")
            return nil
        }
        #else
        return nil
        #endif
    }
}

#if canImport(FoundationModels)
/// Схема ответа модели. Строгий формат исключает вольный текст в ответе.
/// Необязательные значения передаём нулями — так надёжнее, чем optional.
@Generable
struct ExtractedTitle {
    @Guide(description: "Название фильма или сериала без лишних слов")
    var title: String

    @Guide(description: "Год выхода четырьмя цифрами, либо 0 если года нет")
    var year: Int

    @Guide(description: "Номер сезона, либо 0 если это не сериал")
    var season: Int

    @Guide(description: "Номер серии, либо 0 если это не сериал")
    var episode: Int
}
#endif
