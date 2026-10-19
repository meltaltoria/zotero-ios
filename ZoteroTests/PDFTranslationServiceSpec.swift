//
//  PDFTranslationServiceSpec.swift
//  ZoteroTests
//

import XCTest

@testable import Zotero

#if SIDELOAD
final class SideloadStorageSpec: XCTestCase {
    func testLoginCredentialPersistsWithoutSharedKeychainEntitlement() {
        let storage = KeychainSecureStorage()
        let previousToken = storage.apiToken
        defer { storage.apiToken = previousToken }

        let token = UUID().uuidString
        storage.apiToken = token
        XCTAssertEqual(storage.lastResultCode, 0)
        XCTAssertEqual(KeychainSecureStorage().apiToken, token)
    }

    func testAttachmentStorageIsWritableWithoutAppGroups() throws {
        let url = URL(fileURLWithPath: Files.appGroupPath).appendingPathComponent(UUID().uuidString)
        let data = Data("sideload-storage".utf8)
        try data.write(to: url, options: .atomic)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertEqual(try Data(contentsOf: url), data)
    }
}
#endif

final class PDFTranslationServiceSpec: XCTestCase {
    func testCacheSeparatesSettingsContainingDelimiter() async throws {
        let session = makeTranslationSession()
        defer { session.invalidateAndCancel() }
        let text = UUID().uuidString
        let first = try await PDFTranslationService.translate(
            text: text,
            provider: "google",
            endpoint: "unused",
            model: "model|en",
            targetLanguage: "fr",
            apiKey: "",
            session: session
        )
        let second = try await PDFTranslationService.translate(
            text: text,
            provider: "google",
            endpoint: "unused",
            model: "model",
            targetLanguage: "en|fr",
            apiKey: "",
            session: session
        )
        XCTAssertEqual(first, "fr")
        XCTAssertEqual(second, "en|fr")
    }

    func testCancelledRequestDoesNotReturnCachedResult() async throws {
        let session = makeTranslationSession()
        defer { session.invalidateAndCancel() }
        let text = UUID().uuidString
        _ = try await PDFTranslationService.translate(
            text: text, provider: "google", endpoint: "unused", model: "unused",
            targetLanguage: "en", apiKey: "", session: session
        )

        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await PDFTranslationService.translate(
                text: text, provider: "google", endpoint: "unused", model: "unused",
                targetLanguage: "en", apiKey: "", session: session
            )
        }
        do {
            _ = try await task.value
            XCTFail("A cancelled translation must throw, including on a cache hit.")
        } catch is CancellationError {
            // Expected.
        }
    }

    private func makeTranslationSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TranslationStubProtocol.self]
        return URLSession(configuration: configuration)
    }

    func testGoogleTokenForASCII() {
        XCTAssertEqual(
            PDFTranslationService.googleToken("hello"),
            "670448.790148"
        )
    }

    func testGoogleTokenForChinese() {
        XCTAssertEqual(
            PDFTranslationService.googleToken("你好世界"),
            "786753.668981"
        )
    }

    func testGoogleTokenForScientificText() {
        XCTAssertEqual(
            PDFTranslationService.googleToken("The electrochemical performance of LiFePO4"),
            "83678.488106"
        )
    }

    func testGoogleTokenForSupplementaryUnicode() {
        XCTAssertEqual(
            PDFTranslationService.googleToken("😀"),
            "916699.772271"
        )
    }

    func testNoteHTMLPreservesOriginalAndTranslation() {
        XCTAssertEqual(
            PDFTranslationResultViewController.noteHTML(
                original: "LiFePO4 < cathode & electrolyte",
                translated: "磷酸铁锂 > 正极"
            ),
            "<p><strong>Original</strong><br>LiFePO4 &lt; cathode &amp; electrolyte</p><p><strong>Translation</strong><br>磷酸铁锂 &gt; 正极</p>"
        )
    }

    func testNoteHTMLEscapesQuotesAndLineBreaks() {
        XCTAssertEqual(
            PDFTranslationResultViewController.noteHTML(
                original: "\"SEI\"\nlayer",
                translated: "'界面膜'"
            ),
            "<p><strong>Original</strong><br>&quot;SEI&quot;<br>layer</p><p><strong>Translation</strong><br>&#39;界面膜&#39;</p>"
        )
    }
}

private final class TranslationStubProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool {
        return true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        return request
    }

    override func startLoading() {
        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil) else {
            return
        }
        let target = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "tl" })?.value ?? ""
        do {
            let data = try JSONSerialization.data(withJSONObject: [[[target]]])
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
