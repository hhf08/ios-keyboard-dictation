import Foundation

/// Symbol page content: tabs (中文 / 英文 / 表情), each with categories shown in the left column.
enum SymbolData {
    struct Category {
        let name: String
        let items: [String]
    }

    struct Tab {
        let name: String
        let categories: [Category]
    }

    private static func c(_ name: String, _ list: String) -> Category {
        Category(name: name, items: list.split(separator: " ").map(String.init))
    }

    static let tabs: [Tab] = [
        Tab(name: "中文", categories: [
            c("常用", "， 。 ？ ！ 、 ： ； “ ” ‘ ’ （ ） 《 》 …… —— ～ · ￥ ％ ＠ ＃ ＆ ＊"),
            c("括号", "（ ） 【 】 《 》 〈 〉 「 」 『 』 〔 〕 ［ ］ ｛ ｝ 〖 〗 “ ” ‘ ’"),
            c("数学", "＋ － × ÷ ＝ ≠ ≈ ± ＜ ＞ ≤ ≥ ∞ √ ∑ ∏ ∫ ∵ ∴ ％ ‰ ° ′ ″ π ∠ ⊥ ∥ ∈ ∩ ∪"),
            c("单位", "℃ ℉ ￥ $ € £ ¥ ㎡ ㎏ ㎞ ㎝ ㎜ ㏄ ㎎ ㎖ ㎎ ㏕ ‰ ‱"),
            c("序号", "① ② ③ ④ ⑤ ⑥ ⑦ ⑧ ⑨ ⑩ ⑴ ⑵ ⑶ ⑷ ⑸ ㈠ ㈡ ㈢ ㈣ ㈤ Ⅰ Ⅱ Ⅲ Ⅳ Ⅴ Ⅵ Ⅶ Ⅷ Ⅸ Ⅹ"),
            c("箭头", "→ ← ↑ ↓ ↖ ↗ ↘ ↙ ⇒ ⇐ ⇔ ↔ ↕ ➜ ➤ ➔ ⇧ ⇩ ↻ ↺"),
            c("特殊", "※ § № ☆ ★ ○ ● ◎ ◇ ◆ □ ■ △ ▲ ▽ ▼ ♀ ♂ ♪ ♫ ✓ ✔ ✗ ✘ ☑ ☒ ♠ ♥ ♣ ♦ ☀ ☁ ☂ ☎ ✉ ✈"),
        ]),
        Tab(name: "英文", categories: [
            c("常用", ", . ? ! ' \" : ; @ # & * - _ / \\ | ~ ` ^"),
            c("括号", "( ) [ ] { } < > « » ‹ ›"),
            c("数学", "+ - * / = % < > ± × ÷ ^ √ ∞ π ° ≠ ≈ ≤ ≥"),
            c("货币", "$ € £ ¥ ₩ ₽ ¢ ₹ ₺ ₿ ₫ ₱ ₴"),
            c("网址", ".com .cn .net .org www. http:// https:// @gmail.com @qq.com @163.com"),
        ]),
        Tab(name: "表情", categories: [
            c("笑脸", "😀 😃 😄 😁 😆 😂 🤣 😊 😇 🙂 😉 😍 🥰 😘 😋 😜 🤪 😎 🤩 🥳 😏 😌 😴 🤤 😪 🤗 🤭 🤫 🤔 😐 🙄 😬"),
            c("情绪", "😢 😭 😤 😠 😡 🤬 😱 😨 😰 😥 😓 😩 😫 🥺 😳 🤯 😵 🥴 😷 🤒 🤕 🤢 🤮 🥶 🥵 😈 👻 💀 💩 🤡"),
            c("手势", "👍 👎 👏 🙌 👐 🤝 🙏 ✌️ 🤞 🤟 🤘 👌 🤏 👈 👉 👆 👇 ☝️ ✋ 🤚 🖐 🖖 👋 🤙 💪 ✍️ 👊 ✊"),
            c("爱心", "❤️ 🧡 💛 💚 💙 💜 🖤 🤍 🤎 💔 ❣️ 💕 💞 💓 💗 💖 💘 💝 💟 🌹 🌷 🌸 💐 💋 💌"),
            c("物品", "🎉 🎊 🎁 🎂 🍰 🧧 🏮 🔥 ✨ 🌟 ⭐ 💯 💢 💤 💦 ☕ 🍵 🍺 🍻 🍉 🍎 🍜 🍚 🧋 ⚽ 🏀 🎮 📱 💰 🚗"),
            c("动物", "🐶 🐱 🐭 🐹 🐰 🦊 🐻 🐼 🐨 🐯 🦁 🐮 🐷 🐸 🐵 🙈 🙉 🙊 🐔 🐧 🐦 🐤 🦆 🐟 🐳 🐬 🦋 🐌 🐞 🐲"),
            c("颜文字", "^_^ ^o^ (^_^) (*^▽^*) (￣▽￣) (╯▽╰) o(╥﹏╥)o (T_T) (>_<) (=^･ω･^=) ╮(╯▽╰)╭ (｡･ω･｡) ヽ(✿ﾟ▽ﾟ)ノ (๑•̀ㅂ•́)و✧ (ﾉ>ω<)ﾉ ┑(￣Д￣)┍ (｀・ω・´) Σ(っ°Д°;)っ (づ｡◕‿‿◕｡)づ (￣︶￣)↗"),
        ]),
    ]

    /// Quick punctuation for the nine-key left column.
    static let quickChinese = ["，", "。", "？", "！", "、", "：", "；", "～", "……", "“", "”", "@"]
    /// Number page left column.
    static let numberSide = ["+", "-", "*", "/", "=", "%", ":", "(", ")", "#", ",", "~"]
}
