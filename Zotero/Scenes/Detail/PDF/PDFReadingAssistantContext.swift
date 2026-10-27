//
//  PDFReadingAssistantContext.swift
//  Zotero
//

import CryptoKit
import Foundation

enum PDFReadingAssistantScope: String, CaseIterable, Identifiable {
    case document = "全文", page = "当前页", selection = "选中文本"
    var id: String { rawValue }
}

struct PDFReadingAssistantPage {
    let number: Int
    let text: String
}

struct PDFReadingAssistantContext {
    let text: String
    let description: String
    let pages: [Int]
    let isExcerpt: Bool

    /// Keep physical page numbers intact. Long PDFs use distributed excerpts for summaries and relevance-ranked chunks for questions.
    static func build(pages: [PDFReadingAssistantPage], scope: PDFReadingAssistantScope, question: String, currentPage: Int,
                      totalPages: Int, extractionLimited: Bool = false, limit: Int = 48000) throws -> Self {
        struct Chunk {
            let page: Int
            let text: String
            let index: Int
        }
        var chunks: [Chunk] = []
        for page in pages {
            let text = page.text.trimmingCharacters(in: .whitespacesAndNewlines)
            var start = text.startIndex
            while start < text.endIndex {
                let end = text.index(start, offsetBy: 1800, limitedBy: text.endIndex) ?? text.endIndex
                chunks.append(Chunk(page: page.number, text: String(text[start..<end]), index: chunks.count))
                start = end
            }
        }
        guard !chunks.isEmpty else {
            throw PDFReadingAssistantError.message(scope == .selection ? "请先在 PDF 中选择可复制的文字。" : "此范围没有可提取的文字。扫描 PDF 需要先完成 OCR；图片和公式不会自动转成文字。")
        }
        let allSize = chunks.reduce(0) { $0 + $1.text.count + 32 }
        var ordered = chunks
        if allSize > limit {
            let terms = Set(question.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { $0.count >= 2 })
            let summary = ["总结", "概括", "问题", "summary", "summarize", "overview"].contains { question.lowercased().contains($0) }
            if summary {
                // Sample across the entire paper, rather than silently sending only its beginning.
                let count = max(1, min(chunks.count, limit / 1900))
                let positions = Set((0..<count).map { count == 1 ? 0 : $0 * (chunks.count - 1) / (count - 1) })
                ordered = chunks.filter { positions.contains($0.index) }
            } else {
                func score(_ chunk: Chunk) -> Int {
                    let lower = chunk.text.lowercased()
                    return terms.reduce(0) { $0 + (lower.contains($1) ? 5 : 0) } + (chunk.page == currentPage ? 2 : 0) + (chunk.index == 0 ? 1 : 0)
                }
                let scores = Dictionary(uniqueKeysWithValues: chunks.map { ($0.index, score($0)) })
                ordered.sort { lhs, rhs in
                    let first = scores[lhs.index] ?? 0, second = scores[rhs.index] ?? 0
                    return first == second ? lhs.index < rhs.index : first > second
                }
            }
        }
        var selected: [Chunk] = []
        var remaining = max(0, limit)
        for chunk in ordered {
            let cost = chunk.text.count + 32
            if cost <= remaining {
                selected.append(chunk)
                remaining -= cost
            } else if selected.isEmpty, remaining > 64 {
                selected.append(Chunk(page: chunk.page, text: String(chunk.text.prefix(remaining - 32)), index: chunk.index))
                break
            }
        }
        guard !selected.isEmpty else { throw PDFReadingAssistantError.message("文档上下文预算不足。") }
        selected.sort { $0.index < $1.index }
        let covered = Array(Set(selected.map(\.page))).sorted()
        let excerpt = extractionLimited || selected.reduce(0, { $0 + $1.text.count }) < chunks.reduce(0, { $0 + $1.text.count })
        let description: String
        if scope == .document {
            description = excerpt ? "全文节选：本次覆盖 \(covered.count)/\(totalPages) 页，未发送完整全文" : "全文文本：\(covered.count)/\(totalPages) 页含可提取文字"
        } else {
            description = "\(scope.rawValue)：PDF 第 \(covered.map(String.init).joined(separator: "、")) 页" + (excerpt ? "（节选）" : "")
        }
        let text = description + "\n" + selected.map { "[PDF 第 \($0.page) 页]\n\($0.text)" }.joined(separator: "\n\n")
        return Self(text: text, description: description, pages: covered, isExcerpt: excerpt)
    }
}

/// Chat stays in this app, separated by library/attachment. Neither PDF context nor API credentials are saved in the transcript.
struct PDFReadingAssistantHistory {
    let url: URL

    init(documentID: String, directory: URL? = nil) {
        let root = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("ReadingAI", isDirectory: true)
        let hash = SHA256.hash(data: Data(documentID.utf8)).map { String(format: "%02x", $0) }.joined()
        url = root.appendingPathComponent(hash + ".json")
    }

    func load() -> [PDFReadingAssistantMessage] {
        guard let data = try? Data(contentsOf: url), data.count < 8_000_000,
              let messages = try? JSONDecoder().decode([PDFReadingAssistantMessage].self, from: data) else { return [] }
        return messages.map { message in
            var value = message
            if value.status == .streaming { value.status = .stopped }
            return value
        }
    }

    func save(_ messages: [PDFReadingAssistantMessage]) throws {
        let manager = FileManager.default
        let folder = url.deletingLastPathComponent()
        try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        var excluded = URLResourceValues()
        excluded.isExcludedFromBackup = true
        var folderURL = folder
        try folderURL.setResourceValues(excluded)
        var retained: [PDFReadingAssistantMessage] = []
        var remainingBytes = 4_000_000
        for message in messages.suffix(120).reversed() {
            let cost = message.content.utf8.count + 512
            guard cost <= remainingBytes else { break }
            retained.append(message)
            remainingBytes -= cost
        }
        let data = try JSONEncoder().encode(Array(retained.reversed()))
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    func clear() throws {
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }
}
