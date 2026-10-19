//
//  PDFKitReaderViewController.swift
//  Zotero
//

import PDFKit
import SwiftUI
import Translation
import UIKit

/// The personal-account reader renders and exports with Apple's PDFKit. Zotero continues to own annotation data.
final class PDFKitReaderViewController: UIViewController, UIGestureRecognizerDelegate {
    private let url: URL
    private let store: PDFKitAnnotationStore
    private let initialPage: Int?
    private let annotationKey: String?
    private let previewRects: [CGRect]?
    private let pdfView = PDFKitSelectionView()
    private let toolbar = UIToolbar()
    private let body = UIView()
    private let sidebar = PDFKitSidebarController()
    private let drawing = PDFKitInkView()
    private var sidebarWidth: NSLayoutConstraint!
    private var sidebarVisible = false
    private var document: PDFKit.PDFDocument?
    private var rendered: [(PDFPage, PDFKit.PDFAnnotation)] = []
    private var recordByAnnotation: [ObjectIdentifier: PDFKitAnnotationRecord] = [:]
    private var observers: [NSObjectProtocol] = []
    private var oldMenuItems: [UIMenuItem]?
    private var color = AnnotationsConfig.defaultActiveColor
    private var penEnabled = false
    private var translationTask: Task<Void, Never>?
    private var translationID: UUID?
    private var translationAlert: UIAlertController?
    private var systemHost: UIViewController?
    private var lastStoredPage: Int?
    private var didRestorePage = false
    private let pageButton = UIBarButtonItem(title: "", style: .plain, target: nil, action: nil)
    private let penButton = UIBarButtonItem(image: UIImage(systemName: "pencil.tip"), style: .plain, target: nil, action: nil)

