import Foundation

/// Languages supported by MoniVol's interface.
enum AppLanguage: String, CaseIterable {
    case english = "en"
    case chinese = "zh"
    case japanese = "ja"
    case french = "fr"
    case german = "de"
    case russian = "ru"

    /// Stores only an explicit in-app override. An absent value follows macOS.
    static let storageKey = "appLanguageOverride"

    /// Uses the first macOS preferred language supported by MoniVol.
    static var systemDefault: AppLanguage {
        for identifier in Locale.preferredLanguages {
            let code = identifier.lowercased()
            if code.hasPrefix("zh") { return .chinese }
            if code.hasPrefix("ja") { return .japanese }
            if code.hasPrefix("fr") { return .french }
            if code.hasPrefix("de") { return .german }
            if code.hasPrefix("ru") { return .russian }
            if code.hasPrefix("en") { return .english }
        }
        return .english
    }

    /// Respects a saved in-app choice and otherwise follows macOS.
    static var selected: AppLanguage {
        guard let code = UserDefaults.standard.string(forKey: storageKey),
              let language = AppLanguage(rawValue: code) else {
            return systemDefault
        }
        return language
    }

    var name: String {
        switch self {
        case .english: return "English"
        case .chinese: return "简体中文"
        case .japanese: return "日本語"
        case .french: return "Français"
        case .german: return "Deutsch"
        case .russian: return "Русский"
        }
    }

    func text(_ english: String, _ chinese: String) -> String {
        switch self {
        case .english: return english
        case .chinese: return chinese
        case .japanese: return Self.translations[english]?.japanese ?? english
        case .french: return Self.translations[english]?.french ?? english
        case .german: return Self.translations[english]?.german ?? english
        case .russian: return Self.translations[english]?.russian ?? english
        }
    }

    private struct Translations {
        let japanese: String
        let french: String
        let german: String
        let russian: String
    }

