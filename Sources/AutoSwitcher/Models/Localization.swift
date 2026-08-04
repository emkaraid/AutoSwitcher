//
//  Localization.swift
//  AutoSwitcher
//
//  In-app localization (EN / RU) with a user-selectable override.
//
//  Why not .lproj bundles: the app bundle is assembled by hand in build.sh
//  (SwiftPM executable, no Xcode project), and we also want the language to
//  be switchable at runtime from Preferences without relaunching. A small
//  in-code string table observed by SwiftUI does both trivially at this size.
//

import Foundation
import Combine

final class L10n: ObservableObject {

    static let shared = L10n()

    /// "system" | "en" | "ru" — persisted in UserDefaults.
    @Published var language: String {
        didSet {
            UserDefaults.standard.set(language, forKey: AppSettings.Keys.appLanguage)
        }
    }

    private init() {
        language = UserDefaults.standard.string(forKey: AppSettings.Keys.appLanguage) ?? "system"
    }

    var isRussian: Bool {
        switch language {
        case "ru": return true
        case "en": return false
        default:
            return Locale.preferredLanguages.first?.lowercased().hasPrefix("ru") ?? false
        }
    }

    /// Translate a key. Unknown keys return the key itself so a missing
    /// entry is immediately visible in the UI instead of crashing.
    func t(_ key: String) -> String {
        guard let pair = L10n.table[key] else { return key }
        return isRussian ? pair.ru : pair.en
    }

    /// Translate with one substitution (%@).
    func t(_ key: String, _ arg: String) -> String {
        t(key).replacingOccurrences(of: "%@", with: arg)
    }

    // MARK: - String table

