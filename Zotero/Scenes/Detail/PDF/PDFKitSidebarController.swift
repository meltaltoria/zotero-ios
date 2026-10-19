//
//  PDFKitSidebarController.swift
//  Zotero
//

import PDFKit
import UIKit

final class PDFKitSidebarController: UITableViewController, UISearchResultsUpdating {
    var document: PDFKit.PDFDocument? { didSet { buildOutline(); if isViewLoaded { tableView.reloadData() } } }
    var records: [PDFKitAnnotationRecord] = [] { didSet { if isViewLoaded { tableView.reloadData() } } }
    var onSelectAnnotation: ((PDFKitAnnotationRecord) -> Void)?
    var onEditAnnotation: ((PDFKitAnnotationRecord) -> Void)?
    var onSelectPage: ((Int) -> Void)?
    private let segments = UISegmentedControl(items: ["Annotations", "Pages", "Outline"])
    private var outline: [(title: String, page: Int, level: Int)] = []
    private var query = ""
    private let filter = UISearchController(searchResultsController: nil)

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "PDF"
        navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .done, target: self, action: #selector(close))
        tableView.backgroundColor = .secondarySystemBackground
        tableView.estimatedRowHeight = 100
        tableView.rowHeight = UITableView.automaticDimension
        segments.selectedSegmentIndex = 0
        segments.addTarget(self, action: #selector(segmentChanged), for: .valueChanged)
        let container = UIView(frame: CGRect(x: 0, y: 0, width: 300, height: 52))
        segments.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(segments)
        NSLayoutConstraint.activate([
            segments.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            segments.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            segments.centerYAnchor.constraint(equalTo: container.centerYAnchor)
        ])
        tableView.tableHeaderView = container
        filter.searchResultsUpdater = self
        filter.obscuresBackgroundDuringPresentation = false
        filter.searchBar.placeholder = "Filter annotations"
        navigationItem.searchController = filter
        definesPresentationContext = true
    }

    private var filtered: [PDFKitAnnotationRecord] {
        guard !query.isEmpty else { return records }
        return records.filter { ($0.text ?? "").localizedCaseInsensitiveContains(query)
            || $0.comment.strippedRichTextTags.localizedCaseInsensitiveContains(query)
            || $0.tags.contains(where: { $0.name.localizedCaseInsensitiveContains(query) })
        }
    }

    func updateSearchResults(for searchController: UISearchController) {
        query = searchController.searchBar.text ?? ""
        tableView.reloadData()
    }

    @objc private func segmentChanged() { tableView.reloadData() }
    @objc private func close() { dismiss(animated: true) }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch segments.selectedSegmentIndex {
        case 1: return document?.pageCount ?? 0
        case 2: return outline.count
        default: return filtered.count
        }
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "row") ?? UITableViewCell(style: .subtitle, reuseIdentifier: "row")
        var content = cell.defaultContentConfiguration()
        content.textProperties.numberOfLines = 6
        content.secondaryTextProperties.numberOfLines = 4
        cell.accessoryType = .none
        cell.indentationLevel = 0
        switch segments.selectedSegmentIndex {
        case 1:
            let page = document?.page(at: indexPath.row)
            content.text = "Page \(page?.label ?? "\(indexPath.row + 1)")"
            content.image = page?.thumbnail(of: CGSize(width: 52, height: 70), for: .cropBox)
            content.imageProperties.maximumSize = CGSize(width: 52, height: 70)

        case 2:
            let item = outline[indexPath.row]
            content.text = item.title
            content.secondaryText = "Page \(item.page + 1)"
            cell.indentationLevel = min(item.level, 4)

        default:
            let record = filtered[indexPath.row]
            content.text = (record.text?.isEmpty == false ? record.text : record.comment.strippedRichTextTags) ?? record.type.rawValue.capitalized
            content.secondaryText = "Page \(record.pageLabel) · \(record.type.rawValue)\n\(record.comment.strippedRichTextTags)"
            content.image = UIImage(systemName: record.type == .note ? "note.text" : (record.type == .ink ? "pencil.tip" : "highlighter"))
            content.imageProperties.tintColor = UIColor(hex: record.color)
            cell.accessoryType = .detailButton
        }
        cell.contentConfiguration = content
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        switch segments.selectedSegmentIndex {
        case 1: onSelectPage?(indexPath.row)
        case 2: onSelectPage?(outline[indexPath.row].page)
        default: onSelectAnnotation?(filtered[indexPath.row])
        }
    }

    override func tableView(_ tableView: UITableView, accessoryButtonTappedForRowWith indexPath: IndexPath) {
        guard segments.selectedSegmentIndex == 0 else { return }
        onEditAnnotation?(filtered[indexPath.row])
    }

    private func buildOutline() {
        outline.removeAll()
        guard let document, let root = document.outlineRoot else { return }
        func append(_ parent: PDFOutline, level: Int) {
            for index in 0..<parent.numberOfChildren {
                guard let item = parent.child(at: index) else { continue }
                if let page = item.destination?.page {
                    let pageIndex = document.index(for: page)
                    if pageIndex != NSNotFound { outline.append((item.label ?? "Untitled", pageIndex, level)) }
                }
                append(item, level: level + 1)
            }
        }
        append(root, level: 0)
    }
}

final class PDFKitSearchController: UITableViewController, UISearchResultsUpdating, PDFDocumentDelegate {
    private let document: PDFKit.PDFDocument
    private let search = UISearchController(searchResultsController: nil)
    private var matches: [PDFSelection] = []
    private var pending: DispatchWorkItem?
    var onSelect: ((PDFSelection) -> Void)?

    init(document: PDFKit.PDFDocument) {
        self.document = document
        super.init(style: .plain)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit { pending?.cancel() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Find in PDF"
        document.delegate = self
        search.searchResultsUpdater = self
        search.obscuresBackgroundDuringPresentation = false
        navigationItem.searchController = search
        navigationItem.hidesSearchBarWhenScrolling = false
        navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .done, target: self, action: #selector(close))
        definesPresentationContext = true
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        pending?.cancel()
        document.cancelFindString()
        document.delegate = nil
    }

    func updateSearchResults(for searchController: UISearchController) {
        pending?.cancel()
        document.cancelFindString()
        matches.removeAll()
        tableView.reloadData()
        let query = searchController.searchBar.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !query.isEmpty else { return }
        let work = DispatchWorkItem { [weak self] in
            self?.document.beginFindString(query, withOptions: .caseInsensitive)
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    func didMatchString(_ instance: PDFSelection) {
        guard matches.count < 500 else { document.cancelFindString(); return }
        matches.append(instance)
        tableView.insertRows(at: [IndexPath(row: matches.count - 1, section: 0)], with: .none)
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { matches.count }
    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "match") ?? UITableViewCell(style: .subtitle, reuseIdentifier: "match")
        let selection = matches[indexPath.row]
        cell.textLabel?.text = selection.string
        cell.detailTextLabel?.text = selection.pages.first.map { "Page \(document.index(for: $0) + 1)" }
        return cell
    }
    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) { onSelect?(matches[indexPath.row]) }
    @objc private func close() { dismiss(animated: true) }
}
