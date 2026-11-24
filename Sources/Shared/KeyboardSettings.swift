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
        static let micPrewarm = "micPrewarmV2"
        static let onDevice = "onDeviceRecognitionV2"
        static let holdDelay = "holdDelay"
        static let clipboard = "clipboardHistory"
        static let inlineCompat = "inlineCompat"
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

    /// Opens the microphone when the keyboard appears (keeps it occupied while visible). Off by default;
    /// the microphone is released after every dictation even when this is on.
    static var micPrewarm: Bool {
        get { defaults.object(forKey: Key.micPrewarm) as? Bool ?? false }
        set { defaults.set(newValue, forKey: Key.micPrewarm) }
    }

    /// Prefer on-device recognition when the system supports it (faster); falls back to the server.
    static var onDeviceRecognition: Bool {
        get { defaults.object(forKey: Key.onDevice) as? Bool ?? true }
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

    /// Live dictation text: false = marked text updated in place (default);
    /// true = delete the previous partial and insert the new one (for apps that mishandle marked text).
    static var inlineCompat: Bool {
        get { defaults.object(forKey: Key.inlineCompat) as? Bool ?? false }
        set { defaults.set(newValue, forKey: Key.inlineCompat) }
    }

    static var clipboardHistory: [String] {
        get { defaults.stringArray(forKey: Key.clipboard) ?? [] }
        set { defaults.set(Array(newValue.prefix(20)), forKey: Key.clipboard) }
    }
}
