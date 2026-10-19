//
//  PDFKitAnnotationStore.swift
//  Zotero
//

import PDFKit
import RealmSwift
import UIKit

/// A detached snapshot in raw PDF coordinates, the same coordinate space used by Zotero sync.
struct PDFKitAnnotationRecord: ReaderAnnotation {
    let key: String
    let type: AnnotationType
    let page: Int
    let pageLabel: String
    let rects: [CGRect]
    let paths: [[CGPoint]]
    let lineWidth: CGFloat?
    let color: String
    let comment: String
    let text: String?
    let fontSize: CGFloat?
    let rotation: Int
    let sortIndex: String
    let dateAdded: Date
    let dateModified: Date
    let tags: [Tag]
    let authorId: Int?
    let authorName: String

    func author(displayName: String, username: String) -> String { authorName }
    func isAuthor(currentUserId: Int) -> Bool { authorId == currentUserId }
    func editability(currentUserId: Int, library: Library) -> AnnotationEditability {
        guard library.metadataEditable else { return .notEditable }
        if case .custom = library.identifier { return .editable }
        return isAuthor(currentUserId: currentUserId) ? .editable : .notEditable
    }

    init?(item: RItem) {
        func field(_ key: String, base: String? = nil) -> String? {
            item.fields.first(where: { $0.key == key && (base == nil || $0.baseKey == base) })?.value
        }
        guard let type = AnnotationType(rawValue: item.annotationType),
              let pageString = field(FieldKeys.Item.Annotation.Position.pageIndex, base: FieldKeys.Item.Annotation.position),
              let pageNumber = Double(pageString), pageNumber.isFinite, pageNumber >= 0, pageNumber < Double(Int.max) else { return nil }
        self.key = item.key
        self.type = type
        page = Int(pageNumber)
        pageLabel = field(FieldKeys.Item.Annotation.pageLabel) ?? "\(page + 1)"
        rects = item.rects.map { CGRect(x: $0.minX, y: $0.minY, width: $0.maxX - $0.minX, height: $0.maxY - $0.minY) }
        paths = item.paths.sorted(byKeyPath: "sortIndex").compactMap { path in
            let coordinates = path.coordinates.sorted(byKeyPath: "sortIndex")
            guard coordinates.count.isMultiple(of: 2) else { return nil }
            return stride(from: 0, to: coordinates.count, by: 2).map { CGPoint(x: coordinates[$0].value, y: coordinates[$0 + 1].value) }
        }
        lineWidth = field(FieldKeys.Item.Annotation.Position.lineWidth).flatMap(Double.init).map { CGFloat($0) }
        color = field(FieldKeys.Item.Annotation.color) ?? "#ffd400"
        comment = field(FieldKeys.Item.Annotation.comment) ?? ""
        text = field(FieldKeys.Item.Annotation.text)
        fontSize = field(FieldKeys.Item.Annotation.Position.fontSize).flatMap(Double.init).map { CGFloat($0) }
        rotation = field(FieldKeys.Item.Annotation.Position.rotation).flatMap(Int.init) ?? 0
        sortIndex = item.annotationSortIndex
        dateAdded = item.dateAdded
        dateModified = item.dateModified
        tags = item.tags.map { Tag(tag: $0) }
        authorId = item.createdBy?.identifier
        authorName = field(FieldKeys.Item.Annotation.authorName) ?? item.createdBy?.name ?? ""
    }

    init(type: AnnotationType, page: Int, pageLabel: String, rects: [CGRect], paths: [[CGPoint]] = [], lineWidth: CGFloat? = nil,
         text: String?, comment: String, color: String, userId: Int, author: String, sortIndex: String) {
        key = KeyGenerator.newKey
        self.type = type
        self.page = page
        self.pageLabel = pageLabel
        self.rects = rects.map { $0.rounded(to: 3) }
        self.paths = paths.map { $0.map { $0.rounded(to: 3) } }
        self.lineWidth = lineWidth
        self.color = color
        self.comment = comment
        self.text = text
        fontSize = nil
        rotation = 0
        self.sortIndex = sortIndex
        dateAdded = Date()
        dateModified = dateAdded
        tags = []
        authorId = userId
        authorName = author
    }

    /// Bound serialized position size and share an endpoint so split pen strokes remain visually continuous.
    static func inkChunks(_ points: [CGPoint]) -> [[CGPoint]] {
        guard points.count > 1 else { return [] }
        var chunks: [[CGPoint]] = []
        var start = 0
        while start < points.count - 1 {
            let end = min(start + 1000, points.count)
            chunks.append(Array(points[start..<end]))
            start = end - 1
        }
        return chunks
    }

