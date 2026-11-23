// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import WispCommon
import ImageIO

/// The viewer's local representation of the host's current modal prompt.
final class SystemPromptPanel: NSPanel, NSTextFieldDelegate {
    private(set) var prompt: SystemPrompt
    private let send: (SystemPromptAction) -> Void
    private var fields: [UInt8: NSTextField] = [:]
    private var buttons: [UInt8: NSButton] = [:]
    private var sentValues: [UInt8: String] = [:]
    private var pending: SystemPromptAction?
    private var queuedButton: UInt8?
    private var editTimer: Timer?
    private let status = NSTextField(wrappingLabelWithString: "")

    private var surface: PromptSurface?
    private var showWork: DispatchWorkItem?
    override var canBecomeKey: Bool { true }

    init(prompt: SystemPrompt, host: String, send: @escaping (SystemPromptAction) -> Void) {
        self.prompt = prompt
        self.send = send
        let authenticationForm = prompt.layout == nil && prompt.controls.contains { $0.kind == .secureText }
        let width: CGFloat = authenticationForm ? 260 : 368
        let inset: CGFloat = authenticationForm ? 16 : 24
        let contentWidth = width - 2 * inset
        var parts = prompt.text.components(separatedBy: "\n\n").filter { !$0.isEmpty }
        // SecurityAgent may expose a placeholder AX window title before the visible app name.
        if authenticationForm, parts.count > 1, let first = parts.first,
           ["untitled", "未命名", "無標題"].contains(first.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) {
            parts.removeFirst()
        }
        let heading = NSTextField(wrappingLabelWithString: parts.first ?? "macOS is asking for a response.")
        heading.font = .systemFont(ofSize: authenticationForm ? 14 : 17, weight: .semibold)
        heading.alignment = .center
        heading.preferredMaxLayoutWidth = contentWidth
        let bodyText = parts.dropFirst().joined(separator: "\n\n")
        let body = NSTextField(wrappingLabelWithString: bodyText)
        if authenticationForm { body.font = .systemFont(ofSize: 12) }
        body.textColor = .secondaryLabelColor
        body.alignment = .center
        body.preferredMaxLayoutWidth = contentWidth
        func measure(_ label: NSTextField) -> CGFloat {
            label.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: contentWidth, height: 900)).height ?? 22
        }
        let fieldCount = prompt.controls.filter { $0.kind != .button }.count
        let buttonCount = prompt.controls.count - fieldCount
        let height = 138 + measure(heading) + (bodyText.isEmpty ? 0 : measure(body) + 8)
            + CGFloat(fieldCount) * 35 + CGFloat(max(0, (buttonCount - 1) / 3)) * 32
        let measuredSize = prompt.layout?.size ?? CGSize(width: width, height: height)
        let mask: NSWindow.StyleMask = prompt.layout == nil ? [.titled, .closable, .fullSizeContentView] : [.borderless]
        super.init(contentRect: NSRect(origin: .zero, size: measuredSize), styleMask: mask, backing: .buffered, defer: false)
        title = authenticationForm ? "\(Brand.name) · \(host)" : "System prompt on \(host)"
        if authenticationForm { titleVisibility = .hidden }
        titlebarAppearsTransparent = true
        isReleasedWhenClosed = false
        level = .floating
        hidesOnDeactivate = false
        collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        if let layout = prompt.layout {
            let source = layout.authorization == true || prompt.controls.contains { $0.kind == .secureText }
                ? "\(Brand.name) · \(host)" : nil
            let surface = PromptSurface(layout: layout, text: prompt.text, source: source)
            self.surface = surface
            isOpaque = false
            backgroundColor = .clear
            hasShadow = true
            isMovableByWindowBackground = true
            appearance = NSAppearance(named: layout.dark ? .darkAqua : .aqua)
            contentView = surface
            for (index, control) in prompt.controls.enumerated() {
                let view = makeControl(control, index: index)
                view.frame = layout.controls[index]
                if source != nil, let field = view as? NSTextField {
                    styleAuthenticationField(field, control: control)
                }
                surface.addControl(view, primary: layout.defaultButton == UInt8(index))
            }
            surface.addStatus(status)
            update(prompt)
            return
        }
        let icon = NSImageView()
        if authenticationForm {
            icon.image = NSApp.applicationIconImage
            icon.imageScaling = .scaleProportionallyUpOrDown
            NSLayoutConstraint.activate([
                icon.widthAnchor.constraint(equalToConstant: 44),
                icon.heightAnchor.constraint(equalToConstant: 44)
            ])
        } else {
            icon.image = NSImage(systemSymbolName: "macwindow.on.rectangle", accessibilityDescription: nil)
        }
        icon.symbolConfiguration = .init(pointSize: 27, weight: .medium)
        icon.contentTintColor = .controlAccentColor
        let content = NSStackView(views: [icon, heading])
        content.orientation = .vertical
        content.alignment = .centerX
        content.spacing = authenticationForm ? 8 : 10
        content.edgeInsets = NSEdgeInsets(top: authenticationForm ? 34 : 48, left: inset, bottom: 16, right: inset)
        content.wantsLayer = true
        content.layer?.cornerRadius = ViewerController.cornerRadius(of: self)
        content.layer?.borderWidth = 1.5
        content.layer?.borderColor = RemoteView.outlineColor.withAlphaComponent(0.95).cgColor
        contentView = content
        heading.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -2 * inset).isActive = true
        if !bodyText.isEmpty {
            content.addArrangedSubview(body)
            body.widthAnchor.constraint(equalTo: heading.widthAnchor).isActive = true
        }
        var actions: [NSButton] = []
        for (index, control) in prompt.controls.enumerated() {
            let view = makeControl(control, index: index)
            if let button = view as? NSButton {
                if authenticationForm { button.controlSize = .large }
                actions.append(button)
            } else {
                if authenticationForm, let field = view as? NSTextField {
                    styleAuthenticationField(field, control: control)
                }
                content.addArrangedSubview(view)
                view.widthAnchor.constraint(equalTo: heading.widthAnchor).isActive = true
            }
        }
        status.textColor = .secondaryLabelColor
        status.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        status.alignment = .center
        status.isHidden = true
        content.addArrangedSubview(status)
        status.widthAnchor.constraint(equalTo: heading.widthAnchor).isActive = true
        for start in stride(from: 0, to: actions.count, by: 3) {
            let row = NSStackView(views: Array(actions.dropFirst(start).prefix(3)))
            row.orientation = .horizontal
            row.distribution = .fillEqually
            row.spacing = 8
            row.alignment = .centerY
            content.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: heading.widthAnchor).isActive = true
        }
        if !prompt.controls.contains(where: \.enabled) {
            showStatus("The remote Mac requires its original dialog.")
        }
        if authenticationForm {
            content.layoutSubtreeIfNeeded()
            setContentSize(NSSize(width: width, height: ceil(content.fittingSize.height)))
        }
        update(prompt)
    }

    private func styleAuthenticationField(_ field: NSTextField, control: SystemPrompt.Control) {
        field.bezelStyle = .roundedBezel
        field.controlSize = .large
        field.font = .systemFont(ofSize: 13)
        if field.placeholderString?.isEmpty != false {
            field.placeholderString = control.kind == .secureText ? "Password" : "Username"
            field.setAccessibilityLabel(field.placeholderString)
        }
        if control.kind == .secureText, control.enabled { initialFirstResponder = field }
    }

    private func makeControl(_ control: SystemPrompt.Control, index: Int) -> NSControl {
        let id = UInt8(index)
        if control.kind == .button {
            let button = NSButton(title: control.label, target: self, action: #selector(press(_:)))
            button.tag = index
            buttons[id] = button
            return button
        }
        let field = control.kind == .secureText ? NSSecureTextField() : NSTextField()
        field.stringValue = control.value
        field.placeholderString = control.label
        field.setAccessibilityLabel(control.label)
        field.delegate = self
        fields[id] = field
        sentValues[id] = control.value
        return field
    }

    func present() {
        let pointer = NSEvent.mouseLocation
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(pointer) }) ?? NSScreen.main {
            let area = screen.visibleFrame
            let rightInset = min(24, max(0, (area.width - frame.width) / 2))
            let topInset = min(24, max(0, (area.height - frame.height) / 2))
            setFrameTopLeftPoint(NSPoint(x: max(area.minX, area.maxX - frame.width - rightInset),
                                         y: area.maxY - topInset))
        }
        if prompt.layout?.capturable == true {
            let work = DispatchWorkItem { [weak self] in self?.orderFrontRegardless() }
            showWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: work)
        } else { orderFrontRegardless() }
    }

    func receiveImage(_ data: Data) {
        guard let surface, isVisible || showWork != nil else { return }
        surface.showImage(data)
        showWork?.cancel()
        showWork = nil
        if !isVisible { orderFrontRegardless() }
    }

    override func cancelOperation(_ sender: Any?) {
        if !prompt.controls.contains(where: \.enabled) { close() }
        else { super.cancelOperation(sender) }
    }

    func update(_ next: SystemPrompt) {
        for (index, control) in next.controls.enumerated() {
            let id = UInt8(index)
            if let field = fields[id] {
                if control.kind == .text, field.currentEditor() == nil,
                   field.stringValue == sentValues[id] {
                    field.stringValue = control.value
                    sentValues[id] = control.value
                }
                field.isEnabled = control.enabled
            }
        }
        prompt = next
        updateButtons()
    }

    func controlTextDidChange(_ obj: Notification) {
        editTimer?.invalidate()
        editTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: false) { [weak self] _ in
            self?.flushEdits()
        }
    }

    @objc private func press(_ sender: NSButton) {
        queuedButton = UInt8(sender.tag)
        flushEdits()
    }

    private func flushEdits() {
        editTimer?.invalidate()
        editTimer = nil
        guard pending == nil, isVisible else { return }
        let button = queuedButton
        queuedButton = nil
        let edits = fields.reduce(into: [UInt8: String]()) { edits, entry in
            let (id, field) = entry
            let secure = field is NSSecureTextField
            guard field.isEnabled, !secure || button != nil else { return }
            let value = field.currentEditor()?.string ?? field.stringValue
            if value != sentValues[id] { edits[id] = value }
        }
        guard button != nil || !edits.isEmpty else { return }
        guard edits.values.allSatisfy({ $0.utf8.count <= 1024 }) else {
            showStatus("The text is too long to send.")
            return
        }
        let action = SystemPromptAction(id: prompt.id, revision: prompt.revision, button: button, edits: edits)
        pending = action
        showStatus(button == nil ? "" : "Waiting for the remote Mac…")
        updateButtons()
        send(action)
    }

    func receiveResult(_ error: String) {
        guard let action = pending else { return }
        pending = nil
        showStatus(error)
        updateButtons()
        for id in action.edits.keys {
            if let field = fields[id] as? NSSecureTextField {
                field.currentEditor()?.string = ""
                field.stringValue = ""
            }
        }
        guard error.isEmpty else { queuedButton = nil; return }
        for (id, value) in action.edits where !(fields[id] is NSSecureTextField) {
            sentValues[id] = value
        }
        if action.button == nil { flushEdits() }
    }

    override func close() {
        showWork?.cancel()
        showWork = nil
        editTimer?.invalidate()
        pending = nil
        queuedButton = nil
        sentValues.removeAll()
        for field in fields.values where field is NSSecureTextField { field.stringValue = "" }
        super.close()
    }

    private func updateButtons() {
        for (id, button) in buttons {
            button.isEnabled = prompt.controls[Int(id)].enabled && pending?.button == nil
        }
    }

    private func showStatus(_ text: String) {
        status.stringValue = text
        status.isHidden = text.isEmpty
    }
}

