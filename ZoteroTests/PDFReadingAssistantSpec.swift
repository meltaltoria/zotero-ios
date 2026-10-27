//
//  PDFReadingAssistantSpec.swift
//  ZoteroTests
//

import UIKit
import XCTest

@testable import Zotero

final class PDFReadingAssistantSpec: XCTestCase {
    func testDeepSeekRequestUsesExpectedRouteAndNoKeyInBody() throws {
        let configuration = PDFReadingAssistantConfiguration(endpoint: "https://api.deepseek.com/", model: "deepseek-flash", apiKey: "test-not-a-real-key")
        let request = try PDFReadingAssistantService.request(configuration: configuration, messages: [.init(role: "user", content: "Explain LiCoO2")])
        XCTAssertEqual(request.url?.absoluteString, "https://api.deepseek.com/chat/completions")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-not-a-real-key")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertEqual(body["stream"] as? Bool, true)
        XCTAssertEqual(body["model"] as? String, "deepseek-flash")
        XCTAssertEqual((body["thinking"] as? [String: String])?["type"], "disabled")
        XCTAssertFalse(String(data: request.httpBody!, encoding: .utf8)!.contains("test-not-a-real-key"))
        let complete = PDFReadingAssistantConfiguration(endpoint: "https://example.com/v1/chat/completions", model: "custom", apiKey: "test")
        XCTAssertEqual(try complete.validatedURL().path, "/v1/chat/completions")
    }

    func testRejectsUnsafeOrAmbiguousEndpointsBeforeSendingKey() {
        for endpoint in ["http://example.com/v1", "https://user:pass@example.com/v1", "https://example.com/v1?key=value", "https://example.com/#fragment", "not-a-url"] {
            XCTAssertThrowsError(try PDFReadingAssistantConfiguration(endpoint: endpoint, model: "model", apiKey: "test").validatedURL())
        }
        XCTAssertThrowsError(try PDFReadingAssistantConfiguration(endpoint: "https://api.deepseek.com", model: "", apiKey: "test").validatedURL())
        XCTAssertThrowsError(try PDFReadingAssistantConfiguration(endpoint: "https://api.deepseek.com", model: "deepseek-flash", apiKey: "").validatedURL())
    }

    func testHistoryBudgetExcludesIncompleteResponsesAndOrphanAnswers() {
        let history = [PDFReadingAssistantMessage(role: "user", content: "old question"),
                       PDFReadingAssistantMessage(role: "assistant", content: "old answer"),
                       PDFReadingAssistantMessage(role: "user", content: "recent question"),
                       PDFReadingAssistantMessage(role: "assistant", content: "partial", status: .failed)]
        let messages = PDFReadingAssistantService.messages(context: "[PDF 第 7 页] evidence", history: history, question: "new question", historyLimit: 26)
        XCTAssertEqual(messages.map(\.role), ["system", "user", "user"])
        XCTAssertEqual(messages[1].content, "recent question")
        XCTAssertTrue(messages[0].content.contains("[PDF 第 7 页] evidence"))
        XCTAssertFalse(messages.contains(where: { $0.content == "partial" }))
    }

