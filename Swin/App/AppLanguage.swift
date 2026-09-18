import Foundation

/// 手动语言选择（覆盖系统语言）。
///
/// iOS 在启动时读 `AppleLanguages` 这个 UserDefault 决定 app 用哪个 .lproj。
/// 写入它 → 下次启动整个 app（界面文案 + 模型层 String(localized:) + 教练话术
/// 的 prefersChinese，它走 Bundle.preferredLocalizations）全部用所选语言，
/// 一致切换、**不会中英混着**（避免即时切换导致 SwiftUI Text 和 Foundation
/// 字符串各自一半的问题）。所以切换需重开 app 生效。
enum AppLanguage {
    private static let appleKey = "AppleLanguages"          // iOS 启动读这个
    private static let markKey  = "app.language.manual"     // 旧版手动选择的遗留 key

    /// 语言不再手动选择：清掉任何旧的覆盖，让 app 跟随系统语言。首启调用。
    /// （旧版曾写入 AppleLanguages 覆盖；清掉后，iOS 会按系统语言在
    /// Localizable.xcstrings 的可用本地化里自动挑最匹配的。）
    static func followSystem() {
        let d = UserDefaults.standard
        if d.object(forKey: markKey) != nil || d.object(forKey: appleKey) != nil {
            d.removeObject(forKey: markKey)
            d.removeObject(forKey: appleKey)
        }
    }
}