/// Main queue. AX and the image use the same top-left coordinate system and point size.
private final class PromptSurface: NSVisualEffectView {
    override var isFlipped: Bool { true }
    private let imageView = NSImageView()
    private var artwork: [NSView] = []
    private var actionButtons: [NSButton] = []

    init(layout: SystemPrompt.Layout, text: String, source: String?) {
        super.init(frame: NSRect(origin: .zero, size: layout.size))
        material = .popover
        blendingMode = .behindWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        layer?.borderWidth = 1.5
        layer?.borderColor = RemoteView.outlineColor.withAlphaComponent(0.95).cgColor
        imageView.frame = bounds
        imageView.imageScaling = .scaleAxesIndependently
        imageView.isHidden = true
        addSubview(imageView)
        let labels = layout.labels.sorted { $0.frame.minY < $1.frame.minY }
        let iconArea = layout.icon ?? CGRect(x: (bounds.width - 64) / 2, y: 16, width: 64, height: 64)
        let url = Bundle(path: "/System/Library/Frameworks/NetworkExtension.framework")?
            .url(forResource: "LocalNetworkPrivacy", withExtension: "png")
        let icon = NSImageView(frame: iconArea)
        icon.image = layout.iconPNG.flatMap { Self.image($0, maxDimension: 256, size: iconArea.size) }
            ?? (layout.localNetwork ? url.flatMap(NSImage.init(contentsOf:)) : nil)
            ?? NSImage(systemSymbolName: "macwindow", accessibilityDescription: nil)
        if let source {
            icon.toolTip = source
            icon.setAccessibilityLabel(source)
            icon.image = NSApp.applicationIconImage
        }
        icon.imageScaling = .scaleProportionallyUpOrDown
        addArtwork(icon)
        if labels.isEmpty {
            let bottom = layout.controls.map(\.minY).min() ?? bounds.height - 16
            addLabel(text.isEmpty ? "macOS is asking for a response." : text,
                     frame: NSRect(x: 14, y: iconArea.maxY + 4, width: bounds.width - 28,
                                   height: max(20, bottom - iconArea.maxY - 10)), heading: true)
        } else {
            for (index, label) in labels.enumerated() {
                addLabel(label.text, frame: label.frame, heading: index == 0)
            }
        }
    }