    init(url: URL, title: String?, store: PDFKitAnnotationStore, initialPage: Int?, annotationKey: String?, previewRects: [CGRect]?) {
        self.url = url
        self.store = store
        self.initialPage = initialPage
        self.annotationKey = annotationKey
        self.previewRects = previewRects
        super.init(nibName: nil, bundle: nil)
        self.title = title ?? url.lastPathComponent
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
        translationTask?.cancel()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        setupLayout()
        setupToolbar()
        setupNavigation()
        pdfView.autoScales = true
        pdfView.displayBox = .cropBox
        pdfView.backgroundColor = .secondarySystemBackground
        pdfView.onTranslate = { [weak self] in self?.translateSelection() }
        pdfView.onHighlight = { [weak self] in self?.addMarkup(.highlight) }
        pdfView.onUnderline = { [weak self] in self?.addMarkup(.underline) }
        pdfView.onNote = { [weak self] in self?.addNote() }
        let tap = UITapGestureRecognizer(target: self, action: #selector(annotationTapped(_:)))
        tap.cancelsTouchesInView = false
        tap.delegate = self
        pdfView.addGestureRecognizer(tap)
        drawing.isHidden = true
        drawing.pdfView = pdfView
        drawing.onStroke = { [weak self] page, points in self?.saveInk(page: page, points: points) }
        store.onChange = { [weak self] _ in self?.reloadAnnotations() }
        store.onError = { [weak self] error in self?.showError(error) }
        sidebar.onSelectAnnotation = { [weak self] record in self?.focus(record) }
        sidebar.onEditAnnotation = { [weak self] record in self?.annotationActions(record) }
        sidebar.onSelectPage = { [weak self] page in self?.go(to: page) }
        loadDocument()
        observers.append(NotificationCenter.default.addObserver(forName: .PDFViewPageChanged, object: pdfView, queue: .main) { [weak self] _ in
            self?.pageChanged()
        })
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        oldMenuItems = UIMenuController.shared.menuItems
        UIMenuController.shared.menuItems = [
            UIMenuItem(title: "Translate", action: #selector(PDFKitSelectionView.translateText)),
            UIMenuItem(title: "Highlight", action: #selector(PDFKitSelectionView.highlightText)),
            UIMenuItem(title: "Underline", action: #selector(PDFKitSelectionView.underlineText)),
            UIMenuItem(title: "Note", action: #selector(PDFKitSelectionView.noteText))
        ]
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        UIMenuController.shared.menuItems = oldMenuItems
        if isBeingDismissed || navigationController?.isBeingDismissed == true {
            cancelTranslation()
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if sidebarVisible { sidebarWidth.constant = sidebarSize }
        guard !didRestorePage, let document, document.pageCount > 0, pdfView.bounds.width > 0 else { return }
        didRestorePage = true
        let request = ReadDocumentDataDbRequest(attachmentKey: store.attachmentKey, libraryId: store.libraryId, defaultPageValue: "0")
        let stored = try? store.dbStorage.perform(request: request, on: .main)
        let page = initialPage ?? stored.flatMap { Int($0.page) } ?? 0
        go(to: min(max(page, 0), document.pageCount - 1))
        if let annotationKey, let record = store.records.first(where: { $0.key == annotationKey }) {
            focus(record)
        } else if let rect = previewRects?.first, let current = pdfView.currentPage {
            pdfView.go(to: rect, on: current)
        }
        pageChanged()
    }

    private var sidebarSize: CGFloat {
        min(320, max(180, view.bounds.width * 0.33))
    }

    private func setupLayout() {
        for subview in [body, toolbar] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(subview)
        }
        addChild(sidebar)
        for subview in [sidebar.view!, pdfView, drawing] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            body.addSubview(subview)
        }
        sidebar.didMove(toParent: self)
        sidebar.view.isHidden = true
        sidebarWidth = sidebar.view.widthAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            body.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            body.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            body.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            body.bottomAnchor.constraint(equalTo: toolbar.topAnchor),
            toolbar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            toolbar.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            toolbar.heightAnchor.constraint(equalToConstant: 48),
            sidebar.view.leadingAnchor.constraint(equalTo: body.leadingAnchor),
            sidebar.view.topAnchor.constraint(equalTo: body.topAnchor),
            sidebar.view.bottomAnchor.constraint(equalTo: body.bottomAnchor),
            sidebarWidth,
            pdfView.leadingAnchor.constraint(equalTo: sidebar.view.trailingAnchor),
            pdfView.trailingAnchor.constraint(equalTo: body.trailingAnchor),
            pdfView.topAnchor.constraint(equalTo: body.topAnchor),
            pdfView.bottomAnchor.constraint(equalTo: body.bottomAnchor),
            drawing.leadingAnchor.constraint(equalTo: pdfView.leadingAnchor),
            drawing.trailingAnchor.constraint(equalTo: pdfView.trailingAnchor),
            drawing.topAnchor.constraint(equalTo: pdfView.topAnchor),
            drawing.bottomAnchor.constraint(equalTo: pdfView.bottomAnchor)
        ])
    }

    private func setupNavigation() {
        navigationItem.leftBarButtonItems = [
            UIBarButtonItem(barButtonSystemItem: .close, target: self, action: #selector(closeReader)),
            UIBarButtonItem(image: UIImage(systemName: "sidebar.left"), style: .plain, target: self, action: #selector(toggleReaderSidebar))
        ]
        navigationItem.leftBarButtonItems?.last?.accessibilityLabel = "Annotations, pages and outline"
        let search = UIBarButtonItem(barButtonSystemItem: .search, target: self, action: #selector(searchDocument))
        let more = UIBarButtonItem(image: UIImage(systemName: "ellipsis.circle"), menu: readerMenu())
        more.accessibilityLabel = "Reading options and export"
        navigationItem.rightBarButtonItems = [more, search]
    }

    private func setupToolbar() {
        func button(_ image: String, _ title: String, _ action: @escaping () -> Void) -> UIBarButtonItem {
            let item = UIBarButtonItem(image: UIImage(systemName: image), primaryAction: UIAction { _ in action() })
            item.accessibilityLabel = title
            return item
        }
        penButton.target = self
        penButton.action = #selector(togglePen)
        penButton.accessibilityLabel = "Start or stop handwriting"
        pageButton.target = self
        pageButton.action = #selector(jumpToPage)
        pageButton.accessibilityLabel = "Page. Tap to jump to a page."
        toolbar.items = [
            button("highlighter", "Highlight selected text") { [weak self] in self?.addMarkup(.highlight) },
            .flexibleSpace(),
            button("underline", "Underline selected text") { [weak self] in self?.addMarkup(.underline) },
            .flexibleSpace(),
            button("note.text.badge.plus", "Add note") { [weak self] in self?.addNote() },
            .flexibleSpace(),
            penButton,
            .flexibleSpace(),
            button("character.bubble", "Translate selected text") { [weak self] in self?.translateSelection() },
            .flexibleSpace(),
            button("circle.lefthalf.filled", "Annotation color") { [weak self] in self?.chooseColor() },
            .flexibleSpace(), pageButton
        ]
    }

    private func loadDocument() {
        guard let document = PDFKit.PDFDocument(url: url) else {
            showMessage("Could not open this PDF.")
            return
        }
        self.document = document
        if document.isLocked {
            let alert = UIAlertController(title: "Unlock PDF", message: "Enter the document password.", preferredStyle: .alert)
            alert.addTextField { $0.isSecureTextEntry = true }
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
            alert.addAction(UIAlertAction(title: "Unlock", style: .default) { [weak self, weak alert] _ in
                guard let self else { return }
                if document.unlock(withPassword: alert?.textFields?.first?.text ?? "") {
                    self.finishLoading(document)
                } else {
                    self.showMessage("Incorrect PDF password.")
                }
            })
            DispatchQueue.main.async { [weak self] in self?.present(alert, animated: true) }
        } else {
            finishLoading(document)
        }
    }

    private func finishLoading(_ document: PDFKit.PDFDocument) {
        pdfView.document = document
        sidebar.document = document
        applyReadingSettings()
        do {
            try store.load()
        } catch {
            showError(error)
        }
        view.setNeedsLayout()
    }

    private func applyReadingSettings() {
        let defaults = UserDefaults.standard
        let horizontal = defaults.bool(forKey: "PDFKitReader.horizontal")
        let continuous = defaults.object(forKey: "PDFKitReader.continuous") as? Bool ?? true
        let twoPages = defaults.bool(forKey: "PDFKitReader.twoPages")
        pdfView.displayDirection = horizontal ? .horizontal : .vertical
        pdfView.displayMode = twoPages ? (continuous ? .twoUpContinuous : .twoUp) : (continuous ? .singlePageContinuous : .singlePage)
        pdfView.displaysAsBook = true
        pdfView.autoScales = true
        let appearance = defaults.string(forKey: "PDFKitReader.appearance") ?? "automatic"
        overrideUserInterfaceStyle = appearance == "dark" ? .dark : (appearance == "light" || appearance == "sepia" ? .light : .unspecified)
        pdfView.backgroundColor = appearance == "sepia" ? UIColor(red: 0.94, green: 0.90, blue: 0.81, alpha: 1) : .secondarySystemBackground
        navigationItem.rightBarButtonItems?.first?.menu = readerMenu()
    }

    private func readerMenu() -> UIMenu {
        let defaults = UserDefaults.standard
        func option(_ title: String, key: String, fallback: Bool = false) -> UIAction {
            let enabled = defaults.object(forKey: key) as? Bool ?? fallback
            return UIAction(title: title, state: enabled ? .on : .off) { [weak self] _ in
                defaults.set(!enabled, forKey: key)
                self?.applyReadingSettings()
            }
        }
        let appearance = UIMenu(title: "Appearance", children: ["automatic", "light", "dark", "sepia"].map { value in
            UIAction(title: value.capitalized, state: (defaults.string(forKey: "PDFKitReader.appearance") ?? "automatic") == value ? .on : .off) { [weak self] _ in
                defaults.set(value, forKey: "PDFKitReader.appearance")
                self?.applyReadingSettings()
            }
        })
        return UIMenu(children: [
            option("Continuous scrolling", key: "PDFKitReader.continuous", fallback: true),
            option("Horizontal scrolling", key: "PDFKitReader.horizontal"),
            option("Two pages", key: "PDFKitReader.twoPages"), appearance,
            UIAction(title: "Fit page", image: UIImage(systemName: "arrow.down.right.and.arrow.up.left")) { [weak self] _ in self?.pdfView.autoScales = true },
            UIAction(title: "Export PDF with annotations", image: UIImage(systemName: "square.and.arrow.up")) { [weak self] _ in self?.exportPDF() }
        ])
    }

    private func reloadAnnotations() {
        rendered.forEach { $0.0.removeAnnotation($0.1) }
        rendered.removeAll()
        recordByAnnotation.removeAll()
        guard let document else { return }
        for record in store.records {
            guard let page = document.page(at: record.page), let annotation = record.pdfAnnotation() else { continue }
            page.addAnnotation(annotation)
            rendered.append((page, annotation))
            recordByAnnotation[ObjectIdentifier(annotation)] = record
        }
        sidebar.records = store.records
    }

    private func pageChanged() {
        guard let document, let page = pdfView.currentPage else { return }
        let index = document.index(for: page)
        pageButton.title = "\(index + 1)/\(document.pageCount)"
        guard didRestorePage, index != lastStoredPage else { return }
        do {
            try store.dbStorage.perform(request: StorePageForItemDbRequest(key: store.attachmentKey, libraryId: store.libraryId, page: "\(index)"), on: .main)
            lastStoredPage = index
        } catch {
            showError(error)
        }
    }

    private func go(to index: Int) {
        guard let page = document?.page(at: index) else { return }
        pdfView.go(to: page)
    }

    private func focus(_ record: PDFKitAnnotationRecord) {
        guard let page = document?.page(at: record.page) else { return }
        if let rect = record.rects.first { pdfView.go(to: rect.insetBy(dx: -20, dy: -35), on: page) } else { pdfView.go(to: page) }
    }

    private func selectedText() -> String? {
        guard let text = pdfView.currentSelection?.string?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            showMessage("Select text in the PDF first. Scanned pages need OCR before text can be selected.")
            return nil
        }
        return text
    }

    private func newRecord(type: AnnotationType, page: PDFPage, rects: [CGRect], paths: [[CGPoint]] = [], text: String?, comment: String = "") -> PDFKitAnnotationRecord? {
        guard let document else { return nil }
        let index = document.index(for: page)
        let bounds = rects.first ?? paths.first?.first.map { CGRect(origin: $0, size: CGSize(width: 1, height: 1)) } ?? .zero
        let textOffset = page.selection(for: bounds)?.range(at: 0, on: page).location ?? 0
        let offset = textOffset == NSNotFound ? 0 : textOffset
        let y = max(0, Int((page.bounds(for: .mediaBox).maxY - bounds.maxY).rounded()))
        let sortIndex = String(format: "%05d|%06d|%05d", index, offset, y)
        let labels = DefaultAnnotationPageLabel.read(
            attachmentKey: store.attachmentKey, libraryId: store.libraryId, dbStorage: store.dbStorage, queue: .main
        )
        let pageLabel = labels.label(for: index) ?? page.label ?? "\(index + 1)"
        return PDFKitAnnotationRecord(type: type, page: index, pageLabel: pageLabel, rects: rects, paths: paths,
                                      lineWidth: type == .ink ? 2 : nil, text: text, comment: comment, color: color,
                                      userId: store.userId, author: Defaults.shared.displayName, sortIndex: sortIndex)
    }

    private func addMarkup(_ type: AnnotationType) {
        guard selectedText() != nil, let selection = pdfView.currentSelection, let document else { return }
        guard document.allowsCommenting, store.canEdit() else { showMessage("This PDF or library is read-only."); return }
        var pending: [PDFKitAnnotationRecord] = []
        for page in selection.pages {
            let lines = selection.selectionsByLine().filter { $0.pages.contains(page) }
            let rects = lines.map { $0.bounds(for: page) }.filter { !$0.isEmpty && !$0.isInfinite && !$0.isNull }
            let text = lines.compactMap(\.string).joined(separator: "\n")
            if !rects.isEmpty, let record = newRecord(type: type, page: page, rects: rects, text: TextConverter.convertTextForAnnotation(from: text)) {
                pending.append(record)
            }
        }
        do {
            // A selection spanning pages becomes one Zotero annotation per page, matching Zotero's position model.
            try store.create(pending)
            pdfView.clearSelection()
        } catch { showError(error) }
    }

    private func addNote() {
        guard let page = pdfView.currentSelection?.pages.first ?? pdfView.currentPage else { return }
        guard document?.allowsCommenting == true, store.canEdit() else { showMessage("This PDF or library is read-only."); return }
        let text = pdfView.currentSelection?.string
        let position = pdfView.currentSelection.map { $0.bounds(for: page).origin }
            ?? pdfView.convert(CGPoint(x: pdfView.bounds.midX, y: pdfView.bounds.midY), to: page)
        let crop = page.bounds(for: .cropBox)
        let rect = CGRect(x: min(max(position.x, crop.minX), crop.maxX - 22), y: min(max(position.y, crop.minY), crop.maxY - 22), width: 22, height: 22)
        editComment(title: "New note", comment: "") { [weak self] comment in
            guard let self, !comment.isEmpty,
                  let record = self.newRecord(type: .note, page: page, rects: [rect], text: text, comment: comment) else { return }
            try self.store.create(record)
            self.pdfView.clearSelection()
        }
    }

    @objc private func togglePen() {
        guard document?.allowsCommenting == true, store.canEdit() else { showMessage("This PDF or library is read-only."); return }
        penEnabled.toggle()
        drawing.isHidden = !penEnabled
        drawing.inkColor = UIColor(hex: color)
        penButton.tintColor = penEnabled ? .systemRed : nil
        penButton.accessibilityLabel = penEnabled ? "Stop handwriting to scroll PDF" : "Start handwriting"
        navigationItem.prompt = penEnabled ? "Drawing · tap the red pencil to resume scrolling" : nil
        if !penEnabled { drawing.cancelStroke() }
    }

    private func saveInk(page: PDFPage, points: [CGPoint]) {
        let records = PDFKitAnnotationRecord.inkChunks(points).compactMap {
            newRecord(type: .ink, page: page, rects: [], paths: [$0], text: nil)
        }
        guard !records.isEmpty else { return }
        do { try store.create(records) } catch { showError(error) }
    }

    private func chooseColor(for record: PDFKitAnnotationRecord? = nil) {
        let alert = UIAlertController(title: "Annotation color", message: nil, preferredStyle: .actionSheet)
        for hex in AnnotationsConfig.allColors {
            alert.addAction(UIAlertAction(title: AnnotationsConfig.colorNames[hex] ?? hex, style: .default) { [weak self] _ in
                guard let self else { return }
                if let record {
                    do { try self.store.edit(record, color: hex) } catch { self.showError(error) }
                } else {
                    self.color = hex
                    self.drawing.inkColor = UIColor(hex: hex)
                }
            })
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        anchor(alert)
        present(alert, animated: true)
    }

    @objc private func annotationTapped(_ recognizer: UITapGestureRecognizer) {
        guard presentedViewController == nil, !penEnabled, pdfView.currentSelection?.string?.isEmpty != false,
              let page = pdfView.page(for: recognizer.location(in: pdfView), nearest: false) else { return }
        let point = pdfView.convert(recognizer.location(in: pdfView), to: page)
        for annotation in page.annotations.reversed() {
            guard annotation.bounds.insetBy(dx: -3, dy: -3).contains(point),
                  let record = recordByAnnotation[ObjectIdentifier(annotation)] else { continue }
            annotationActions(record)
            return
        }
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool { true }

    private func annotationActions(_ record: PDFKitAnnotationRecord) {
        let alert = UIAlertController(title: "Page \(record.pageLabel)", message: [record.text, record.comment.strippedRichTextTags].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n\n"), preferredStyle: .actionSheet)
        alert.addAction(UIAlertAction(title: "Copy text", style: .default) { _ in UIPasteboard.general.string = record.text ?? record.comment.strippedRichTextTags })
        if let text = record.text, !text.isEmpty {
            alert.addAction(UIAlertAction(title: "Translate annotation", style: .default) { [weak self] _ in self?.translate(text, annotation: record) })
        }
        if store.canEdit(record) {
            alert.addAction(UIAlertAction(title: "Edit comment", style: .default) { [weak self] _ in
                self?.editComment(title: "Annotation comment", comment: record.comment.strippedRichTextTags) { [weak self] text in
                    guard let self, text != record.comment.strippedRichTextTags else { return }
                    try self.store.edit(record, comment: text)
                }
            })
            alert.addAction(UIAlertAction(title: "Change color", style: .default) { [weak self] _ in self?.chooseColor(for: record) })
            alert.addAction(UIAlertAction(title: "Delete annotation", style: .destructive) { [weak self] _ in self?.confirmDelete(record) })
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        anchor(alert)
        presentAfterDismissal(alert)
    }

    private func confirmDelete(_ record: PDFKitAnnotationRecord) {
        let alert = UIAlertController(title: "Delete annotation?", message: "This deletion will sync to your Zotero library.", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Delete", style: .destructive) { [weak self] _ in
            guard let self else { return }
            do { try self.store.delete(record) } catch { self.showError(error) }
        })
        present(alert, animated: true)
    }

    private func editComment(title: String, comment: String, save: @escaping (String) throws -> Void) {
        let editor = PDFKitCommentController(text: comment, save: save)
        editor.title = title
        let navigation = UINavigationController(rootViewController: editor)
        navigation.modalPresentationStyle = .pageSheet
        present(navigation, animated: true)
    }

    @objc private func translateSelection() {
        guard let text = selectedText() else { return }
        translate(text, annotation: nil)
    }

    private func cancelTranslation() {
        translationID = nil
        translationTask?.cancel()
        translationTask = nil
        if let systemHost {
            self.systemHost = nil
            if systemHost.presentingViewController != nil { systemHost.dismiss(animated: true) }
        }
    }

    private func translate(_ text: String, annotation: PDFKitAnnotationRecord?) {
        cancelTranslation()
        let id = UUID()
        translationID = id
        if PDFTranslationSettingsStore.provider == "apple" {
            if #available(iOS 18.0, *) {
                let host = PDFKitSystemTranslationController(
                    text: text, target: PDFTranslationSettingsStore.targetLanguage,
                    cancel: { [weak self] in self?.cancelTranslation() },
                    completion: { [weak self] result in self?.finishTranslation(result, id: id, original: text, annotation: annotation) }
                )
                host.modalPresentationStyle = .pageSheet
                host.isModalInPresentation = true
                systemHost = host
                present(host, animated: true)
            } else {
                showMessage("Apple Translation requires iOS 18 or later.")
            }
            return
        }
        let alert = UIAlertController(title: "Translating…", message: nil, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { [weak self] _ in self?.cancelTranslation() })
        translationAlert = alert
        present(alert, animated: true) { [weak self] in
            guard let self, self.translationID == id else { return }
            self.translationTask = Task { [weak self] in
                do {
                    let translated = try await PDFTranslationService.translate(text: text, provider: PDFTranslationSettingsStore.provider,
                                                                               endpoint: PDFTranslationSettingsStore.endpoint, model: PDFTranslationSettingsStore.model,
                                                                               targetLanguage: PDFTranslationSettingsStore.targetLanguage, apiKey: PDFTranslationSettingsStore.apiKey)
                    try Task.checkCancellation()
                    await MainActor.run { self?.finishTranslation(.success(translated), id: id, original: text, annotation: annotation) }
                } catch {
                    guard !Task.isCancelled else { return }
                    await MainActor.run { self?.finishTranslation(.failure(error), id: id, original: text, annotation: annotation) }
                }
            }
        }
    }

    private func finishTranslation(_ result: Result<String, Error>, id: UUID, original: String, annotation: PDFKitAnnotationRecord?) {
        guard translationID == id else { return }
        let alert: UIViewController? = systemHost ?? translationAlert
        translationAlert = nil
        let show = { [weak self] in
            guard let self, self.translationID == id else { return }
            self.cancelTranslation()
            switch result {
            case .failure(let error): self.showError(error)

            case .success(let text):
                var saveAnnotation: ((String) -> Void)?
                if let annotation, self.store.canEdit(annotation) {
                    saveAnnotation = { [weak self] translated in
                        guard let self else { return }
                        self.editComment(title: "Save translation to comment", comment: annotation.comment.isEmpty ? translated : annotation.comment.strippedRichTextTags + "\n\n" + translated) { [weak self] comment in
                            guard let self else { return }
                            try self.store.edit(annotation, comment: comment)
                        }
                    }
                }
                var saveNote: (() -> Void)?
                if let editor = NoteEditorViewController.activeEditor, editor.canInsertTranslation(in: self.view.window?.windowScene) {
                    saveNote = { [weak self, weak editor] in
                        guard let self, let editor, editor.canInsertTranslation(in: self.view.window?.windowScene) else { return }
                        editor.insertHTMLAtCurrentSelection(PDFTranslationResultViewController.noteHTML(original: original, translated: text))
                    }
                }
                PDFTranslationFloatingController.show(PDFTranslationResultViewController(originalText: original, translatedText: text,
                                                                                         translationCompletion: saveAnnotation, noteInsertionCompletion: saveNote), in: self)
            }
        }
        if alert?.presentingViewController != nil { alert?.dismiss(animated: true, completion: show) } else { show() }
    }

    @objc private func toggleReaderSidebar() {
        if traitCollection.horizontalSizeClass == .compact {
            let controller = PDFKitSidebarController()
            controller.document = document
            controller.records = store.records
            controller.onSelectPage = { [weak self, weak controller] page in controller?.dismiss(animated: true) { self?.go(to: page) } }
            controller.onSelectAnnotation = { [weak self, weak controller] record in controller?.dismiss(animated: true) { self?.focus(record) } }
            controller.onEditAnnotation = { [weak self, weak controller] record in controller?.dismiss(animated: true) { self?.annotationActions(record) } }
            present(UINavigationController(rootViewController: controller), animated: true)
        } else {
            sidebarVisible.toggle()
            sidebar.view.isHidden = !sidebarVisible
            sidebarWidth.constant = sidebarVisible ? sidebarSize : 0
            view.setNeedsLayout()
        }
    }

    @objc private func searchDocument() {
        guard let document else { return }
        let search = PDFKitSearchController(document: document)
        search.onSelect = { [weak self, weak search] selection in
            search?.dismiss(animated: true) {
                self?.pdfView.setCurrentSelection(selection, animate: true)
                self?.pdfView.go(to: selection)
            }
        }
        present(UINavigationController(rootViewController: search), animated: true)
    }

    @objc private func jumpToPage() {
        let alert = UIAlertController(title: "Go to page", message: "1–\(document?.pageCount ?? 0)", preferredStyle: .alert)
        alert.addTextField { $0.keyboardType = .numberPad }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Go", style: .default) { [weak self, weak alert] _ in
            guard let self, let text = alert?.textFields?.first?.text, let page = Int(text), page > 0, page <= (self.document?.pageCount ?? 0) else { return }
            self.go(to: page - 1)
        })
        present(alert, animated: true)
    }

    private func exportPDF() {
        guard let document, let copy = PDFKit.PDFDocument(url: url), !copy.isLocked else {
            showMessage("Export is unavailable for this locked PDF.")
            return
        }
        guard document.allowsPrinting else { showMessage("This PDF does not permit export."); return }
        for record in store.records {
            if let annotation = record.pdfAnnotation() { copy.page(at: record.page)?.addAnnotation(annotation) }
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("PDFKitExport-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let output = folder.appendingPathComponent(url.lastPathComponent)
            guard copy.write(to: output) else { throw CocoaError(.fileWriteUnknown) }
            let share = UIActivityViewController(activityItems: [output], applicationActivities: nil)
            share.popoverPresentationController?.barButtonItem = navigationItem.rightBarButtonItems?.first
            share.completionWithItemsHandler = { _, _, _, _ in try? FileManager.default.removeItem(at: folder) }
            present(share, animated: true)
        } catch {
            try? FileManager.default.removeItem(at: folder)
            showError(error)
        }
    }

    @objc private func closeReader() { navigationController?.dismiss(animated: true) }

    private func showError(_ error: Error) { showMessage(error.localizedDescription) }

    private func showMessage(_ message: String) {
        let alert = UIAlertController(title: "PDF Reader", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        presentAfterDismissal(alert)
    }

    private func presentAfterDismissal(_ controller: UIViewController) {
        // Alerts can be triggered while a sidebar or action sheet is closing.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if let presented = self.presentedViewController {
                presented.dismiss(animated: true) { self.present(controller, animated: true) }
            } else { self.present(controller, animated: true) }
        }
    }

    private func anchor(_ alert: UIAlertController) {
        alert.popoverPresentationController?.sourceView = toolbar
        alert.popoverPresentationController?.sourceRect = toolbar.bounds
    }
}

private final class PDFKitSelectionView: PDFView {
    var onTranslate: (() -> Void)?
    var onHighlight: (() -> Void)?
    var onUnderline: (() -> Void)?
    var onNote: (() -> Void)?
    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if [#selector(translateText), #selector(highlightText), #selector(underlineText), #selector(noteText)].contains(action) {
            return !(currentSelection?.string?.isEmpty ?? true)
        }
        return super.canPerformAction(action, withSender: sender)
    }
    @objc func translateText() { onTranslate?() }
    @objc func highlightText() { onHighlight?() }
    @objc func underlineText() { onUnderline?() }
    @objc func noteText() { onNote?() }
}

private final class PDFKitCommentController: UIViewController {
    private let textView = UITextView()
    private let initialText: String
    private let save: (String) throws -> Void
    init(text: String, save: @escaping (String) throws -> Void) {
        initialText = text
        self.save = save
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        textView.text = initialText
        textView.font = .preferredFont(forTextStyle: .body)
        textView.adjustsFontForContentSizeCategory = true
        textView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(textView)
        NSLayoutConstraint.activate([
            textView.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 12),
            textView.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -12),
            textView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            textView.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor)
        ])
        navigationItem.leftBarButtonItem = UIBarButtonItem(barButtonSystemItem: .cancel, target: self, action: #selector(cancel))
        navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .save, target: self, action: #selector(saveText))
    }
    @objc private func cancel() { dismiss(animated: true) }
    @objc private func saveText() {
        let text = textView.text ?? ""
        do {
            try save(text)
            dismiss(animated: true)
        } catch {
            let alert = UIAlertController(title: "Could not save comment", message: error.localizedDescription, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default))
            present(alert, animated: true)
        }
    }
}

