//
//  PDFKitReaderSpec.swift
//  ZoteroTests
//

import PDFKit
import RealmSwift
import UIKit
import XCTest

@testable import Zotero

final class PDFKitReaderSpec: XCTestCase {
    private func record(type: AnnotationType = .highlight, rects: [CGRect] = [CGRect(x: 35, y: 90, width: 120, height: 12)],
                        paths: [[CGPoint]] = [], comment: String = "A translation", page: Int = 0) -> PDFKitAnnotationRecord {
        PDFKitAnnotationRecord(type: type, page: page, pageLabel: "iii", rects: rects, paths: paths,
                               lineWidth: type == .ink ? 2 : nil, text: "Selected text", comment: comment, color: "#ffd400",
                               userId: 42, author: "Reader", sortIndex: "00000|000010|00090")
    }

    func testCreatesSyncableAnnotationWithRawCoordinatesAndPageLabel() throws {
        let realm = try Realm(configuration: .init(inMemoryIdentifier: UUID().uuidString))
        let parent = RItem()
        parent.key = "PARENT01"
        parent.libraryId = .custom(.myLibrary)
        parent.rawType = ItemTypes.attachment
        let user = RUser()
        user.identifier = 42
        let rects = [CGRect(x: -12.5, y: 215.75, width: 50.25, height: 9.5), CGRect(x: 30, y: 195, width: 70, height: 10)]
        let annotation = record(rects: rects)
        let schema = SchemaController()
        try realm.write {
            realm.add(parent)
            realm.add(user)
            let request = CreatePDFKitAnnotationsDbRequest(
                attachmentKey: parent.key, libraryId: .custom(.myLibrary), annotations: [annotation], userId: 42, schemaController: schema
            )
            try request.process(in: realm)
        }
        let stored = try XCTUnwrap(realm.objects(RItem.self).first(where: { $0.key == annotation.key }))
        let restored = try XCTUnwrap(PDFKitAnnotationRecord(item: stored))
        XCTAssertEqual(restored.rects, rects)
        XCTAssertEqual(restored.pageLabel, "iii")
        XCTAssertEqual(restored.comment, "A translation")
        XCTAssertEqual(restored.authorId, 42)
        XCTAssertEqual(stored.parent?.key, parent.key)
        XCTAssertEqual(stored.changeType, .user)
        XCTAssertFalse(stored.changes.isEmpty)
        XCTAssertEqual(stored.fields.first(where: { $0.key == FieldKeys.Item.Annotation.Position.pageIndex })?.baseKey,
                       FieldKeys.Item.Annotation.position)
    }

    func testEditingCommentPreservesColorGeometryAndTags() throws {
        let realm = try Realm(configuration: .init(inMemoryIdentifier: UUID().uuidString))
        let parent = RItem()
        parent.key = "PARENT01"
        parent.libraryId = .custom(.myLibrary)
        let annotation = record()
        let schema = SchemaController()
        let parser = DateParser()
        try realm.write {
            realm.add(parent)
            let request = CreatePDFKitAnnotationsDbRequest(
                attachmentKey: parent.key, libraryId: .custom(.myLibrary), annotations: [annotation], userId: 42, schemaController: schema
            )
            try request.process(in: realm)
        }
        let item = try XCTUnwrap(realm.objects(RItem.self).first(where: { $0.key == annotation.key }))
        try realm.write {
            let tag = RTypedTag()
            tag.tag = RTag.create(name: "Keep this tag", libraryId: .custom(.myLibrary))
            tag.item = item
            realm.add(tag)
            try EditItemFieldsDbRequest(key: item.key, libraryId: .custom(.myLibrary),
                                        fieldValues: [.init(key: FieldKeys.Item.Annotation.comment, baseKey: nil): "New comment"], dateParser: parser).process(in: realm)
        }
        let restored = try XCTUnwrap(PDFKitAnnotationRecord(item: item))
        XCTAssertEqual(restored.comment, "New comment")
        XCTAssertEqual(restored.rects, annotation.rects)
        XCTAssertEqual(restored.color, annotation.color)
        XCTAssertEqual(restored.tags.map(\.name), ["Keep this tag"])
    }