    func pdfAnnotation() -> PDFKit.PDFAnnotation? {
        let validRects = rects.filter { !$0.isEmpty && !$0.isInfinite && !$0.isNull }
        let bounds: CGRect
        if type == .ink {
            bounds = AnnotationBoundingBoxCalculator.boundingBox(from: paths, lineWidth: lineWidth ?? 1)
        } else {
            guard let first = validRects.first else { return nil }
            bounds = validRects.dropFirst().reduce(first) { $0.union($1) }
        }
        guard !bounds.isEmpty, !bounds.isInfinite, !bounds.isNull else { return nil }
        let subtype: PDFAnnotationSubtype
        switch type {
        case .highlight: subtype = .highlight
        case .underline: subtype = .underline
        case .note: subtype = .text
        case .image: subtype = .square
        case .ink: subtype = .ink
        case .freeText: subtype = .freeText
        }
        let annotation = PDFKit.PDFAnnotation(bounds: bounds, forType: subtype, withProperties: nil)
        annotation.color = UIColor(hex: color)
        annotation.contents = comment
        annotation.userName = authorName
        annotation.modificationDate = dateModified
        annotation.setValue(key, forAnnotationKey: PDFAnnotationKey(rawValue: "ZoteroKey"))
        if type == .highlight || type == .underline {
            annotation.quadrilateralPoints = validRects.flatMap { rect in
                [CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.maxX, y: rect.maxY),
                 CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY)]
                    .map { NSValue(cgPoint: CGPoint(x: $0.x - bounds.minX, y: $0.y - bounds.minY)) }
            }
        }
        if type == .freeText {
            annotation.font = .systemFont(ofSize: fontSize ?? 14)
            annotation.fontColor = UIColor(hex: color)
            annotation.color = .clear
            annotation.setValue(rotation, forAnnotationKey: PDFAnnotationKey(rawValue: "Rotate"))
        }
        if type == .ink {
            let border = PDFBorder()
            border.lineWidth = lineWidth ?? 1
            annotation.border = border
            for points in paths {
                let path = UIBezierPath()
                for (index, point) in points.enumerated() {
                    let local = CGPoint(x: point.x - bounds.minX, y: point.y - bounds.minY)
                    if index == 0 { path.move(to: local) } else { path.addLine(to: local) }
                }
                annotation.add(path)
            }
        }
        return annotation
    }
}

/// Creation uses Zotero's normal change tracking, but never creates a PSPDFKit document or transforms raw coordinates.
final class CreatePDFKitAnnotationsDbRequest: CreateOrEditReaderAnnotationsDbRequest<PDFKitAnnotationRecord> {
    override func addFields(for annotation: PDFKitAnnotationRecord, to item: RItem, database: Realm) {
        super.addFields(for: annotation, to: item, database: database)
        for pair in FieldKeys.Item.Annotation.extraPDFFields(for: annotation.type) {
            let field = RItemField()
            field.key = pair.key
            field.baseKey = pair.baseKey
            field.changed = true
            switch pair.key {
            case FieldKeys.Item.Annotation.Position.pageIndex: field.value = "\(annotation.page)"
            case FieldKeys.Item.Annotation.pageLabel: field.value = annotation.pageLabel
            case FieldKeys.Item.Annotation.Position.lineWidth: field.value = annotation.lineWidth.map { "\($0)" } ?? ""
            case FieldKeys.Item.Annotation.Position.rotation: field.value = "\(annotation.rotation)"
            case FieldKeys.Item.Annotation.Position.fontSize: field.value = "\(annotation.fontSize ?? 14)"
            default: field.value = ""
            }
            item.fields.append(field)
        }
    }

    override func addAdditionalProperties(for annotation: PDFKitAnnotationRecord, to item: RItem, changes: inout RItemChanges, database: Realm) {
        database.delete(item.rects)
        for rect in annotation.rects {
            let stored = RRect()
            stored.minX = Double(rect.minX)
            stored.minY = Double(rect.minY)
            stored.maxX = Double(rect.maxX)
            stored.maxY = Double(rect.maxY)
            item.rects.append(stored)
        }
        changes.insert(.rects)
        database.delete(item.paths)
        for (index, points) in annotation.paths.enumerated() {
            let path = RPath()
            path.sortIndex = index
            for (offset, point) in points.enumerated() {
                for (component, value) in [point.x, point.y].enumerated() {
                    let coordinate = RPathCoordinate()
                    coordinate.sortIndex = offset * 2 + component
                    coordinate.value = Double(value)
                    path.coordinates.append(coordinate)
                }
            }
            item.paths.append(path)
        }
        changes.insert(.paths)
    }
}

