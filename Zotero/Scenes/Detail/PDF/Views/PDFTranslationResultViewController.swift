//
//  PDFTranslationResultViewController.swift
//  Zotero
//

import UIKit

final class PDFTranslationResultViewController: UIViewController {
    private let originalText: String
    private let translatedText: String

    private let translationCompletion: ((String) -> Void)?
    private let noteInsertionCompletion: (() -> Void)?

    init(
        originalText: String,
        translatedText: String,
        translationCompletion: ((String) -> Void)? = nil,
        noteInsertionCompletion: (() -> Void)? = nil
    ) {
        self.originalText = originalText
        self.translatedText = translatedText
        self.translationCompletion = translationCompletion
        self.noteInsertionCompletion = noteInsertionCompletion
        super.init(nibName: nil, bundle: nil)
        title = "Translation"
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    static func noteHTML(original: String, translated: String) -> String {
        func escapeHTML(_ text: String) -> String {
            text
                .replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
                .replacingOccurrences(of: "\"", with: "&quot;")
                .replacingOccurrences(of: "'", with: "&#39;")
                .replacingOccurrences(of: "\n", with: "<br>")
        }

        return "<p><strong>Original</strong><br>\(escapeHTML(original))</p><p><strong>Translation</strong><br>\(escapeHTML(translated))</p>"
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        let originalLabel = UILabel()
        originalLabel.text = "Original"
        originalLabel.font = .preferredFont(forTextStyle: .headline)

        let originalView = UITextView()
        originalView.text = originalText
        originalView.font = .preferredFont(forTextStyle: .body)
        originalView.textColor = .secondaryLabel
        originalView.backgroundColor = .secondarySystemBackground
        originalView.layer.cornerRadius = 10
        originalView.isEditable = false
        originalView.isSelectable = true
        originalView.textContainerInset = UIEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)

        let translationLabel = UILabel()
        translationLabel.text = "Translation"
        translationLabel.font = .preferredFont(forTextStyle: .headline)

        let translationView = UITextView()
        translationView.text = translatedText
        translationView.font = .preferredFont(forTextStyle: .body)
        translationView.backgroundColor = .secondarySystemBackground
        translationView.layer.cornerRadius = 10
        translationView.isEditable = false
        translationView.isSelectable = true
        translationView.textContainerInset = UIEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)

        let copyButton = UIButton(type: .system)
        copyButton.setTitle("Copy Translation", for: .normal)
        copyButton.titleLabel?.font = .preferredFont(forTextStyle: .headline)
        copyButton.addAction(UIAction { [weak self] _ in
            UIPasteboard.general.string = self?.translatedText
        }, for: .touchUpInside)

        let closeButton = UIButton(type: .system)
        closeButton.setTitle("Done", for: .normal)
        closeButton.addAction(UIAction { [weak self] _ in
            self?.dismiss(animated: true)
        }, for: .touchUpInside)

        var buttons = [UIButton]()
        buttons.append(copyButton)

        if let translationCompletion {
            let saveButton = UIButton(type: .system)
            saveButton.setTitle("Add to Annotation", for: .normal)
            saveButton.addAction(UIAction { [weak self] _ in
                translationCompletion(self?.translatedText ?? "")
                self?.dismiss(animated: true)
            }, for: .touchUpInside)
            buttons.append(saveButton)
        }

        if let noteInsertionCompletion {
            let noteButton = UIButton(type: .system)
            noteButton.setTitle("Add to Note", for: .normal)
            noteButton.addAction(UIAction { [weak self] _ in
                noteInsertionCompletion()
                self?.dismiss(animated: true)
            }, for: .touchUpInside)
            buttons.append(noteButton)
        }

        buttons.append(closeButton)

        let buttonStack = UIStackView(arrangedSubviews: buttons)
        buttonStack.axis = .horizontal
        buttonStack.distribution = .fillEqually
        buttonStack.spacing = 12
        buttons.axis = .horizontal
        buttons.distribution = .fillEqually
        buttons.spacing = 12

        let stack = UIStackView(arrangedSubviews: [
            originalLabel,
            originalView,
            translationLabel,
            translationView,
            buttonStack
        ])
        stack.axis = .vertical
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -16),
            originalView.heightAnchor.constraint(equalToConstant: 120),
            translationView.heightAnchor.constraint(greaterThanOrEqualToConstant: 220)
        ])
    }
}