private final class PDFKitInkView: UIView {
    weak var pdfView: PDFView?
    var onStroke: ((PDFPage, [CGPoint]) -> Void)?
    var inkColor = UIColor.systemYellow
    private var page: PDFPage?
    private var points: [CGPoint] = []
    private var preview: [CGPoint] = []
    override init(frame: CGRect) { super.init(frame: frame); isOpaque = false; backgroundColor = .clear }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first, let pdfView else { return }
        let point = touch.location(in: pdfView)
        guard let page = pdfView.page(for: point, nearest: false) else { return }
        self.page = page
        points = [pdfView.convert(point, to: page)]
        preview = [touch.location(in: self)]
    }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first, let pdfView, let page else { return }
        for sample in event?.coalescedTouches(for: touch) ?? [touch] {
            points.append(pdfView.convert(sample.location(in: pdfView), to: page))
            preview.append(sample.location(in: self))
        }
        setNeedsDisplay()
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        if let page { onStroke?(page, points) }
        cancelStroke()
    }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { cancelStroke() }
    func cancelStroke() { page = nil; points.removeAll(); preview.removeAll(); setNeedsDisplay() }
    override func draw(_ rect: CGRect) {
        let path = UIBezierPath()
        for (index, point) in preview.enumerated() {
            if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        inkColor.setStroke()
        path.lineWidth = 2 * (pdfView?.scaleFactor ?? 1)
        path.lineCapStyle = .round
        path.stroke()
    }
}