    required init?(coder: NSCoder) { nil }

    private func addArtwork(_ view: NSView) {
        artwork.append(view)
        addSubview(view)
    }

    private func addLabel(_ text: String, frame: CGRect, heading: Bool) {
        let label = NSTextField(wrappingLabelWithString: text)
        label.alignment = .center
        label.font = .systemFont(ofSize: heading ? 13 : 11, weight: heading ? .bold : .regular)
        label.frame = frame.insetBy(dx: -2, dy: 0)
        addArtwork(label)
    }

    func addControl(_ view: NSControl, primary: Bool) {
        if let button = view as? NSButton {
            button.isBordered = false
            button.font = .systemFont(ofSize: 13)
            button.wantsLayer = true
            button.layer?.cornerRadius = 5
            let fill = primary ? NSColor.controlAccentColor : NSColor.labelColor.withAlphaComponent(0.09)
            button.layer?.backgroundColor = fill.cgColor
            if primary { button.contentTintColor = .white }
            actionButtons.append(button)
        }
        addSubview(view)
    }

    func addStatus(_ status: NSTextField) {
        status.isHidden = true
        status.frame = bounds.insetBy(dx: 10, dy: 8)
        status.frame.size.height = 30
        status.font = .systemFont(ofSize: 11)
        status.alignment = .center
        status.drawsBackground = true
        status.backgroundColor = .windowBackgroundColor
        addSubview(status)
    }

    private static func image(_ data: Data, maxDimension: Int, size: CGSize) -> NSImage? {
        guard !data.isEmpty else { return nil }
        let source = CGImageSourceCreateWithData(data as CFData, nil)
        let properties = source.flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) as? [CFString: Any] }
        let width = properties?[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = properties?[kCGImagePropertyPixelHeight] as? Int ?? 0
        let image = (1...maxDimension).contains(width) && (1...maxDimension).contains(height)
            ? source.flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) } : nil
        return image.map { NSImage(cgImage: $0, size: size) }
    }

    func showImage(_ data: Data) {
        let image = Self.image(data, maxDimension: 4096, size: bounds.size)
        imageView.image = image
        imageView.isHidden = image == nil
        for view in artwork { view.isHidden = image != nil }
        for button in actionButtons {
            button.isTransparent = image != nil
            button.layer?.backgroundColor = image == nil ? NSColor.labelColor.withAlphaComponent(0.09).cgColor : nil
        }
    }
}
