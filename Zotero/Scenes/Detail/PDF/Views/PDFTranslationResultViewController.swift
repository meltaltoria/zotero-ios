//
//  PDFTranslationResultViewController.swift
//  Zotero
//

import UIKit

final class PDFTranslationResultViewController: UIViewController {
    var onClose: (() -> Void)?
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
        originalLabel.adjustsFontForContentSizeCategory = true

        let originalView = makeTextView(text: originalText, secondary: true)

        let translationLabel = UILabel()
        translationLabel.text = "Translation"
        translationLabel.font = .preferredFont(forTextStyle: .headline)
        translationLabel.adjustsFontForContentSizeCategory = true

        let translationView = makeTextView(text: translatedText, secondary: false)

        let copyButton = makeButton(title: "Copy") { [weak self] in
            UIPasteboard.general.string = self?.translatedText
        }

        var buttons = [UIButton]()
        buttons.append(copyButton)

        if let translationCompletion {
            buttons.append(makeButton(title: "Annotation") { [weak self] in
                guard let self else { return }
                translationCompletion(self.translatedText)
                self.closeResult()
            })
        }

        if let noteInsertionCompletion {
            buttons.append(makeButton(title: "Note") { [weak self] in
                noteInsertionCompletion()
                self?.closeResult()
            })
        }

        buttons.append(makeButton(title: "Done") { [weak self] in
            self?.closeResult()
        })

        let buttonStack = UIStackView(arrangedSubviews: buttons)
        buttonStack.axis = .horizontal
        buttonStack.distribution = .fillEqually
        buttonStack.spacing = 12

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

        let scroll = UIScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scroll)
        scroll.addSubview(stack)
        let height = stack.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor, constant: -32)
        height.priority = .defaultHigh
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -16),
            stack.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor, constant: -32),
            height,
            originalView.heightAnchor.constraint(equalTo: translationView.heightAnchor, multiplier: 0.45),
            originalView.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            translationView.heightAnchor.constraint(greaterThanOrEqualToConstant: 80)
        ])
    }

    private func closeResult() {
        if let onClose { onClose() } else { dismiss(animated: true) }
    }

    private func makeTextView(text: String, secondary: Bool) -> UITextView {
        let textView = UITextView()
        textView.text = text
        textView.font = .preferredFont(forTextStyle: .body)
        textView.adjustsFontForContentSizeCategory = true
        textView.textColor = secondary ? .secondaryLabel : .label
        textView.backgroundColor = .secondarySystemBackground
        textView.layer.cornerRadius = 10
        textView.isEditable = false
        textView.isSelectable = true
        textView.textContainerInset = UIEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)
        return textView
    }

    private func makeButton(title: String, action: @escaping () -> Void) -> UIButton {
        let button = UIButton(type: .system)
        button.setTitle(title, for: .normal)
        button.titleLabel?.font = .preferredFont(forTextStyle: .headline)
        button.addAction(UIAction { _ in action() }, for: .touchUpInside)
        return button
    }
}
