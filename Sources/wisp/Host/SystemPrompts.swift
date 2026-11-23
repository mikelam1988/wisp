// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import Darwin
import ScreenCaptureKit
import ImageIO
import WispCommon

/// Reads and operates only the frontmost supported system modal.
/// Main queue, while DisplayGate is idle.
final class SystemPromptHost {
    private var published: SystemPrompt?

    private var captureTask: Task<Void, Never>?
    private var lastImage: Data?

    func reset() {
        captureTask?.cancel()
        captureTask = nil
        lastImage = nil
        published = nil
    }

    /// Called on the session tick. Capture just the advertised window, at its backing scale.
    func refreshImage(send: @escaping (Data) -> Void) {
        guard let prompt = published, let layout = prompt.layout, layout.capturable, captureTask == nil else { return }
        captureTask = Task { @MainActor [weak self] in
            let bytes = await Self.capture(id: prompt.id, size: layout.size)
            guard !Task.isCancelled, let self else { return }
            self.captureTask = nil
            guard self.published == prompt, self.lastImage != bytes else { return }
            self.lastImage = bytes
            PromptImageTransfer.send(bytes ?? Data(), id: prompt.id, revision: prompt.revision, packet: send)
        }
    }

    private static func capture(id: CGWindowID, size: CGSize) async -> Data? {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true),
              let window = content.windows.first(where: { $0.windowID == id }), window.frame.size == size else { return nil }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCStreamConfiguration()
        config.width = Int(size.width * CGFloat(filter.pointPixelScale))
        config.height = Int(size.height * CGFloat(filter.pointPixelScale))
        config.ignoreShadowsSingleWindow = true
        config.showsCursor = false
        guard let image = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config),
              !Task.isCancelled else { return nil }
        // Some OS versions return a solid or transparent surface for a protected window.
        let n = 64
        var preview = [UInt8](repeating: 0, count: n * n)
        let visible = preview.withUnsafeMutableBytes { buffer -> Bool in
            guard let ctx = CGContext(data: buffer.baseAddress, width: n, height: n, bitsPerComponent: 8,
                                      bytesPerRow: n, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: n, height: n))
            let middle = (n/4 ..< 3*n/4).flatMap { y in buffer[(y*n + n/4)..<(y*n + 3*n/4)] }
            return Int(middle.max() ?? 0) - Int(middle.min() ?? 0) > 6
        }
        guard visible else { return nil }
        let bitmap = NSBitmapImageRep(cgImage: image)
        guard let png = bitmap.representation(using: .png, properties: [:]), png.count <= PromptImageTransfer.limit else { return nil }
        return png
    }

    func update(locked: Bool, interactive: Bool, appearance: Bool, authorizationLayout: Bool) -> SystemPrompt? {
        let current = locked ? nil : Self.current(interactive: interactive, appearance: appearance, authorizationLayout: authorizationLayout)
        let previous = published
        guard let current else {
            guard published != nil else { return nil }
            reset()
            Log.info(.host, "system prompt dismissed")
            return SystemPrompt(id: 0)
        }
        let revision = previous.flatMap { $0.hasSameLayout(as: current.prompt) ? $0.revision : nil }
            ?? UInt32.random(in: 1 ... .max)
        let prompt = SystemPrompt(id: current.prompt.id, revision: revision, text: current.prompt.text,
                                  controls: current.prompt.controls, layout: current.prompt.layout)
        guard prompt != published else { return nil }
        if previous?.revision != revision {
            captureTask?.cancel()
            captureTask = nil
            lastImage = nil
        }
        published = prompt
        if prompt.id != previous?.id {
            let enabled = prompt.controls.filter(\.enabled).count
            Log.info(.host, "system prompt detected (window \(prompt.id), \(enabled) of \(prompt.controls.count) controls available)")
        }
        return prompt
    }

    func act(_ action: SystemPromptAction, onOpenSettings: () -> Void) -> String {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any],
              session["CGSSessionScreenIsLocked"] as? Bool != true,
              let published, published.id == action.id, published.revision == action.revision,
              let current = Self.current(interactive: true, appearance: published.layout != nil, authorizationLayout: published.layout?.authorization == true), published.hasSameLayout(as: current.prompt)
        else { return "The original prompt changed or is no longer available." }

        let controls = current.prompt.controls
        func accepts(_ index: UInt8, button: Bool) -> Bool {
            guard controls.indices.contains(Int(index)) else { return false }
            let control = controls[Int(index)]
            return control.enabled && (control.kind == .button) == button
        }
        guard action.edits.keys.allSatisfy({ index in
            accepts(index, button: false) && (controls[Int(index)].kind != .secureText || action.button != nil)
        }),
              action.button.map({ accepts($0, button: true) }) ?? true
        else { return "The selected control is no longer available." }

        for (index, value) in action.edits.sorted(by: { $0.key < $1.key }) {
            let field = current.elements[Int(index)]
            guard AXUIElementSetAttributeValue(field, kAXValueAttribute as CFString, value as CFString) == .success
            else { return "macOS rejected the text edit." }
        }
        if let index = action.button {
            let element = current.elements[Int(index)]
            // Resolve the clicked control while its original window is still present.
            var pid: pid_t = 0
            let opensSettings = AXUIElementGetPid(element, &pid) == .success
                && Self.hasExecutable(pid, path: Self.privacyWarningExecutable)
                && Self.settingsButtonTitles.contains(controls[Int(index)].label)
            let result = AXUIElementPerformAction(element, kAXPressAction as CFString)
            guard result == .success else { return "macOS did not confirm the button action (\(result.rawValue))." }
            if opensSettings { onOpenSettings() }
            Log.info(.host, "system prompt action applied (window \(action.id), button \(index))")
        }
        return ""
    }

    private static func current(interactive: Bool, appearance: Bool, authorizationLayout: Bool) -> (prompt: SystemPrompt, elements: [AXUIElement])? {
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return nil }
        for window in windows {
            guard let layer = window[kCGWindowLayer as String] as? Int,
                  let owner = window[kCGWindowOwnerPID as String] as? pid_t,
                  let id = window[kCGWindowNumber as String] as? CGWindowID else { continue }
            let ownerName = window[kCGWindowOwnerName as String] as? String
            let privacyWarning = layer == Int(CGWindowLevelForKey(.normalWindow))
                && ownerName == "universalAccessAuthWarn"
                && hasExecutable(owner, path: Self.privacyWarningExecutable)
            let notification = layer == Int(CGWindowLevelForKey(.modalPanelWindow))
                && NSRunningApplication(processIdentifier: owner)?.bundleIdentifier == "com.apple.UserNotificationCenter"
            if privacyWarning || notification {
                let share = window[kCGWindowSharingState as String] as? Int ?? 0
                let bounds = (window[kCGWindowBounds as String] as? [String: CGFloat])
                    .flatMap { CGRect(dictionaryRepresentation: $0 as CFDictionary) }
                return read(windowID: id, owner: owner, interactive: interactive, appearance: appearance,
                            capturable: share != 0, windowBounds: bounds,
                            privacyWarning: privacyWarning,
                            fallback: privacyWarning ? "Privacy permission request on the remote Mac" : "")
            }
            if layer == Int(CGWindowLevelForKey(.screenSaverWindow)),
               ownerName == "SecurityAgent", hasExecutable(owner, path: Self.securityAgentExecutable) {
                return read(windowID: id, owner: owner, interactive: interactive, appearance: appearance && authorizationLayout,
                            authorization: true, fallback: "Administrator authentication on the remote Mac")
            }
        }
        return nil
    }

    private static let privacyWarningExecutable = "/System/Library/PrivateFrameworks/UniversalAccess.framework/Versions/A/Resources/universalAccessAuthWarn.app/Contents/MacOS/universalAccessAuthWarn"
    private static let securityAgentExecutable = "/System/Library/Frameworks/Security.framework/Versions/A/MachServices/SecurityAgent.bundle/Contents/MacOS/SecurityAgent"

    // The Open System Settings button in Apple's SecurityWarning nib. Match the host's
    // installed translations, including per-app language overrides.
    private static let settingsButtonTitles: Set<String> = {
        let bundle = URL(fileURLWithPath: privacyWarningExecutable).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Resources/SecurityWarning.loctable")
        let translations = (try? Data(contentsOf: bundle)).flatMap {
            try? PropertyListDecoder().decode([String: [String: String]].self, from: $0)
        }
        return Set(translations?.values.compactMap { $0["933.title"] } ?? [])
            .union(["Open System Settings", "打开系统设置", "打開系統設定"])
    }()

    private static func hasExecutable(_ pid: pid_t, path expected: String) -> Bool {
        var path = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { return false }
        return String(cString: path) == expected
    }

    private static let networkBundle = Bundle(path: "/System/Library/Frameworks/NetworkExtension.framework")
    private static let networkIcon: Data? = {
        guard let url = networkBundle?.url(forResource: "LocalNetworkPrivacy", withExtension: "png"),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let icon = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 160
              ] as CFDictionary),
              let data = NSBitmapImageRep(cgImage: icon).representation(using: .png, properties: [:]),
              data.count <= 28000 else { return nil }
        return data
    }()

    private static func read(windowID: CGWindowID, owner: pid_t, interactive: Bool, appearance: Bool = false,
                             capturable: Bool = false, windowBounds: CGRect? = nil, authorization: Bool = false,
                             privacyWarning: Bool = false, fallback: String = "")
        -> (prompt: SystemPrompt, elements: [AXUIElement]) {
        let window = PanelTracker.axWindow(id: windowID, pid: owner)
        // A shareable window with no AX tree can still be displayed read-only.
        guard window != nil || (appearance && capturable && windowBounds != nil)
        else { return (SystemPrompt(id: windowID, text: fallback), []) }
        var labels: [String] = []
        var controls: [SystemPrompt.Control] = []
        var elements: [AXUIElement] = []
        let bounds = appearance ? (window.flatMap(axFrame(of:)) ?? windowBounds) : nil
        var labelFrames: [SystemPrompt.Layout.Label] = []
        var controlFrames: [CGRect] = []
        var icon: CGRect?
        func frame(_ element: AXUIElement) -> CGRect? {
            guard let bounds, let rect = axFrame(of: element) else { return nil }
            let clipped = rect.intersection(bounds)
            guard !clipped.isEmpty else { return nil }
            return clipped.offsetBy(dx: -bounds.minX, dy: -bounds.minY)
        }
        var remaining = 32

        func text(_ element: AXUIElement, _ attribute: String) -> String {
            let value = axString(element, attribute)
            return value == "?" ? "" : value
        }
        func appendLabel(_ value: String) {
            let label = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !label.isEmpty, labels.count < 6, !labels.contains(label) { labels.append(label) }
        }
        func visit(_ element: AXUIElement) {
            guard remaining > 0 else { return }
            remaining -= 1
            let role = axString(element, kAXRoleAttribute)
            let title = text(element, kAXTitleAttribute)
            switch role {
            case kAXStaticTextRole:
                let value = text(element, kAXValueAttribute)
                let string = value.isEmpty ? title : value
                appendLabel(string)
                if !string.isEmpty, let rect = frame(element), labelFrames.count < 6 {
                    labelFrames.append(.init(String(string.prefix(800)), rect))
                }
            case kAXImageRole:
                if icon == nil { icon = frame(element) }
            case kAXButtonRole, kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole:
                guard controls.count < SystemPrompt.maxControls else { return }
                var enabledValue: CFTypeRef?
                AXUIElementCopyAttributeValue(element, kAXEnabledAttribute as CFString, &enabledValue)
                let enabled = interactive && (enabledValue as? Bool ?? true)
                let description = text(element, kAXDescriptionAttribute)
                let label = title.isEmpty ? description : title
                if role == kAXButtonRole {
                    guard !label.isEmpty else { return }
                    var actions: CFArray?
                    AXUIElementCopyActionNames(element, &actions)
                    controls.append(.init(kind: .button, label: label,
                                          enabled: enabled && (actions as? [String] ?? []).contains(kAXPressAction)))
                } else {
                    let secure = axString(element, kAXSubroleAttribute) == kAXSecureTextFieldSubrole
                    var settable = DarwinBoolean(false)
                    AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable)
                    controls.append(.init(kind: secure ? .secureText : .text, label: label,
                                          enabled: enabled && settable.boolValue,
                                          value: interactive && !secure ? text(element, kAXValueAttribute) : ""))
                }
                elements.append(element)
                if let rect = frame(element) { controlFrames.append(rect) }
            default:
                var value: CFTypeRef?
                if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success,
                   let children = value as? [AXUIElement] { children.forEach(visit) }
            }
        }
        if let window {
            let windowTitle = text(window, kAXTitleAttribute)
            if !authorization { appendLabel(windowTitle) }
            visit(window)
            if labels.isEmpty { appendLabel(windowTitle) }
        }
        let message = labels.isEmpty ? fallback : labels.joined(separator: "\n\n")
        let networkMessage = networkBundle?.localizedString(forKey: "APP_WANTS_LOCAL_NETWORK_MESSAGE", value: nil, table: nil)
        let network = networkMessage.map { message.contains($0) } == true
            || ["本地网络", "local network"].contains { message.localizedCaseInsensitiveContains($0) }
        var defaultButton: UInt8?
        if authorization || privacyWarning, let window, bounds != nil {
            var value: CFTypeRef?
            if AXUIElementCopyAttributeValue(window, kAXDefaultButtonAttribute as CFString, &value) == .success,
               let value, let index = elements.firstIndex(where: { CFEqual($0, value) }) {
                defaultButton = UInt8(index)
            }
        }
        let layout = bounds.map {
            SystemPrompt.Layout(size: $0.size, controls: controlFrames, labels: labelFrames, icon: icon,
                                localNetwork: network, dark: NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua,
                                capturable: capturable, iconPNG: network ? networkIcon : nil,
                                authorization: authorization ? true : nil, defaultButton: defaultButton)
        }
        return (SystemPrompt(id: windowID, text: message, controls: controls,
                             layout: layout?.fits(controlCount: controls.count) == true ? layout : nil), elements)
    }
}
