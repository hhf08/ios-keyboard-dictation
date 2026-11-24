import Foundation

struct T9Candidate {
    let text: String
    let pinyin: String
    let consumed: Int
}

/// Pinyin nine-key lookup backed by a bundled table: `digits<TAB>word,pin'yin word,pin'yin ...`
final class T9Engine {
    static let letters: [Character: String] = [
        "2": "abc", "3": "def", "4": "ghi", "5": "jkl",
        "6": "mno", "7": "pqrs", "8": "tuv", "9": "wxyz",
    ]

    private var table: [String: String] = [:]
    private(set) var isLoaded = false
    private let lock = NSLock()

    func loadAsync(completion: @escaping () -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            var dict: [String: String] = [:]
            if let url = Bundle(for: T9Engine.self).url(forResource: "t9", withExtension: "txt"),
               let content = try? String(contentsOf: url, encoding: .utf8) {
                dict.reserveCapacity(90_000)
                content.enumerateLines { line, _ in
                    if let tab = line.firstIndex(of: "\t") {
                        dict[String(line[..<tab])] = String(line[line.index(after: tab)...])
                    }
                }
            }
            self.lock.lock()
            self.table = dict
            self.isLoaded = true
            self.lock.unlock()
            DispatchQueue.main.async { completion() }
        }
    }

    private func entries(for digits: String) -> [(String, String)] {
        lock.lock()
        let raw = table[digits]
        lock.unlock()
        guard let raw else { return [] }
        return raw.split(separator: " ").compactMap { item in
            guard let comma = item.lastIndex(of: ",") else { return nil }
            return (String(item[..<comma]), String(item[item.index(after: comma)...]))
        }
    }

    /// Candidates for the digit buffer: full matches first, then shorter prefixes.
    func candidates(for digits: String, pinyinFilter: String? = nil) -> [T9Candidate] {
        guard !digits.isEmpty else { return [] }
        var result: [T9Candidate] = []
        var seen = Set<String>()
        var length = digits.count
        while length > 0 {
            let prefix = String(digits.prefix(length))
            var list = entries(for: prefix)
            if let pinyinFilter, length == digits.count {
                list = list.filter { $0.1 == pinyinFilter }
            } else if let pinyinFilter {
                let first = pinyinFilter.split(separator: "'").first.map(String.init) ?? pinyinFilter
                list = list.filter { $0.1.hasPrefix(first) }
            }
            let limit = length == digits.count ? 60 : 25
            for (word, py) in list.prefix(limit) where !seen.contains(word) {
                seen.insert(word)
                result.append(T9Candidate(text: word, pinyin: py, consumed: length))
            }
            if result.count > 120 { break }
            length -= 1
        }
        return result
    }

    /// Distinct pinyin spellings for the full buffer, used for the spelling bar.
    func pinyinOptions(for digits: String) -> [String] {
        guard !digits.isEmpty else { return [] }
        var options: [String] = []
        for (_, py) in entries(for: digits) where !options.contains(py) {
            options.append(py)
            if options.count >= 12 { break }
        }
        if options.isEmpty {
            // Fall back to the first letters of each key.
            options.append(String(digits.compactMap { T9Engine.letters[$0]?.first }))
        }
        return options
    }
}