@available(iOS 18.0, *)
private struct PDFKitSystemTranslationView: View {
    let text: String
    let target: String
    let cancel: () -> Void
    let completion: (Result<String, Error>) -> Void
    var body: some View {
        VStack(spacing: 24) {
            ProgressView("Translating…")
            Text("Apple Translation may ask to download languages for offline use.")
                .multilineTextAlignment(.center)
            Button("Cancel", action: cancel)
        }
        .padding()
        .translationTask(source: nil, target: Locale.Language(identifier: languageCode)) { session in
            do {
                let response = try await session.translate(text)
                try Task.checkCancellation()
                await MainActor.run { completion(.success(response.targetText)) }
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run { completion(.failure(error)) }
            }
        }
    }
    private var languageCode: String {
        switch target.lowercased() {
        case "chinese", "zh", "zh-cn", "zh-hans": return "zh-Hans"
        case "traditional chinese", "zh-tw", "zh-hant": return "zh-Hant"
        case "english": return "en"
        case "japanese": return "ja"
        case "korean": return "ko"
        case "german": return "de"
        case "french": return "fr"
        case "spanish": return "es"
        default: return target
        }
    }
}

@available(iOS 18.0, *)
private final class PDFKitSystemTranslationController: UIHostingController<PDFKitSystemTranslationView> {
    init(text: String, target: String, cancel: @escaping () -> Void, completion: @escaping (Result<String, Error>) -> Void) {
        super.init(rootView: PDFKitSystemTranslationView(text: text, target: target, cancel: cancel, completion: completion))
        view.backgroundColor = .systemBackground
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