    private static let translations: [String: Translations] = [
        "Output Device": .init(japanese: "出力デバイス", french: "Périphérique de sortie", german: "Ausgabegerät", russian: "Устройство вывода"),
        "Language": .init(japanese: "言語", french: "Langue", german: "Sprache", russian: "Язык"),
        "Quit App": .init(japanese: "アプリを終了", french: "Quitter l’app", german: "App beenden", russian: "Выйти"),
        "External display volume": .init(japanese: "外部ディスプレイの音量", french: "Volume de l’écran externe", german: "Lautstärke des Monitors", russian: "Громкость монитора"),
        "More options": .init(japanese: "その他の操作", french: "Plus d’options", german: "Weitere Optionen", russian: "Дополнительно"),
        "Open at Login": .init(japanese: "ログイン時に開く", french: "Ouvrir à la connexion", german: "Bei Anmeldung öffnen", russian: "Открывать при входе"),
        "Could Not Change Login Setting": .init(japanese: "ログイン設定を変更できませんでした", french: "Impossible de modifier le réglage de connexion", german: "Anmeldeeinstellung konnte nicht geändert werden", russian: "Не удалось изменить настройку входа"),
        "Check for Updates": .init(japanese: "更新を確認", french: "Vérifier les mises à jour", german: "Auf Updates prüfen", russian: "Проверить обновления"),
        "About MoniVol": .init(japanese: "MoniVol について", french: "À propos de MoniVol", german: "Über MoniVol", russian: "О MoniVol"),
        "No Device": .init(japanese: "デバイスなし", french: "Aucun appareil", german: "Kein Gerät", russian: "Нет устройства"),
        "Mute or unmute": .init(japanese: "ミュートを切り替え", french: "Activer ou couper le son", german: "Stumm schalten", russian: "Включить или выключить звук"),
        "This device supports native volume control": .init(japanese: "このデバイスはシステムの音量調節に対応しています", french: "Réglage du volume système disponible", german: "Systemlautstärke verfügbar", russian: "Доступна системная регулировка громкости"),
        "Fixed": .init(japanese: "修復済み", french: "Corrigé", german: "Behoben", russian: "Исправлено"),
        "External Display": .init(japanese: "外部ディスプレイ", french: "Écran externe", german: "Externer Monitor", russian: "Внешний монитор"),
        "Built-in Output": .init(japanese: "内蔵出力", french: "Sortie intégrée", german: "Integrierte Ausgabe", russian: "Встроенный выход"),
        "Audio Output": .init(japanese: "オーディオ出力", french: "Sortie audio", german: "Audioausgabe", russian: "Аудиовыход"),
        "Reconnected": .init(japanese: "再接続しました", french: "Reconnecté", german: "Wieder verbunden", russian: "Переподключено"),
        "Reconnect": .init(japanese: "再接続", french: "Reconnecter", german: "Neu verbinden", russian: "Переподключить"),
        "Uninstall Driver": .init(japanese: "ドライバを削除", french: "Désinstaller le pilote", german: "Treiber deinstallieren", russian: "Удалить драйвер"),
        "Uninstall MoniVol Driver": .init(japanese: "MoniVol ドライバを削除", french: "Désinstaller le pilote MoniVol", german: "MoniVol-Treiber deinstallieren", russian: "Удалить драйвер MoniVol"),
        "This will remove the audio driver, stop background processes, and clear configuration data. The app itself will not be deleted — you can reinstall the driver anytime.": .init(
            japanese: "オーディオドライバを削除し、バックグラウンドプロセスを停止して設定データを消去します。アプリは削除されず、ドライバは後で再インストールできます。",
            french: "Le pilote audio sera supprimé, les processus en arrière-plan arrêtés et les réglages effacés. L’application restera installée ; vous pourrez réinstaller le pilote plus tard.",
            german: "Der Audiotreiber wird entfernt, Hintergrundprozesse werden beendet und Einstellungen gelöscht. Die App bleibt installiert; der Treiber kann später erneut installiert werden.",
            russian: "Аудиодрайвер будет удалён, фоновые процессы остановлены, а настройки очищены. Приложение останется установленным; драйвер можно установить позже."
        ),
        "Cancel": .init(japanese: "キャンセル", french: "Annuler", german: "Abbrechen", russian: "Отмена"),

        "Set up MoniVol": .init(japanese: "MoniVol を設定", french: "Configurer MoniVol", german: "MoniVol einrichten", russian: "Настройка MoniVol"),
        "MoniVol lets you control your external monitor volume with your keyboard volume keys.": .init(
            japanese: "キーボードの音量キーで外部ディスプレイの音量を調整できます。",
            french: "Contrôlez le volume de votre écran externe avec les touches du clavier.",
            german: "Steuere die Lautstärke des externen Monitors mit den Lautstärketasten.",
            russian: "Управляйте громкостью внешнего монитора клавишами громкости."
        ),
        "Audio Driver Installed": .init(japanese: "オーディオドライバをインストール済み", french: "Pilote audio installé", german: "Audiotreiber installiert", russian: "Аудиодрайвер установлен"),
        "Install Audio Driver": .init(japanese: "オーディオドライバをインストール", french: "Installer le pilote audio", german: "Audiotreiber installieren", russian: "Установить аудиодрайвер"),
        "The audio driver is installed and ready.": .init(japanese: "オーディオドライバの準備ができました。", french: "Le pilote audio est installé et prêt.", german: "Der Audiotreiber ist installiert und bereit.", russian: "Аудиодрайвер установлен и готов."),
        "Select MoniVol in Sound Settings": .init(japanese: "サウンド設定で MoniVol を選択", french: "Sélectionner MoniVol dans Son", german: "MoniVol in den Toneinstellungen wählen", russian: "Выберите MoniVol в настройках звука"),
        "Open System Settings → Sound and select the MoniVol device to get started.": .init(
            japanese: "「システム設定」→「サウンド」を開き、MoniVol デバイスを選択してください。",
            french: "Ouvrez Réglages Système → Son et sélectionnez le périphérique MoniVol.",
            german: "Öffne Systemeinstellungen → Ton und wähle das MoniVol-Gerät aus.",
            russian: "Откройте «Системные настройки» → «Звук» и выберите устройство MoniVol."
        ),
        "Skip for now": .init(japanese: "今はスキップ", french: "Ignorer pour l’instant", german: "Vorerst überspringen", russian: "Пропустить"),
        "Open MoniVol": .init(japanese: "MoniVol を開く", french: "Ouvrir MoniVol", german: "MoniVol öffnen", russian: "Открыть MoniVol"),
        "Retry": .init(japanese: "再試行", french: "Réessayer", german: "Erneut versuchen", russian: "Повторить"),
        "Installing…": .init(japanese: "インストール中…", french: "Installation…", german: "Installation…", russian: "Установка…"),
        "Install Driver": .init(japanese: "ドライバをインストール", french: "Installer le pilote", german: "Treiber installieren", russian: "Установить драйвер"),
        "An audio driver is required to enable volume control. This requires an administrator password.": .init(
            japanese: "音量調整にはオーディオドライバが必要です。管理者パスワードを入力してください。",
            french: "Un pilote audio est requis pour contrôler le volume. Le mot de passe administrateur est nécessaire.",
            german: "Für die Lautstärkeregelung ist ein Audiotreiber erforderlich. Dazu wird das Administratorpasswort benötigt.",
            russian: "Для управления громкостью нужен аудиодрайвер. Потребуется пароль администратора."
        ),
        "Installation failed: ": .init(japanese: "インストールに失敗しました：", french: "Échec de l’installation : ", german: "Installation fehlgeschlagen: ", russian: "Ошибка установки: "),
        "Checking for existing driver...": .init(japanese: "既存のドライバを確認中…", french: "Recherche d’un pilote existant…", german: "Vorhandener Treiber wird geprüft…", russian: "Проверка установленного драйвера…"),
        "Copying driver files...": .init(japanese: "ドライバファイルをコピー中…", french: "Copie des fichiers du pilote…", german: "Treiberdateien werden kopiert…", russian: "Копирование файлов драйвера…"),
        "Setting permissions...": .init(japanese: "アクセス権を設定中…", french: "Configuration des autorisations…", german: "Berechtigungen werden gesetzt…", russian: "Настройка разрешений…"),
        "Restarting audio system...": .init(japanese: "オーディオシステムを再起動中…", french: "Redémarrage du système audio…", german: "Audiosystem wird neu gestartet…", russian: "Перезапуск аудиосистемы…"),
        "Verifying installation...": .init(japanese: "インストールを確認中…", french: "Vérification de l’installation…", german: "Installation wird überprüft…", russian: "Проверка установки…"),

        "Driver Update Available": .init(japanese: "ドライバの更新があります", french: "Mise à jour du pilote disponible", german: "Treiberupdate verfügbar", russian: "Доступно обновление драйвера"),
        "Current": .init(japanese: "現在", french: "Actuelle", german: "Aktuell", russian: "Текущая"),
        "New": .init(japanese: "新規", french: "Nouvelle", german: "Neu", russian: "Новая"),
        "Requires administrator privileges": .init(japanese: "管理者権限が必要です", french: "Nécessite les droits administrateur", german: "Administratorrechte erforderlich", russian: "Требуются права администратора"),
        "Later": .init(japanese: "後で", french: "Plus tard", german: "Später", russian: "Позже"),
        "Update Now": .init(japanese: "今すぐ更新", french: "Mettre à jour", german: "Jetzt aktualisieren", russian: "Обновить сейчас"),

        "MoniVol Settings": .init(japanese: "MoniVol 設定", french: "Réglages MoniVol", german: "MoniVol-Einstellungen", russian: "Настройки MoniVol"),
        "Version": .init(japanese: "バージョン", french: "Version", german: "Version", russian: "Версия"),
        "Updates": .init(japanese: "アップデート", french: "Mises à jour", german: "Updates", russian: "Обновления"),
        "System Info": .init(japanese: "システム情報", french: "Informations système", german: "Systeminformationen", russian: "Сведения о системе"),
        "App Version": .init(japanese: "アプリのバージョン", french: "Version de l’app", german: "App-Version", russian: "Версия приложения"),
        "Driver Version": .init(japanese: "ドライバのバージョン", french: "Version du pilote", german: "Treiberversion", russian: "Версия драйвера"),
        "Driver Status": .init(japanese: "ドライバの状態", french: "État du pilote", german: "Treiberstatus", russian: "Состояние драйвера"),
        "Not Installed": .init(japanese: "未インストール", french: "Non installé", german: "Nicht installiert", russian: "Не установлен"),
        "Driver Installed": .init(japanese: "ドライバのインストール日", french: "Pilote installé", german: "Treiber installiert", russian: "Драйвер установлен"),
        "About": .init(japanese: "情報", french: "À propos", german: "Über", russian: "О приложении"),
        "MoniVol controls the volume of external display audio on macOS.": .init(japanese: "MoniVol は macOS で外部ディスプレイの音量を調整します。", french: "MoniVol contrôle le volume des écrans externes sur macOS.", german: "MoniVol steuert unter macOS die Lautstärke externer Monitore.", russian: "MoniVol управляет громкостью внешних мониторов в macOS."),
        "Visit Website": .init(japanese: "Webサイトを開く", french: "Visiter le site web", german: "Website besuchen", russian: "Открыть сайт"),

        "Driver Updated": .init(japanese: "ドライバを更新しました", french: "Pilote mis à jour", german: "Treiber aktualisiert", russian: "Драйвер обновлён"),
        "The MoniVol audio driver has been updated to version %@.": .init(japanese: "MoniVol オーディオドライバをバージョン %@ に更新しました。", french: "Le pilote audio MoniVol a été mis à jour vers la version %@.", german: "Der MoniVol-Audiotreiber wurde auf Version %@ aktualisiert.", russian: "Аудиодрайвер MoniVol обновлён до версии %@."),
        "Update Failed": .init(japanese: "更新に失敗しました", french: "Échec de la mise à jour", german: "Update fehlgeschlagen", russian: "Ошибка обновления"),
        "Failed to update driver: %@": .init(japanese: "ドライバを更新できませんでした：%@", french: "Échec de la mise à jour du pilote : %@", german: "Treiber konnte nicht aktualisiert werden: %@", russian: "Не удалось обновить драйвер: %@"),
        "OK": .init(japanese: "OK", french: "OK", german: "OK", russian: "ОК"),
        "unknown": .init(japanese: "不明", french: "inconnue", german: "unbekannt", russian: "неизвестно"),
        "Driver bundle not found in app resources": .init(japanese: "アプリ内にドライバが見つかりません", french: "Pilote introuvable dans l’application", german: "Treiber wurde in der App nicht gefunden", russian: "Драйвер не найден в ресурсах приложения"),
        "Failed to copy driver: %@": .init(japanese: "ドライバをコピーできませんでした：%@", french: "Échec de la copie du pilote : %@", german: "Treiber konnte nicht kopiert werden: %@", russian: "Не удалось скопировать драйвер: %@"),
        "Failed to set permissions: %@": .init(japanese: "アクセス権を設定できませんでした：%@", french: "Échec de la configuration des autorisations : %@", german: "Berechtigungen konnten nicht gesetzt werden: %@", russian: "Не удалось настроить разрешения: %@"),
        "Failed to restart audio system: %@": .init(japanese: "オーディオシステムを再起動できませんでした：%@", french: "Échec du redémarrage du système audio : %@", german: "Audiosystem konnte nicht neu gestartet werden: %@", russian: "Не удалось перезапустить аудиосистему: %@"),
        "Driver installation could not be verified": .init(japanese: "ドライバのインストールを確認できませんでした", french: "L’installation du pilote n’a pas pu être vérifiée", german: "Die Treiberinstallation konnte nicht überprüft werden", russian: "Не удалось проверить установку драйвера"),
        "Failed to uninstall driver: %@": .init(japanese: "ドライバを削除できませんでした：%@", french: "Échec de la désinstallation du pilote : %@", german: "Treiber konnte nicht deinstalliert werden: %@", russian: "Не удалось удалить драйвер: %@")
    ]
}
