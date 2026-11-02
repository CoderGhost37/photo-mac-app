import Foundation

public enum CLIPTokenizerError: Error, Equatable {
    case unreadableVocabulary
}

/// OpenAI CLIP byte-pair encoder. The merge list is the file `Scripts/fetch-clip.sh` installs; tests can pass a tiny list.
public struct CLIPTokenizer: Sendable {
    public let startOfText: Int32
    public let endOfText: Int32
    public let contextLength: Int

    private let byteSymbols: [UInt8: String]
    private let encoder: [String: Int]
    private let ranks: [Pair: Int]

    public init(mergesText: String, contextLength: Int = ClipModel.contextLength) {
        let parsed = Self.vocabulary(from: mergesText)
        byteSymbols = parsed.bytes
        encoder = parsed.encoder
        ranks = parsed.ranks
        startOfText = Int32(parsed.encoder["<|startoftext|>"] ?? 0)
        endOfText = Int32(parsed.encoder["<|endoftext|>"] ?? 0)
        self.contextLength = contextLength
    }

    public init(vocabularyAt url: URL, contextLength: Int = ClipModel.contextLength) throws {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            throw CLIPTokenizerError.unreadableVocabulary
        }
        self.init(mergesText: text, contextLength: contextLength)
    }

    /// Token ids padded to `contextLength`. Position 0 is start-of-text and the real text ends at end-of-text.
    public func encode(_ text: String) -> [Int32] {
        var ids = [startOfText]
        ids.append(contentsOf: pieceIDs(for: text))
        ids.append(endOfText)
        if ids.count > contextLength {
            ids = Array(ids.prefix(contextLength))
            ids[ids.count - 1] = endOfText
        }
        if ids.count < contextLength {
            ids.append(contentsOf: Array(repeating: 0, count: contextLength - ids.count))
        }
        return ids
    }

    func pieceIDs(for text: String) -> [Int32] {
        var ids: [Int32] = []
        for token in Self.clipTokens(in: Self.clean(text)) {
            let symbols = token.utf8.map { byteSymbols[$0] ?? "" }.joined()
            for piece in bpe(symbols) {
                if let id = encoder[piece] {
                    ids.append(Int32(id))
                }
            }
        }
        return ids
    }

    private func bpe(_ token: String) -> [String] {
        let characters = Array(token).map(String.init)
        guard let last = characters.last else { return [] }
        if characters.count == 1 {
            return [last + "</w>"]
        }
        var word = characters
        word[word.count - 1] = last + "</w>"
        var pairSet = Self.pairs(in: word)
        if pairSet.isEmpty { return [token + "</w>"] }
        while true {
            var best: Pair?
            var bestRank = Int.max
            for pair in pairSet {
                if let rank = ranks[pair], rank < bestRank {
                    bestRank = rank
                    best = pair
                }
            }
            guard let bigram = best else { break }
            var merged: [String] = []
            var index = 0
            while index < word.count {
                guard let found = word[index...].firstIndex(of: bigram.left) else {
                    merged.append(contentsOf: word[index...])
                    break
                }
                merged.append(contentsOf: word[index..<found])
                index = found
                if index < word.count - 1, word[index] == bigram.left, word[index + 1] == bigram.right {
                    merged.append(bigram.left + bigram.right)
                    index += 2
                } else {
                    merged.append(word[index])
                    index += 1
                }
            }
            word = merged
            if word.count == 1 { break }
            pairSet = Self.pairs(in: word)
        }
        return word
    }

    private static func pairs(in word: [String]) -> Set<Pair> {
        guard word.count >= 2 else { return [] }
        var result = Set<Pair>()
        for index in 1..<word.count {
            result.insert(Pair(left: word[index - 1], right: word[index]))
        }
        return result
    }

    private static func clean(_ text: String) -> String {
        var value = text.precomposedStringWithCanonicalMapping
        for _ in 0..<2 {
            value = value.replacingOccurrences(of: "&lt;", with: "<")
            value = value.replacingOccurrences(of: "&gt;", with: ">")
            value = value.replacingOccurrences(of: "&quot;", with: "\"")
            value = value.replacingOccurrences(of: "&#39;", with: "'")
            value = value.replacingOccurrences(of: "&apos;", with: "'")
            value = value.replacingOccurrences(of: "&nbsp;", with: " ")
            value = value.replacingOccurrences(of: "&amp;", with: "&")
        }
        return value.split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased()
    }

    private static func clipTokens(in text: String) -> [String] {
        guard let pattern = try? NSRegularExpression(
            pattern: #"<\|startoftext\|>|<\|endoftext\|>|'s|'t|'re|'ve|'m|'ll|'d|\p{L}+|\p{N}|[^\s\p{L}\p{N}]+"#,
            options: [.caseInsensitive]
        ) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return pattern.matches(in: text, range: range).compactMap { match in
            Range(match.range, in: text).map { String(text[$0]) }
        }
    }

    private static func vocabulary(from text: String) -> (bytes: [UInt8: String], encoder: [String: Int], ranks: [Pair: Int]) {
        let symbols = byteSymbols()
        var lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map {
            $0.trimmingCharacters(in: .init(charactersIn: "\r"))
        }
        if !lines.isEmpty { lines.removeFirst() }
        while lines.last?.isEmpty == true { lines.removeLast() }
        if lines.count > ClipModel.bpeMergeCount {
            lines = Array(lines.prefix(ClipModel.bpeMergeCount))
        }
        var merges: [Pair] = []
        merges.reserveCapacity(lines.count)
        for line in lines {
            let parts = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            guard parts.count == 2 else { continue }
            merges.append(Pair(left: String(parts[0]), right: String(parts[1])))
        }
        var vocab = symbols.ordered
        vocab.append(contentsOf: symbols.ordered.map { $0 + "</w>" })
        vocab.append(contentsOf: merges.map { $0.left + $0.right })
        vocab.append("<|startoftext|>")
        vocab.append("<|endoftext|>")
        var encoder: [String: Int] = [:]
        encoder.reserveCapacity(vocab.count)
        for (index, token) in vocab.enumerated() {
            encoder[token] = index
        }
        var ranks: [Pair: Int] = [:]
        ranks.reserveCapacity(merges.count)
        for (index, pair) in merges.enumerated() {
            ranks[pair] = index
        }
        return (symbols.map, encoder, ranks)
    }

    private static func byteSymbols() -> (map: [UInt8: String], ordered: [String]) {
        var identity: [Int] = []
        identity.append(contentsOf: Array(33...126))
        identity.append(contentsOf: Array(161...172))
        identity.append(contentsOf: Array(174...255))
        var codePoints = identity
        var extra = 256
        var present = Set(identity)
        var bytes: [Int] = identity
        for byte in 0..<256 where !present.contains(byte) {
            bytes.append(byte)
            codePoints.append(extra)
            extra += 1
        }
        var map: [UInt8: String] = [:]
        var ordered: [String] = []
        ordered.reserveCapacity(bytes.count)
        for (byte, code) in zip(bytes, codePoints) {
            let symbol = UnicodeScalar(code).map(String.init) ?? ""
            map[UInt8(byte)] = symbol
            ordered.append(symbol)
        }
        return (map, ordered)
    }
}

private struct Pair: Hashable {
    var left: String
    var right: String
}
