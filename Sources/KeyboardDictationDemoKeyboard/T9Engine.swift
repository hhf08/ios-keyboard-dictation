import Foundation

struct T9Candidate {
    let text: String
    let pinyin: String
    /// Number of keys (digits or letters, separators not counted) this candidate consumes.
    let consumed: Int
}

/// Pinyin lookup backed by a bundled table (from rime-ice): `digits<TAB>word,pin'yin word,pin'yin ...`.
/// Serves both nine-key input (digits) and full pinyin (letters are mapped to their digits and
/// then matched exactly against each entry's pinyin), so one table covers both layouts.
final class T9Engine {
    static let letters: [Character: String] = [
        "2": "abc", "3": "def", "4": "ghi", "5": "jkl",
        "6": "mno", "7": "pqrs", "8": "tuv", "9": "wxyz",
    ]
    static let digitForLetter: [Character: Character] = {
        var map: [Character: Character] = [:]
        for (digit, letters) in letters {
            for l in letters { map[l] = digit }
        }
        return map
    }()

    private var table: [String: String] = [:]
    /// Digit prefix → common single characters whose syllable starts with it (incomplete syllables).
    private var prefixChars: [String: [(String, String)]] = [:]
    private(set) var isLoaded = false
    private let lock = NSLock()

    func loadAsync(completion: @escaping () -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            var dict: [String: String] = [:]
            var ranked: [String: [(Int, String, String)]] = [:]
            if let url = Bundle(for: T9Engine.self).url(forResource: "t9", withExtension: "txt"),
               let content = try? String(contentsOf: url, encoding: .utf8) {
                dict.reserveCapacity(90_000)
                content.enumerateLines { line, _ in
                    guard let tab = line.firstIndex(of: "\t") else { return }
                    let key = String(line[..<tab])
                    let value = String(line[line.index(after: tab)...])
                    dict[key] = value
                    guard key.count >= 2, key.count <= 6 else { return }
                    var rank = 0
                    for part in value.split(separator: " ") {
                        guard rank < 6 else { break }
                        guard let comma = part.firstIndex(of: ",") else { continue }
                        let word = part[..<comma]
                        let py = part[part.index(after: comma)...]
                        guard word.count == 1, !py.contains("'") else { continue }
                        for n in 1..<key.count {
                            ranked[String(key.prefix(n)), default: []].append((rank, String(word), String(py)))
                        }
                        rank += 1
                    }
                }
            }
            var prefix: [String: [(String, String)]] = [:]
            for (k, list) in ranked {
                prefix[k] = list.sorted { $0.0 < $1.0 }.prefix(80).map { ($0.1, $0.2) }
            }
            self.lock.lock()
            self.table = dict
            self.prefixChars = prefix
            self.isLoaded = true
            self.lock.unlock()
            DispatchQueue.main.async { completion() }
        }
    }

    // MARK: - Helpers

    struct Parsed {
        var keys: [Character] = []
        var boundaries: Set<Int> = []
    }

    /// Splits user input into keys and the separator (分词) positions.
    static func parse(_ input: String) -> Parsed {
        var p = Parsed()
        for ch in input {
            if ch == "'" {
                if !p.keys.isEmpty { p.boundaries.insert(p.keys.count) }
            } else {
                p.keys.append(ch)
            }
        }
        return p
    }

    static func keyCount(_ input: String) -> Int { input.filter { $0 != "'" }.count }

    /// Removes the first `n` keys (and any separators that follow them).
    static func drop(keys n: Int, from input: String) -> String {
        var count = 0
        var idx = input.startIndex
        while idx < input.endIndex, count < n {
            if input[idx] != "'" { count += 1 }
            idx = input.index(after: idx)
        }
        var rest = input[idx...]
        while rest.first == "'" { rest = rest.dropFirst() }
        return String(rest)
    }

    static func boundaries(of pinyin: String) -> Set<Int> {
        var set = Set<Int>()
        var count = 0
        for ch in pinyin {
            if ch == "'" { set.insert(count) } else { count += 1 }
        }
        return set
    }

    private func entries(for digits: String) -> [(String, String)] {
        lock.lock()
        let raw = table[digits]
        lock.unlock()
        guard let raw else { return [] }
        var out: [(String, String)] = []
        for part in raw.split(separator: " ") {
            guard let comma = part.firstIndex(of: ",") else { continue }
            out.append((String(part[..<comma]), String(part[part.index(after: comma)...])))
        }
        return out
    }

    private func completions(for digits: String) -> [(String, String)] {
        lock.lock()
        defer { lock.unlock() }
        return prefixChars[digits] ?? []
    }

    private func filterMatches(_ py: String, _ f: String) -> Bool {
        py == f || py.hasPrefix(f + "'") || f.hasPrefix(py + "'") || (f.count == 1 && py.hasPrefix(f))
    }

    // MARK: - Lookup

    /// Candidates for the composition: full matches first, then incomplete-syllable completions,
    /// then shorter prefixes (which commit part of the input).
    func candidates(input: String, fullPinyin: Bool, pinyinFilter: String? = nil) -> [T9Candidate] {
        let parsed = Self.parse(fullPinyin ? input.lowercased() : input)
        let keys = parsed.keys
        guard !keys.isEmpty else { return [] }
        let letters = fullPinyin ? String(keys) : ""
        let digits = fullPinyin ? String(keys.map { Self.digitForLetter[$0] ?? "1" }) : String(keys)
        var result: [T9Candidate] = []
        var seen = Set<String>()

        func accepts(_ py: String, length: Int) -> Bool {
            if fullPinyin, py.replacingOccurrences(of: "'", with: "") != String(letters.prefix(length)) { return false }
            if !parsed.boundaries.isEmpty {
                let b = Self.boundaries(of: py)
                for x in parsed.boundaries where x < length && !b.contains(x) { return false }
            }
            if let f = pinyinFilter, !filterMatches(py, f) { return false }
            return true
        }

        var length = keys.count
        while length > 0 {
            let limit = length == keys.count ? 90 : 30
            var added = 0
            for (word, py) in entries(for: String(digits.prefix(length))) {
                if added >= limit { break }
                guard !seen.contains(word), accepts(py, length: length) else { continue }
                seen.insert(word)
                result.append(T9Candidate(text: word, pinyin: py, consumed: length))
                added += 1
            }
            if length == keys.count, parsed.boundaries.isEmpty, keys.count <= 5 {
                // The whole input may be the start of one syllable (e.g. "zh", "xia").
                var extra = 0
                for (word, py) in completions(for: digits) {
                    if extra >= 30 { break }
                    if fullPinyin, !py.hasPrefix(letters) { continue }
                    if let f = pinyinFilter, !(py.hasPrefix(f) || f.hasPrefix(py)) { continue }
                    guard !seen.contains(word) else { continue }
                    seen.insert(word)
                    result.append(T9Candidate(text: word, pinyin: py, consumed: length))
                    extra += 1
                }
            }
            if result.count > 160 { break }
            length -= 1
        }
        return result
    }

    /// Spelling choices for nine-key input, shown in the left column: full spellings,
    /// then possible first syllables, then the single letters of the first key.
    func pinyinOptions(input: String) -> [String] {
        let parsed = Self.parse(input)
        let keys = parsed.keys
        guard !keys.isEmpty else { return [] }
        let digits = String(keys)
        var options: [String] = []
        func add(_ s: String) { if !s.isEmpty, !options.contains(s) { options.append(s) } }

        for (_, py) in entries(for: digits) {
            if options.count >= 8 { break }
            if !parsed.boundaries.isEmpty {
                let b = Self.boundaries(of: py)
                if parsed.boundaries.contains(where: { $0 < keys.count && !b.contains($0) }) { continue }
            }
            add(py)
        }
        var length = keys.count
        while length > 0, options.count < 18 {
            for (_, py) in entries(for: String(digits.prefix(length))) {
                if options.count >= 18 { break }
                add(py.split(separator: "'").first.map(String.init) ?? py)
            }
            length -= 1
        }
        if let first = keys.first, let ls = Self.letters[first] {
            for l in ls { add(String(l)) }
        }
        return options
    }
}
