// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import Carbon
import WispCommon

/// Text Input Sources is main-thread only. The viewer observes the selection for
/// its login session, including changes made while another app is frontmost.
final class KeyboardInputSource {
    private var observer: NSObjectProtocol?
    private var lastSent: String?

    func start(send: @escaping (String) -> Void) {
        stop()
        observer = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),
            object: nil, queue: .main
        ) { [weak self] _ in self?.publish(send) }
        publish(send)
    }

    private func publish(_ send: (String) -> Void) {
        guard observer != nil, let id = Self.currentID, id != lastSent, id.utf8.count <= 512 else { return }
        lastSent = id
        send(id)
    }

    func stop() {
        if let observer { DistributedNotificationCenter.default().removeObserver(observer) }
        observer = nil
        lastSent = nil
    }

    static var currentID: String? {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { return nil }
        return Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue() as String
    }

    /// Select an enabled keyboard source by exact ID, including the IME mode.
    /// A missing source leaves the user's existing selection intact.
    static func apply(_ id: String) -> Bool {
        guard !IsSecureEventInputEnabled(), let currentID, id != currentID else { return true }
        let filter: [String: Any] = [
            kTISPropertyInputSourceCategory as String: kTISCategoryKeyboardInputSource!,
            kTISPropertyInputSourceID as String: id,
            kTISPropertyInputSourceIsSelectCapable as String: true
        ]
        guard let sources = TISCreateInputSourceList(filter as CFDictionary, false)?.takeRetainedValue() as? [TISInputSource],
              let source = sources.first else {
            Log.info(.host, "input source is not enabled on this Mac: \(id)")
            return false
        }
        let result = TISSelectInputSource(source)
        if result == noErr { Log.info(.host, "selected viewer's input source: \(id)") }
        else { Log.warning(.host, "could not select input source \(id) (\(result))") }
        return result == noErr
    }
}
