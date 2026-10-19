//
//  PDFTranslationFloatingController.swift
//  Zotero
//

import UIKit

/// A child controller keeps the PDF interactive outside the floating result, including on iPhone.
final class PDFTranslationFloatingController: UIViewController {
    private final class PassthroughView: UIView {
        weak var panel: UIView?
        override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
            guard let panel else { return false }
            return panel.frame.contains(point)
        }
    }

    private let result: PDFTranslationResultViewController
    private let panel = UIView()
    private let header = UIView()
    private let content = UIView()
    private let resizeHandle = UIImageView(image: UIImage(systemName: "arrow.up.left.and.arrow.down.right"))
    private var dragStart = CGRect.zero
    private var lastBounds = CGRect.zero
    private var expandedSize = CGSize(width: 420, height: 440)
    private var collapsed = false

    init(result: PDFTranslationResultViewController) {
        self.result = result
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    static func show(_ result: PDFTranslationResultViewController, in parent: UIViewController) {
        parent.children.compactMap { $0 as? PDFTranslationFloatingController }.forEach { $0.close() }
        let controller = PDFTranslationFloatingController(result: result)
        parent.addChild(controller)
        controller.view.frame = parent.view.bounds
        controller.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        parent.view.addSubview(controller.view)
        controller.didMove(toParent: parent)
        result.onClose = { [weak controller] in controller?.close() }
    }

    override func loadView() { view = PassthroughView() }

    override func viewDidLoad() {
        super.viewDidLoad()
        (view as? PassthroughView)?.panel = panel
        panel.backgroundColor = .systemBackground
        panel.layer.cornerRadius = 14
        panel.layer.borderColor = UIColor.separator.cgColor
        panel.layer.borderWidth = 0.5
        panel.layer.shadowColor = UIColor.black.cgColor
        panel.layer.shadowOpacity = 0.25
        panel.layer.shadowRadius = 12
        panel.layer.shadowOffset = CGSize(width: 0, height: 4)
        view.addSubview(panel)
        header.backgroundColor = .secondarySystemBackground
        header.layer.cornerRadius = 14
        panel.addSubview(header)
        panel.addSubview(content)

        let title = UILabel()
        title.text = "Translation · Drag to move"
        title.font = .preferredFont(forTextStyle: .subheadline)
        title.adjustsFontForContentSizeCategory = true
        title.accessibilityLabel = "Translation. Drag the header to move this panel."
        let collapse = UIButton(type: .system)
        collapse.setImage(UIImage(systemName: "minus"), for: .normal)
        collapse.accessibilityLabel = "Collapse or expand translation"
        collapse.addAction(UIAction { [weak self] _ in self?.toggleCollapsed() }, for: .touchUpInside)
        let close = UIButton(type: .system)
        close.setImage(UIImage(systemName: "xmark"), for: .normal)
        close.accessibilityLabel = "Close translation"
        close.addAction(UIAction { [weak self] _ in self?.close() }, for: .touchUpInside)
        let stack = UIStackView(arrangedSubviews: [title, collapse, close])
        stack.spacing = 10
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -6),
            stack.topAnchor.constraint(equalTo: header.topAnchor),
            stack.bottomAnchor.constraint(equalTo: header.bottomAnchor),
            collapse.widthAnchor.constraint(equalToConstant: 44),
            close.widthAnchor.constraint(equalToConstant: 44)
        ])
        header.addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(movePanel(_:))))
        addChild(result)
        content.addSubview(result.view)
        result.didMove(toParent: self)
        resizeHandle.tintColor = .secondaryLabel
        resizeHandle.contentMode = .center
        resizeHandle.isUserInteractionEnabled = true
        resizeHandle.accessibilityLabel = "Resize translation panel"
        resizeHandle.addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(resizePanel(_:))))
        panel.addSubview(resizeHandle)
    }

    /// Used for both dragging and rotation/split-view changes; the header can never leave the safe area.
    static func clampedFrame(_ proposed: CGRect, in bounds: CGRect, collapsed: Bool = false) -> CGRect {
        let width = min(max(proposed.width, min(280, bounds.width)), bounds.width)
        let height = collapsed ? min(48, bounds.height) : min(max(proposed.height, min(280, bounds.height)), bounds.height)
        return CGRect(x: min(max(proposed.minX, bounds.minX), bounds.maxX - width),
                      y: min(max(proposed.minY, bounds.minY), bounds.maxY - height), width: width, height: height)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let bounds = view.safeAreaLayoutGuide.layoutFrame.insetBy(dx: 8, dy: 8)
        guard bounds.width > 0 && bounds.height > 0 else { return }
        if panel.frame == .zero {
            let initial = CGRect(x: bounds.maxX - expandedSize.width, y: bounds.minY + 30, width: expandedSize.width, height: expandedSize.height)
            panel.frame = Self.clampedFrame(initial, in: bounds)
        } else if lastBounds != bounds {
            panel.frame = Self.clampedFrame(panel.frame, in: bounds, collapsed: collapsed)
        }
        lastBounds = bounds
        layoutPanel()
    }

    private func layoutPanel() {
        header.frame = CGRect(x: 0, y: 0, width: panel.bounds.width, height: 48)
        content.frame = CGRect(x: 0, y: 48, width: panel.bounds.width, height: max(0, panel.bounds.height - 68))
        result.view.frame = content.bounds
        resizeHandle.frame = CGRect(x: panel.bounds.width - 44, y: panel.bounds.height - 28, width: 44, height: 28)
        content.isHidden = collapsed
        resizeHandle.isHidden = collapsed
    }

    @objc private func movePanel(_ gesture: UIPanGestureRecognizer) {
        if gesture.state == .began { dragStart = panel.frame }
        let delta = gesture.translation(in: view)
        panel.frame = Self.clampedFrame(dragStart.offsetBy(dx: delta.x, dy: delta.y), in: lastBounds, collapsed: collapsed)
        layoutPanel()
    }

    @objc private func resizePanel(_ gesture: UIPanGestureRecognizer) {
        if gesture.state == .began { dragStart = panel.frame }
        let delta = gesture.translation(in: view)
        var frame = dragStart
        frame.size.width += delta.x
        frame.size.height += delta.y
        panel.frame = Self.clampedFrame(frame, in: lastBounds)
        expandedSize = panel.frame.size
        layoutPanel()
    }

    private func toggleCollapsed() {
        if !collapsed { expandedSize = panel.frame.size }
        collapsed.toggle()
        var frame = panel.frame
        frame.size = collapsed ? CGSize(width: expandedSize.width, height: 48) : expandedSize
        panel.frame = Self.clampedFrame(frame, in: lastBounds, collapsed: collapsed)
        layoutPanel()
    }

    private func close() {
        willMove(toParent: nil)
        view.removeFromSuperview()
        removeFromParent()
    }
}