    func testInkPathsRoundTripWithoutCoordinateTransform() throws {
        let realm = try Realm(configuration: .init(inMemoryIdentifier: UUID().uuidString))
        let parent = RItem()
        parent.key = "PARENT01"
        parent.libraryId = .custom(.myLibrary)
        let points = [[CGPoint(x: 30.5, y: 80.5), CGPoint(x: 45, y: 100), CGPoint(x: 40, y: 110)]]
        let annotation = record(type: .ink, rects: [], paths: points)
        let schema = SchemaController()
        try realm.write {
            realm.add(parent)
            let request = CreatePDFKitAnnotationsDbRequest(
                attachmentKey: parent.key, libraryId: .custom(.myLibrary), annotations: [annotation], userId: 42, schemaController: schema
            )
            try request.process(in: realm)
        }
        let item = try XCTUnwrap(realm.objects(RItem.self).first(where: { $0.key == annotation.key }))
        let restored = try XCTUnwrap(PDFKitAnnotationRecord(item: item))
        XCTAssertEqual(restored.paths, points)
        XCTAssertEqual(restored.lineWidth, 2)
        XCTAssertNotNil(restored.pdfAnnotation())
    }

    func testMultiLineHighlightUsesRelativeQuadrilateralPoints() throws {
        let rects = [CGRect(x: 35, y: 90, width: 120, height: 12), CGRect(x: 35, y: 70, width: 50, height: 12)]
        let annotation = try XCTUnwrap(record(rects: rects).pdfAnnotation())
        XCTAssertEqual(annotation.bounds, CGRect(x: 35, y: 70, width: 120, height: 32))
        let points = try XCTUnwrap(annotation.quadrilateralPoints)
        XCTAssertEqual(points.count, 8)
        XCTAssertEqual(points[0].cgPointValue, CGPoint(x: 0, y: 32))
        XCTAssertEqual(points[7].cgPointValue, CGPoint(x: 50, y: 0))
    }

    func testLongInkStrokeIsSplitWithSharedEndpointsAndBoundedPositionSize() throws {
        let points = (0..<2400).map { CGPoint(x: Double($0) / 7, y: Double($0) / 11) }
        let chunks = PDFKitAnnotationRecord.inkChunks(points)
        XCTAssertEqual(chunks.count, 3)
        XCTAssertTrue(chunks.allSatisfy { $0.count <= 1000 })
        XCTAssertEqual(chunks[0].last, chunks[1].first)
        XCTAssertEqual(chunks[1].last, chunks[2].first)
        XCTAssertEqual(chunks.last?.last, points.last)
        for chunk in chunks {
            let data = try JSONSerialization.data(withJSONObject: ["pageIndex": 0, "width": 2, "paths": [chunk.flatMap { [Double($0.x), Double($0.y)] }]])
            XCTAssertLessThan(data.count, AnnotationsConfig.positionSizeLimit)
        }
    }

    func testPDFKitCanReopenExportOnRotatedPageWithOffsetCropBox() throws {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 300, height: 400)).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 300, height: 400))
        }
        let page = try XCTUnwrap(PDFPage(image: image))
        page.setBounds(CGRect(x: 20, y: 30, width: 260, height: 340), for: .cropBox)
        page.rotation = 90
        let annotation = record()
        page.addAnnotation(try XCTUnwrap(annotation.pdfAnnotation()))
        let document = PDFKit.PDFDocument()
        document.insert(page, at: 0)
        let data = try XCTUnwrap(document.dataRepresentation())
        let reopened = try XCTUnwrap(PDFKit.PDFDocument(data: data))
        let restoredPage = try XCTUnwrap(reopened.page(at: 0))
        XCTAssertEqual(restoredPage.rotation, 90)
        XCTAssertEqual(restoredPage.bounds(for: .cropBox), page.bounds(for: .cropBox))
        let restored = try XCTUnwrap(restoredPage.annotations.first)
        XCTAssertEqual(restored.bounds, annotation.rects[0])
        XCTAssertEqual(restored.contents, annotation.comment)
    }

    func testPanelStaysReachableAfterDraggingBeyondEveryEdge() {
        let safe = CGRect(x: 8, y: 60, width: 359, height: 650)
        for origin in [CGPoint(x: -900, y: -900), CGPoint(x: 2000, y: 2000)] {
            let frame = PDFTranslationFloatingController.clampedFrame(CGRect(origin: origin, size: CGSize(width: 420, height: 440)), in: safe)
            XCTAssertTrue(safe.contains(frame))
        }
    }

    func testPanelFitsLandscapeSplitViewAndCollapsedHeader() {
        let safe = CGRect(x: 8, y: 8, width: 240, height: 190)
        let proposed = CGRect(x: 700, y: 900, width: 500, height: 600)
        XCTAssertEqual(PDFTranslationFloatingController.clampedFrame(proposed, in: safe), safe)
        let collapsed = PDFTranslationFloatingController.clampedFrame(proposed, in: safe, collapsed: true)
        XCTAssertEqual(collapsed.height, 48)
        XCTAssertTrue(safe.contains(collapsed))
    }
}