final class PDFKitAnnotationStore {
    enum StoreError: LocalizedError {
        case readOnly
        case deleted
        case changedWhileEditing
        var errorDescription: String? {
            switch self {
            case .readOnly: return "This annotation or library is read-only."
            case .deleted: return "This attachment or annotation has been deleted."
            case .changedWhileEditing: return "This annotation changed on another device. Reopen its comment before editing again."
            }
        }
    }

    let attachmentKey: String
    let libraryId: LibraryIdentifier
    let userId: Int
    let dbStorage: DbStorage
    private let schemaController: SchemaController
    private let dateParser: DateParser
    private var token: NotificationToken?
    private var results: Results<RItem>?
    var onChange: (([PDFKitAnnotationRecord]) -> Void)?
    var onError: ((Error) -> Void)?
    private(set) var records: [PDFKitAnnotationRecord] = []

    init(attachmentKey: String, libraryId: LibraryIdentifier, userId: Int, dbStorage: DbStorage,
         schemaController: SchemaController, dateParser: DateParser) {
        self.attachmentKey = attachmentKey
        self.libraryId = libraryId
        self.userId = userId
        self.dbStorage = dbStorage
        self.schemaController = schemaController
        self.dateParser = dateParser
    }

    deinit { token?.invalidate() }

    func load() throws {
        let results = try dbStorage.perform(request: ReadAnnotationsDbRequest(attachmentKey: attachmentKey, libraryId: libraryId, page: nil), on: .main)
        self.results = results
        refresh()
        token = results.observe(keyPaths: ["fields.value", "rects.minX", "rects.minY", "rects.maxX", "rects.maxY",
                                           "paths.coordinates.value", "paths.coordinates.sortIndex", "paths.sortIndex",
                                           "tags.tag.name", "tags.tag.color", "tags.type", "dateModified", "createdBy.identifier"]) { [weak self] change in
            switch change {
            case .initial, .update: self?.refresh()
            case .error(let error): self?.onError?(error)
            }
        }
    }

    func refresh() {
        records = results?.compactMap { PDFKitAnnotationRecord(item: $0) } ?? []
        onChange?(records)
    }

    func canEdit(_ record: PDFKitAnnotationRecord? = nil) -> Bool {
        (try? checkEditable(record)) != nil
    }

    private func checkEditable(_ record: PDFKitAnnotationRecord?) throws {
        let parent = try dbStorage.perform(request: ReadItemDbRequest(libraryId: libraryId, key: attachmentKey), on: .main)
        guard !parent.deleted && !parent.trash && parent.parent?.trash != true && parent.parent?.deleted != true else { throw StoreError.deleted }
        let library = try dbStorage.perform(request: ReadLibraryDbRequest(libraryId: libraryId), on: .main)
        guard library.metadataEditable else { throw StoreError.readOnly }
        if let record {
            let item = try dbStorage.perform(request: ReadItemDbRequest(libraryId: libraryId, key: record.key), on: .main)
            guard !item.deleted, item.parent?.key == attachmentKey else { throw StoreError.deleted }
            if case .group = libraryId, item.createdBy?.identifier != userId { throw StoreError.readOnly }
        }
    }

    func create(_ record: PDFKitAnnotationRecord) throws {
        try create([record])
    }

    func create(_ records: [PDFKitAnnotationRecord]) throws {
        try checkEditable(nil)
        let request = CreatePDFKitAnnotationsDbRequest(
            attachmentKey: attachmentKey, libraryId: libraryId, annotations: records, userId: userId, schemaController: schemaController
        )
        try dbStorage.perform(request: request, on: .main)
        refresh()
    }

    func edit(_ record: PDFKitAnnotationRecord, comment: String? = nil, color: String? = nil) throws {
        try checkEditable(record)
        let item = try dbStorage.perform(request: ReadItemDbRequest(libraryId: libraryId, key: record.key), on: .main)
        guard item.dateModified == record.dateModified else { throw StoreError.changedWhileEditing }
        var fields: [KeyBaseKeyPair: String] = [:]
        if let comment { fields[.init(key: FieldKeys.Item.Annotation.comment, baseKey: nil)] = comment }
        if let color { fields[.init(key: FieldKeys.Item.Annotation.color, baseKey: nil)] = color }
        try dbStorage.perform(request: EditItemFieldsDbRequest(key: record.key, libraryId: libraryId, fieldValues: fields, dateParser: dateParser), on: .main)
        refresh()
    }

    func delete(_ record: PDFKitAnnotationRecord) throws {
        try checkEditable(record)
        try dbStorage.perform(request: MarkObjectsAsDeletedDbRequest<RItem>(keys: [record.key], libraryId: libraryId), on: .main)
        refresh()
    }
}
