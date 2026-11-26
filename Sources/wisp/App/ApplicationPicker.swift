// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import SwiftUI

struct RemoteApplication: Identifiable {
    /// Catalog path, also used to disambiguate apps with the same display name.
    let id: String
    let name: String
}

/// Presenter and request state for a single viewer session. Main queue only.
@Observable
final class ApplicationPicker {
    let hostLabel: String
    private(set) var apps: [RemoteApplication] = []
    private(set) var icons: [String: NSImage] = [:]
    @ObservationIgnored private var catalogRequest: UInt32?
    private(set) var loading = false
    private(set) var launching = false
    private(set) var status: String?
    var search = ""
    @ObservationIgnored private let client: Client
    @ObservationIgnored private let openWindow: (UInt32) -> Void
    @ObservationIgnored private var panel: NSPanel?
    @ObservationIgnored private var pendingApps: [RemoteApplication] = []
    @ObservationIgnored private var request: UInt32 = 0

    init(hostLabel: String, client: Client, openWindow: @escaping (UInt32) -> Void) {
        self.hostLabel = hostLabel
        self.client = client
        self.openWindow = openWindow
    }

    var matches: [RemoteApplication] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty ? apps : apps.filter {
            $0.name.localizedStandardContains(query) || $0.id.localizedStandardContains(query)
        }
    }

    func show() {
        if panel == nil {
            let size = NSSize(width: 612, height: 452)
            let p = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            p.title = "Launch App on \(hostLabel)"
            p.isReleasedWhenClosed = false
            p.hidesOnDeactivate = false
            p.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
            p.contentMinSize = NSSize(width: 370, height: 300)
            let controller = NSHostingController(rootView: ApplicationPickerView(picker: self))
            controller.sizingOptions = []
            p.contentViewController = controller
            p.setContentSize(size)
            p.center()
            panel = p
        }
        guard let panel else { return }
        let alreadyPresented = panel.isVisible || panel.isMiniaturized
        if panel.isMiniaturized { panel.deminiaturize(nil) }
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
        guard !alreadyPresented, !launching else { return }
        status = nil
        loading = true
        pendingApps = []
        apps = []
        request &+= 1
        catalogRequest = request
        client.requestApplications(request)
        timeout(after: 8, text: "The remote Mac didn’t send its app list.")
    }

    func receive(_ app: RemoteApplication?, request id: UInt32) {
        guard id == request, loading else { return }
        if let app { pendingApps.append(app); return }
        apps = pendingApps
        let ids = Set(apps.map(\.id))
        icons = icons.filter { ids.contains($0.key) }
        pendingApps = []
        loading = false
    }

    func receiveIcon(_ png: Data, for app: String, request id: UInt32) {
        guard catalogRequest == id, let image = NSImage(data: png) else { return }
        icons[app] = image
    }

    func launch(_ app: RemoteApplication?) {
        guard !loading, !launching, let app else { return }
        status = "Opening \(app.name)…"
        launching = true
        request &+= 1
        client.launchApplication(app, request: request)
        timeout(after: 25, text: "The remote Mac didn’t report whether the app opened.")
    }

    func launched(_ window: UInt32, status: String, request id: UInt32) {
        guard id == request, launching else { return }
        launching = false
        if window == 0 {
            self.status = status
        } else {
            panel?.close()
            openWindow(window)
        }
    }

    func close() {
        catalogRequest = nil
        loading = false
        launching = false
        pendingApps = []
        panel?.close()
        panel = nil
    }

    private func timeout(after seconds: Double, text: String) {
        let id = request
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self, request == id, loading || launching else { return }
            loading = false
            launching = false
            pendingApps = []
            status = text
        }
    }
}

private struct ApplicationPickerView: View {
    @Bindable var picker: ApplicationPicker
    @FocusState private var searching: Bool
    @FocusState private var focusedApp: String?
    @State private var hoveredApp: String?

    var body: some View {
        let matches = picker.matches
        let firstMatch = matches.first
        VStack(alignment: .leading, spacing: 10) {
            TextField("Search apps", text: $picker.search)
                .textFieldStyle(.roundedBorder)
                .focused($searching)
                .onSubmit { picker.launch(firstMatch) }
                .onKeyPress(.downArrow) {
                    guard let firstMatch else { return .ignored }
                    focusedApp = firstMatch.id
                    return .handled
                }
                .accessibilityIdentifier("appSearch")
            if picker.loading {
                ProgressView("Loading apps…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if matches.isEmpty {
                Text(picker.apps.isEmpty ? "No apps available." : "No matching apps.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 8)], spacing: 8) {
                        ForEach(matches) { app in
                            Button {
                                picker.launch(app)
                            } label: {
                                VStack(spacing: 5) {
                                    Group {
                                        if let icon = picker.icons[app.id] {
                                            Image(nsImage: icon).resizable()
                                        } else {
                                            Image(systemName: "app.dashed").resizable()
                                                .foregroundStyle(.secondary).padding(8)
                                        }
                                    }
                                    .aspectRatio(contentMode: .fit)
                                    .frame(width: 56, height: 56)
                                    Text(app.name)
                                        .font(.system(size: 12))
                                        .multilineTextAlignment(.center)
                                        .lineLimit(2)
                                        .frame(height: 32, alignment: .top)
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 6)
                                .background {
                                    if hoveredApp == app.id || (searching && !picker.search.isEmpty && app.id == firstMatch?.id) {
                                        RoundedRectangle(cornerRadius: 9).fill(.quaternary)
                                    }
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .focused($focusedApp, equals: app.id)
                            .onHover { inside in
                                if inside { hoveredApp = app.id }
                                else if hoveredApp == app.id { hoveredApp = nil }
                            }
                            .disabled(picker.launching)
                            .help(app.id.hasPrefix("/") ? app.id : "/Applications/" + app.id)
                            .accessibilityLabel(app.name)
                            .accessibilityIdentifier(app.id)
                        }
                    }
                    .padding(4)
                    .focusSection()
                }
                .id(picker.search)
                .accessibilityIdentifier("remoteApplications")
            }
            if let status = picker.status {
                Text(status).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .onAppear { searching = true }
    }
}
