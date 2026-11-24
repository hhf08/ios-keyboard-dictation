import Foundation

/// 中文键盘布局
enum ChineseLayout: String {
    case t9
    case qwerty
}

/// Settings shared between the container app and the keyboard extension.
/// Stored in the App Group suite when it is available, otherwise in the process's own defaults
/// (the keyboard also exposes these settings in its own ⚙︎ panel, so they work either way).
enum KeyboardSettings {
    static let appGroup = "group.net.stupidtech.keyboard-dictation-demo"

    enum Key {
        static let layout = "layout"
        static let haptics = "haptics"
        static let micPrewarm = "micPrewarm"
        static let onDevice = "onDeviceRecognition"
        static let holdDelay = "holdDelay"
        static let clipboard = "clipboardHistory"
    }

    static var defaults: UserDefaults {
        UserDefaults(suiteName: appGroup) ?? .standard
    }

    static var layout: ChineseLayout {
        get { ChineseLayout(rawValue: defaults.string(forKey: Key.layout) ?? "") ?? .t9 }
        set { defaults.set(newValue.rawValue, forKey: Key.layout) }
    }

    static var haptics: Bool {
        get { defaults.object(forKey: Key.haptics) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.haptics) }
    }

    /// Keep the microphone stream open while the keyboard is visible so dictation starts instantly.
    static var micPrewarm: Bool {
        get { defaults.object(forKey: Key.micPrewarm) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.micPrewarm) }
    }

    static var onDeviceRecognition: Bool {
        get { defaults.object(forKey: Key.onDevice) as? Bool ?? false }
        set { defaults.set(newValue, forKey: Key.onDevice) }
    }

    /// Seconds the space bar must be held before dictation starts.
    static var holdDelay: Double {
        get {
            let v = defaults.double(forKey: Key.holdDelay)
            return v > 0.05 ? v : 0.2
        }
        set { defaults.set(newValue, forKey: Key.holdDelay) }
    }

    static var clipboardHistory: [String] {
        get { defaults.stringArray(forKey: Key.clipboard) ?? [] }
        set { defaults.set(Array(newValue.prefix(20)), forKey: Key.clipboard) }
    }
}
