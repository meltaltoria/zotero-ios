//
//  PDFTranslationServiceSpec.swift
//  ZoteroTests
//

import XCTest

@testable import Zotero

final class PDFTranslationServiceSpec: XCTestCase {
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
