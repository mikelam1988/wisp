// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

public struct SystemPrompt: Equatable {
    public struct Control: Equatable {
        public enum Kind: UInt8 { case button, text, secureText }
        public let kind: Kind
        public let label: String
        public let enabled: Bool
        public let value: String

        public init(kind: Kind, label: String, enabled: Bool, value: String = "") {
            self.kind = kind
            self.label = label
            self.enabled = enabled
            self.value = kind == .text ? value : ""
        }
    }

    /// Frames are in points from the top left of the host window.
    public struct Layout: Codable, Equatable {
        public struct Label: Codable, Equatable {
            public let text: String
            public let frame: CGRect
            public init(_ text: String, _ frame: CGRect) { self.text = text; self.frame = frame }
        }
        public var size: CGSize
        public var controls: [CGRect]
        public var labels: [Label]
        public var icon: CGRect?
        public var iconPNG: Data?
        public var localNetwork: Bool
        public var dark: Bool
        public var authorization: Bool?
        public var defaultButton: UInt8?
        public var capturable: Bool

        public init(size: CGSize, controls: [CGRect], labels: [Label], icon: CGRect?,
                    localNetwork: Bool, dark: Bool, capturable: Bool, iconPNG: Data? = nil,
                    authorization: Bool? = nil, defaultButton: UInt8? = nil) {
            self.authorization = authorization
            self.defaultButton = defaultButton
            self.iconPNG = iconPNG
            self.size = size
            self.controls = controls
            self.labels = labels
            self.icon = icon
            self.localNetwork = localNetwork
            self.dark = dark
            self.capturable = capturable
        }

        public func fits(controlCount: Int) -> Bool {
            let bounds = CGRect(origin: .zero, size: size)
            let frames = controls + labels.map(\.frame) + (icon.map { [$0] } ?? [])
            return (80...1600).contains(size.width) && (50...1200).contains(size.height)
                && controls.count == controlCount && labels.count <= 6
                && frames.allSatisfy { !$0.isEmpty && bounds.contains($0) }
        }
    }
    public let layout: Layout?
    public static let maxControls = 12
    public let id: UInt32
    public let revision: UInt32
    public let text: String
    public let controls: [Control]

    public init(id: UInt32, revision: UInt32 = 0, text: String = "", controls: [Control] = [], layout: Layout? = nil) {
        self.layout = layout
        self.id = id
        self.revision = revision
        self.text = text
        self.controls = controls
    }

    public func hasSameLayout(as other: Self) -> Bool {
        id == other.id && layout == other.layout && text == other.text && controls.count == other.controls.count
            && zip(controls, other.controls).allSatisfy { $0.kind == $1.kind && $0.label == $1.label }
    }

    public func encode() -> Data {
        message(.hostSystemPrompt) {
            $0.u32(id)
            $0.str(text, max: 800)
            $0.u32(revision)
            let shown = controls.prefix(Self.maxControls)
            $0.u8(UInt8(shown.count))
            for control in shown {
                $0.u8(control.kind.rawValue)
                $0.u8(control.enabled ? 1 : 0)
                $0.str(control.label, max: 200)
                $0.str(control.value, max: 1024)
            }
            if let layout, let data = try? PropertyListEncoder().encode(layout), data.count <= 48000 {
                $0.bytes(data)
            }
        }
    }

    public static func decode(_ data: Data) -> Self? {
        var r = Reader(data)
        guard let id = r.u32() else { return nil }
        let text = r.str() ?? ""
        // Earlier hosts send only the ID and text.
        guard let revision = r.u32(), let count = r.u8() else { return Self(id: id, text: text) }
        guard count <= maxControls else { return nil }
        var controls: [Control] = []
        for _ in 0..<count {
            guard let raw = r.u8(), let kind = Control.Kind(rawValue: raw),
                  let enabled = r.u8(), enabled <= 1, let label = r.str(), let value = r.str() else { return nil }
            controls.append(Control(kind: kind, label: label, enabled: enabled == 1, value: value))
        }
        let layout = (1...48000).contains(r.remaining) ? try? PropertyListDecoder().decode(Layout.self, from: r.rest()) : nil
        return Self(id: id, revision: revision, text: text, controls: controls,
                    layout: layout?.fits(controlCount: controls.count) == true ? layout : nil)
    }
}

public struct SystemPromptAction {
    public let id: UInt32
    public let revision: UInt32
    public let button: UInt8?
    public let edits: [UInt8: String]

    public init(id: UInt32, revision: UInt32, button: UInt8?, edits: [UInt8: String]) {
        self.id = id
        self.revision = revision
        self.button = button
        self.edits = edits
    }

    public func encode() -> Data {
        message(.systemPromptAction) {
            $0.u32(id)
            $0.u32(revision)
            $0.u8(button ?? .max)
            let fields = edits.sorted { $0.key < $1.key }.prefix(SystemPrompt.maxControls)
            $0.u8(UInt8(fields.count))
            for (index, value) in fields { $0.u8(index); $0.str(value, max: 1024) }
        }
    }

    public static func decode(_ data: Data) -> Self? {
        var r = Reader(data)
        guard let id = r.u32(), let revision = r.u32(), let button = r.u8(),
              let count = r.u8(), count <= SystemPrompt.maxControls else { return nil }
        var edits: [UInt8: String] = [:]
        for _ in 0..<count {
            guard let index = r.u8(), edits[index] == nil, let value = r.str(), value.utf8.count <= 1024 else { return nil }
            edits[index] = value
        }
        guard r.remaining == 0, button != .max || !edits.isEmpty else { return nil }
        return Self(id: id, revision: revision, button: button == .max ? nil : button, edits: edits)
    }
}

/// An original-size PNG may span several length-prefixed control messages.
public struct PromptImageTransfer {
    public static let limit = 2 << 20
    private var id: UInt32 = 0
    private var revision: UInt32 = 0
    private var expected = 0
    private var bytes = Data()

    public init() {}

    public static func send(_ data: Data, id: UInt32, revision: UInt32, packet: (Data) -> Void) {
        guard data.count <= limit else { return }
        var offset = 0
        repeat {
            let end = min(offset + 60000, data.count)
            packet(message(.hostSystemPromptImage) {
                $0.u32(id); $0.u32(revision); $0.u32(UInt32(data.count)); $0.u32(UInt32(offset))
                $0.bytes(data.subdata(in: offset..<end))
            })
            offset = end
        } while offset < data.count
    }

    public mutating func receive(_ payload: Data) -> (UInt32, UInt32, Data)? {
        var r = Reader(payload)
        guard let id = r.u32(), let revision = r.u32(), let size = r.u32(), size <= Self.limit,
              let offset = r.u32(), offset <= size, r.remaining <= Int(size - offset) else { return nil }
        if offset == 0 {
            self.id = id
            self.revision = revision
            expected = Int(size)
            bytes = Data()
        }
        guard self.id == id, self.revision == revision, expected == Int(size), bytes.count == Int(offset) else { return nil }
        bytes.append(r.rest())
        guard bytes.count == expected else { return nil }
        let result = bytes
        self = Self()
        return (id, revision, result)
    }
}