    func testStreamDecoderReadsPublicAnswerAndRejectsErrors() throws {
        XCTAssertEqual(try PDFReadingAssistantService.content(from: #"{"choices":[{"delta":{"content":"结果见第 2 页","reasoning_content":"private reasoning"}}]}"#), "结果见第 2 页")
        XCTAssertNil(try PDFReadingAssistantService.content(from: #"{"choices":[{"delta":{"reasoning_content":"private reasoning"}}]}"#))
        XCTAssertNil(try PDFReadingAssistantService.content(from: "[DONE]"))
        XCTAssertThrowsError(try PDFReadingAssistantService.content(from: #"{"error":{"message":"provider body should not be exposed"}}"#))
        XCTAssertThrowsError(try PDFReadingAssistantService.content(from: "not JSON"))
    }

    func testShortContextRetainsPhysicalPagesAndMarksEmptyScans() throws {
        let context = try PDFReadingAssistantContext.build(pages: [.init(number: 1, text: "Introduction"), .init(number: 2, text: ""), .init(number: 3, text: "Experimental results")],
                                                           scope: .document, question: "summary", currentPage: 3, totalPages: 3)
        XCTAssertEqual(context.pages, [1, 3])
        XCTAssertFalse(context.isExcerpt)
        XCTAssertTrue(context.text.contains("[PDF 第 3 页]"))
        XCTAssertTrue(context.description.contains("2/3"))
        XCTAssertThrowsError(try PDFReadingAssistantContext.build(pages: [.init(number: 1, text: "  \n")], scope: .page,
                                                                  question: "explain", currentPage: 1, totalPages: 1))
    }

    func testLongSummarySamplesAcrossPaperAndDisclosesTruncation() throws {
        let pages = (1...80).map { PDFReadingAssistantPage(number: $0, text: String(repeating: "page \($0) evidence ", count: 180)) }
        let context = try PDFReadingAssistantContext.build(pages: pages, scope: .document, question: "总结全文", currentPage: 1, totalPages: 80, limit: 9000)
        XCTAssertTrue(context.isExcerpt)
        XCTAssertTrue(context.description.contains("未发送完整全文"))
        XCTAssertTrue(context.pages.contains(1))
        XCTAssertTrue(context.pages.contains(80))
        XCTAssertLessThan(context.text.count, 9100)
    }

    func testLongQuestionPrioritizesRelevantPageWithoutRenumbering() throws {
        var pages = (1...20).map { PDFReadingAssistantPage(number: $0, text: String(repeating: "Background material. ", count: 150)) }
        pages[16] = .init(number: 17, text: String(repeating: "Lithium intercalation improves performance. ", count: 50))
        let context = try PDFReadingAssistantContext.build(pages: pages, scope: .document, question: "Explain lithium intercalation", currentPage: 1, totalPages: 20, limit: 4000)
        XCTAssertTrue(context.pages.contains(17))
        XCTAssertTrue(context.text.contains("[PDF 第 17 页]"))
        XCTAssertTrue(context.isExcerpt)
    }

    func testSelectionUsesOnlySuppliedSelectionText() throws {
        let context = try PDFReadingAssistantContext.build(pages: [.init(number: 8, text: "selected formula")], scope: .selection,
                                                           question: "explain", currentPage: 8, totalPages: 40)
        XCTAssertEqual(context.pages, [8])
        XCTAssertTrue(context.description.contains("选中文本"))
        XCTAssertFalse(context.text.contains("全文文本"))
    }

    func testHistorySeparatesDocumentsAndRestoresStoppedReplies() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = PDFReadingAssistantHistory(documentID: "my-library/AAAA", directory: directory)
        let second = PDFReadingAssistantHistory(documentID: "group-2/AAAA", directory: directory)
        XCTAssertNotEqual(first.url, second.url)
        try first.save([.init(role: "user", content: "question"), .init(role: "assistant", content: "partial answer", status: .streaming)])
        XCTAssertEqual(first.load().last?.status, .stopped)
        XCTAssertEqual(first.load().first?.content, "question")
        XCTAssertTrue(second.load().isEmpty)
        try first.clear()
        XCTAssertTrue(first.load().isEmpty)
    }

    @MainActor
    func testSidebarLeavesReadablePDFWidthOnIPad() {
        for width: CGFloat in [768, 834, 1024, 1366] {
            let panel = PDFKitReaderViewController.assistantPanelWidth(for: width)
            XCTAssertGreaterThanOrEqual(panel, 300)
            XCTAssertLessThanOrEqual(panel, 440)
            XCTAssertGreaterThanOrEqual(width - panel, 460)
        }
    }

    func testImportsLocalPDFWithoutDeletingOriginalOrDecodingFilenameTwice() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("中文 100%25 电池.PDF")
        let bytes = Data("%PDF-1.7 local test".utf8)
        try bytes.write(to: source)
        let destination = FileData(rootPath: directory.path, relativeComponents: ["storage", "NEWKEY"], name: "中文 100%25 电池", ext: "PDF")
        try LocalFileImporter.copy(from: source, to: destination, fileStorage: FileStorageController())
        XCTAssertEqual(try Data(contentsOf: source), bytes)
        XCTAssertEqual(try Data(contentsOf: destination.createUrl()), bytes)
        XCTAssertEqual(destination.createUrl().lastPathComponent, source.lastPathComponent)
    }

    func testImportRejectsDirectoriesAndMissingFiles() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = FileData(rootPath: directory.path, relativeComponents: [], name: "target", ext: "pdf")
        XCTAssertThrowsError(try LocalFileImporter.copy(from: directory, to: destination, fileStorage: FileStorageController()))
        XCTAssertThrowsError(try LocalFileImporter.copy(from: directory.appendingPathComponent("missing.pdf"), to: destination, fileStorage: FileStorageController()))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.createUrl().path))
    }
}