    private static let table: [String: (en: String, ru: String)] = [
        // Menu bar
        "menu.enable":          ("Enable AutoSwitcher", "Включить AutoSwitcher"),
        "menu.permissions":     ("Set Up Permissions…", "Настроить разрешения…"),
        "menu.permissionsHint": ("Accessibility and Input Monitoring are required for AutoSwitcher to work.",
                                 "Для работы нужны разрешения «Универсальный доступ» и «Мониторинг ввода»."),
        "menu.settings":        ("Settings…", "Настройки…"),
        "menu.switchTo":        ("Switch Layout to %@", "Сменить раскладку на %@"),
        "layout.ru":            ("🇷🇺 Russian", "🇷🇺 русскую"),
        "layout.en":            ("🇺🇸 English", "🇺🇸 английскую"),
        "menu.restart":         ("Restart AutoSwitcher", "Перезапустить AutoSwitcher"),
        "menu.quit":            ("Quit AutoSwitcher", "Завершить AutoSwitcher"),
        "menu.pause":           ("Pause", "Приостановить"),
        "menu.pause30":         ("For 30 minutes", "На 30 минут"),
        "menu.pause1h":         ("For 1 hour", "На 1 час"),
        "menu.pauseRestart":    ("Until restart", "До перезапуска"),
        "menu.resume":          ("Resume (paused until %@)", "Возобновить (пауза до %@)"),
        "menu.resumeRestart":   ("Resume (paused until restart)", "Возобновить (пауза до перезапуска)"),
        "menu.statsToday":      ("Corrected today", "Исправлено сегодня"),
        "menu.statsTotal":      ("total", "всего"),
        "menu.checkUpdates":    ("Check for Updates…", "Проверить обновления…"),

        // Update checker
        "upd.available":        ("AutoSwitcher %@ is available", "Доступна версия AutoSwitcher %@"),
        "upd.availableInfo":    ("You have %@. The download page will open in your browser.",
                                 "У вас установлена %@. Страница загрузки откроется в браузере."),
        "upd.download":         ("Download", "Скачать"),
        "upd.later":            ("Later", "Позже"),
        "upd.latest":           ("You're up to date", "У вас последняя версия"),
        "upd.latestInfo":       ("AutoSwitcher %@ is the newest version.",
                                 "AutoSwitcher %@ — самая свежая версия."),
        "upd.error":            ("Could not check for updates", "Не удалось проверить обновления"),
        "upd.errorInfo":        ("Check your internet connection and try again.",
                                 "Проверьте подключение к интернету и попробуйте ещё раз."),

        // Settings tabs
        "tab.general":          ("General", "Основные"),
        "tab.dictionary":       ("Dictionary", "Словарь"),
        "tab.apps":             ("Apps", "Приложения"),

        // Preferences
        "prefs.behavior":       ("Behavior", "Поведение"),
        "prefs.enable":         ("Enable AutoSwitcher", "Включить AutoSwitcher"),
        "prefs.launchAtLogin":  ("Launch at login", "Запускать при входе в систему"),
        "prefs.smartUndo":      ("Smart Undo on Backspace", "Умная отмена по Backspace (⌫)"),
        "prefs.optionTap":      ("Revert / convert last word on ⌥ Option tap",
                                 "Отмена и конвертация слова по нажатию ⌥ Option"),
        "prefs.convertSelection": ("Convert selected text with ⌥⇧R",
                                 "Конвертировать выделенный текст по ⌥⇧R"),
        "prefs.correctOnEnter": ("Correct the last word on Enter ⏎",
                                 "Исправлять последнее слово по Enter ⏎"),
        "prefs.autoLearn":      ("Add word to Dictionary after two reverts",
                                 "Добавлять слово в словарь после двух отмен"),
        "prefs.askAdd":         ("Offer to add reverted word to Dictionary",
                                 "Предлагать добавить отменённое слово в словарь"),
        "prefs.playSound":      ("Play sound on auto-switch", "Звук при автопереключении"),
        "prefs.ignoreDigits":   ("Ignore words with numbers and symbols",
                                 "Игнорировать слова с цифрами и символами"),
        "prefs.footer":         ("Smart Undo: press ⌫ within 2 seconds of an auto-switch to revert it. A small toast will offer to save the word to the Dictionary so it is never corrected again.",
                                 "Умная отмена: нажмите ⌫ в течение 2 секунд после автопереключения, чтобы отменить его. Всплывающая подсказка предложит сохранить слово в словарь, чтобы оно больше не исправлялось."),
        "prefs.language":       ("Interface Language", "Язык интерфейса"),
        "lang.system":          ("System", "Как в системе"),
        "prefs.diagnostics":    ("Diagnostics", "Диагностика"),
        "prefs.verboseLog":     ("Verbose log (records typed words)",
                                 "Подробный журнал (записывает набранные слова)"),
        "prefs.openLog":        ("Open Log", "Открыть журнал"),
        "prefs.logFooter":      ("By default the log contains only technical events and never your text. Enable the verbose mode temporarily when investigating a problem.",
                                 "По умолчанию журнал содержит только технические события и никогда — ваш текст. Включайте подробный режим временно, для разбора проблем."),

        // Permissions
        "perm.section":         ("Permissions", "Разрешения"),
        "perm.ax":              ("Accessibility", "Универсальный доступ"),
        "perm.im":              ("Input Monitoring", "Мониторинг ввода"),
        "perm.granted":         ("granted", "выдано"),
        "perm.required":        ("required", "требуется"),
        "perm.open":            ("Open Settings", "Открыть настройки"),
        "perm.secure.on":       ("Secure Input is active — correction paused",
                                 "Активен защищённый ввод — исправление на паузе"),
        "perm.secure.off":      ("Secure Input: off", "Защищённый ввод: выключен"),

        // Dictionary
        "dict.title":           ("Exception words", "Слова-исключения"),
        "dict.subtitle":        ("Words in this list will never be auto-corrected.",
                                 "Слова из этого списка никогда не будут исправляться автоматически."),
        "dict.placeholder":     ("Add a word…", "Добавить слово…"),
        "dict.add":             ("Add", "Добавить"),
        "dict.remove":          ("Remove selected", "Удалить выбранные"),

        // Smart Undo toast
        "toast.reverted":       ("Reverted “%@”", "Отменено «%@»"),
        "toast.question":       ("Add to Dictionary so it isn't corrected again?",
                                 "Добавить в словарь, чтобы больше не исправлялось?"),
        "toast.add":            ("Add", "Добавить"),
        "toast.autoAdded":      ("“%@” added to Dictionary", "«%@» добавлено в словарь"),

        // App exceptions tab
        "apps.title":           ("App exceptions", "Приложения-исключения"),
        "apps.subtitle":        ("AutoSwitcher never corrects typing in these apps.",
                                 "В этих приложениях AutoSwitcher не исправляет набор."),
        "apps.add":             ("Add App…", "Добавить приложение…"),
        "apps.remove":          ("Remove selected", "Удалить выбранные"),
        "apps.reset":           ("Restore default list", "Вернуть стандартный список"),

        // Permissions onboarding window
        "ob.windowTitle":       ("AutoSwitcher Setup", "Настройка AutoSwitcher"),
        "ob.title":             ("AutoSwitcher needs two permissions",
                                 "AutoSwitcher нужны два разрешения"),
        "ob.subtitle":          ("macOS requires them to read and correct what you type. Everything stays on your Mac — nothing is logged or sent anywhere.",
                                 "macOS требует их, чтобы читать и исправлять набираемый текст. Всё остаётся на вашем Mac — ничего не записывается и никуда не отправляется."),
        "ob.ax.desc":           ("Lets the app delete a mistyped word and retype it in the correct layout.",
                                 "Позволяет удалить слово и заново напечатать его в правильной раскладке."),
        "ob.im.desc":           ("Lets the app see keystrokes to detect typing in the wrong layout.",
                                 "Позволяет видеть нажатия клавиш, чтобы определять набор в неверной раскладке."),
        "ob.step":              ("Click the button, find AutoSwitcher in the list and turn it on.",
                                 "Нажмите кнопку, найдите AutoSwitcher в списке и включите переключатель."),
        "ob.note":              ("After Input Monitoring is enabled, AutoSwitcher restarts automatically.",
                                 "После включения «Мониторинга ввода» AutoSwitcher перезапустится автоматически."),
        "ob.allSet":            ("All set! AutoSwitcher is up and running.",
                                 "Готово! AutoSwitcher настроен и работает."),
        "ob.granted":           ("Granted", "Выдано"),
        "ob.close":             ("Close", "Закрыть")
    ]
}
