//
//  PDFReadingAssistantSpec.swift
//  ZoteroTests
//

import PDFKit
import RealmSwift
import SwiftUI
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
        XCTAssertThrowsError(try PDFReadingAssistantService.content(from: #"{"choices":[{"delta":{},"finish_reason":"length"}]}"#))
    }

    func testStreamingHandlesKeepAlivesAndUnicodeByteBoundaries() async throws {
        let session = stubSession()
        defer { session.invalidateAndCancel() }
        let sink = AssistantAnswerSink()
        let configuration = PDFReadingAssistantConfiguration(endpoint: "https://example.test/success", model: "test-model", apiKey: "test")
        try await PDFReadingAssistantService.stream(configuration: configuration, messages: [.init(role: "user", content: "question")], session: session) {
            await sink.receive($0)
        }
        let answer = await sink.answer
        XCTAssertEqual(answer, "中文结果 😀")
    }

    func testStreamingRejectsAuthenticationFailureAndTruncatedReply() async {
        let session = stubSession()
        defer { session.invalidateAndCancel() }
        for path in ["bad-key", "truncated"] {
            let configuration = PDFReadingAssistantConfiguration(endpoint: "https://example.test/" + path, model: "test-model", apiKey: "test")
            do {
                try await PDFReadingAssistantService.stream(configuration: configuration, messages: [], session: session) { _ in }
                XCTFail("Invalid or interrupted stream must fail: \(path)")
            } catch {
                XCTAssertTrue(error is PDFReadingAssistantError)
                XCTAssertFalse(error.localizedDescription.contains("test-secret-provider-error"))
            }
        }
    }

    func testCancelledStreamDoesNotSucceed() async {
        let session = stubSession()
        defer { session.invalidateAndCancel() }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await PDFReadingAssistantService.stream(configuration: .init(endpoint: "https://example.test/success", model: "test-model", apiKey: "test"),
                                                        messages: [], session: session) { _ in }
        }
        do {
            try await task.value
            XCTFail("A cancelled stream must fail")
        } catch {
            XCTAssertTrue(error is CancellationError || (error as? URLError)?.code == .cancelled)
        }
    }

    private func stubSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AssistantStreamStub.self]
        return URLSession(configuration: configuration)
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

    @MainActor
    func testReaderCanOpenAndCloseAISidebarWithoutCoveringPDF() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        let data = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 595, height: 842)).pdfData { context in
            context.beginPage()
            ("Reading and annotation\nLocal PDF import and AI assistance" as NSString).draw(
                in: CGRect(x: 40, y: 60, width: 510, height: 200), withAttributes: [.font: UIFont.systemFont(ofSize: 22)])
        }
        try data.write(to: url)
        let storage = RealmDbStorage(config: .init(inMemoryIdentifier: UUID().uuidString))
        let store = PDFKitAnnotationStore(attachmentKey: KeyGenerator.newKey, libraryId: .custom(.myLibrary), userId: 0,
                                          dbStorage: storage, schemaController: SchemaController(), dateParser: DateParser())
        let reader = PDFKitReaderViewController(url: url, title: "AI 阅读预览", store: store, initialPage: nil, annotationKey: nil, previewRects: nil)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 1024, height: 768))
        window.rootViewController = reader
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        reader.view.frame = window.bounds
        reader.view.layoutIfNeeded()
        let button = try XCTUnwrap(reader.navigationItem.rightBarButtonItems?.first(where: { $0.accessibilityLabel == "AI 阅读助手" }))
        let action = try XCTUnwrap(button.action)
        XCTAssertTrue(UIApplication.shared.sendAction(action, to: button.target, from: button, for: nil))
        reader.view.layoutIfNeeded()
        let host = try XCTUnwrap(reader.children.compactMap { $0 as? UIHostingController<PDFReadingAssistantView> }.first)
        XCTAssertFalse(host.view.isHidden)
        XCTAssertGreaterThan(host.view.bounds.width, 300)
        func findPDF(in view: UIView) -> PDFView? {
            (view as? PDFView) ?? view.subviews.lazy.compactMap { findPDF(in: $0) }.first
        }
        let pdf = try XCTUnwrap(findPDF(in: reader.view))
        let pdfFrame = pdf.convert(pdf.bounds, to: reader.view)
        let panelFrame = host.view.convert(host.view.bounds, to: reader.view)
        XCTAssertLessThanOrEqual(pdfFrame.maxX, panelFrame.minX + 1)
        XCTAssertGreaterThan(pdfFrame.width, 460)
        host.rootView.model.messages = [
            .init(role: "user", content: "请概括这篇文献的主要结论", contextDescription: "全文文本：1/1 页含可提取文字"),
            .init(role: "assistant", content: "**核心速览**\n\n这里是侧栏布局预览，不代表真实模型回答。\n\n点击 [第 1 页](zotero-ai-page://1) 可返回原文核对。")
        ]
        for style: UIUserInterfaceStyle in [.light, .dark] {
            reader.overrideUserInterfaceStyle = style
            reader.view.layoutIfNeeded()
            let image = UIGraphicsImageRenderer(bounds: reader.view.bounds).image { _ in reader.view.drawHierarchy(in: reader.view.bounds, afterScreenUpdates: true) }
            let attachment = XCTAttachment(image: image)
            attachment.name = style == .dark ? "AI-reader-dark" : "AI-reader-light"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        host.rootView.model.onPage?(1)
        XCTAssertEqual(pdf.currentPage, pdf.document?.page(at: 0))
        host.rootView.model.onClose?()
        reader.view.layoutIfNeeded()
        XCTAssertTrue(host.view.isHidden)
        XCTAssertGreaterThan(pdf.bounds.width, pdfFrame.width)
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

    @MainActor
    func testImportedPDFCreatesReadableSyncableAttachment() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("local paper.pdf")
        let data = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 300, height: 400)).pdfData { context in
            context.beginPage()
            ("Imported PDF evidence" as NSString).draw(at: CGPoint(x: 20, y: 30), withAttributes: [.font: UIFont.systemFont(ofSize: 14)])
        }
        try data.write(to: source)
        let key = KeyGenerator.newKey
        let destination = Files.attachmentFile(in: .custom(.myLibrary), key: key, filename: source.lastPathComponent, contentType: "application/pdf")
        let storage = FileStorageController()
        defer { try? storage.remove(Files.attachmentDirectory(in: .custom(.myLibrary), key: key)) }
        try LocalFileImporter.copy(from: source, to: destination, fileStorage: storage)
        let attachment = Attachment(type: .file(filename: source.lastPathComponent, contentType: "application/pdf", location: .local, linkType: .importedFile, compressed: false),
                                    title: "local paper", key: key, libraryId: .custom(.myLibrary))
        let realm = try Realm(configuration: .init(inMemoryIdentifier: UUID().uuidString))
        try realm.write {
            let item = try CreateAttachmentDbRequest(attachment: attachment, parentKey: nil, localizedType: "Attachment", includeAccessDate: false, collections: [], tags: []).process(in: realm)
            XCTAssertTrue(item.fileDownloaded)
            XCTAssertTrue(item.attachmentNeedsSync)
            XCTAssertEqual(item.changeType, .user)
        }
        let reopened = try XCTUnwrap(PDFKit.PDFDocument(url: destination.createUrl()))
        XCTAssertEqual(reopened.pageCount, 1)
        XCTAssertTrue(reopened.string?.contains("Imported PDF evidence") == true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
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

private actor AssistantAnswerSink {
    private(set) var answer = ""
    func receive(_ text: String) { answer = text }
}

private final class AssistantStreamStub: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "example.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        let badKey = url.path.contains("bad-key")
        let response = HTTPURLResponse(url: url, statusCode: badKey ? 401 : 200, httpVersion: nil, headerFields: ["Content-Type": "text/event-stream"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        let content: String
        if badKey {
            content = "test-secret-provider-error"
        } else {
            content = ": keep-alive\n\ndata: {\"choices\":[{\"delta\":{\"content\":\"中文\"}}]}\n\ndata: {\"choices\":[{\"delta\":{\"content\":\"结果 😀\"}}]}\n\n" + (url.path.contains("truncated") ? "" : "data: [DONE]\n\n")
        }
        // Intentionally split multibyte scalars across chunks.
        for byte in Data(content.utf8) { client?.urlProtocol(self, didLoad: Data([byte])) }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
