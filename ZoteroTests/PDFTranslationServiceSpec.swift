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
}
