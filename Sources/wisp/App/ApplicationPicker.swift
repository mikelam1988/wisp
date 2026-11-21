// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import SwiftUI

struct RemoteApplication: Identifiable {
    /// Catalog path displayed beneath the name, including the system directory for built-in apps.
    let id: String
    let name: String
}

/// Presenter and request state for a single viewer session. Main queue only.
@Observable
final class ApplicationPicker {
    let hostLabel: String
    private(set) var apps: [RemoteApplication] = []
    private(set) var loading = false
    private(set) var launching = false
    private(set) var status: String?
    var search = ""
    var selection: String?
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

    var selectedApp: RemoteApplication? {
        let matches = matches
        return matches.first { $0.id == selection } ?? matches.first
    }

    func show() {
        if panel?.isVisible == true {
            panel?.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }
        if panel == nil {
            let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 460, height: 390),
                            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            p.title = "Launch App on \(hostLabel)"
            p.isReleasedWhenClosed = false
            p.hidesOnDeactivate = false
            p.contentMinSize = NSSize(width: 370, height: 300)
            p.contentViewController = NSHostingController(rootView: ApplicationPickerView(picker: self))
            p.center()
            panel = p
        }
        panel?.makeKeyAndOrderFront(nil)
        NSApp.activate()
        guard !launching else { return }
        status = nil
        loading = true
        pendingApps = []
        apps = []
        selection = nil
        request &+= 1
        client.requestApplications(request)
        timeout(after: 8, text: "The remote Mac didn’t send its app list.")
    }

    func receive(_ app: RemoteApplication?, request id: UInt32) {
        guard id == request, loading else { return }
        if let app { pendingApps.append(app); return }
        apps = pendingApps
        pendingApps = []
        loading = false
        selection = matches.first?.id
    }

    func launch() {
        guard !loading, !launching, let app = selectedApp else { return }
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

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Search apps", text: $picker.search)
                .textFieldStyle(.roundedBorder)
                .focused($searching)
                .accessibilityIdentifier("appSearch")
            if picker.loading {
                ProgressView("Loading apps…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if picker.matches.isEmpty {
                Text(picker.apps.isEmpty ? "No apps available." : "No matching apps.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(picker.matches, selection: $picker.selection) { app in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(app.name)
                        Text(app.id).font(.caption).foregroundStyle(.secondary)
                    }
                    .tag(app.id)
                }
                .accessibilityIdentifier("remoteApplications")
            }
            if let status = picker.status {
                Text(status).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Launch") { picker.launch() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(picker.loading || picker.launching || picker.selectedApp == nil)
            }
        }
        .padding(14)
        .onAppear { searching = true }
        .onChange(of: picker.search) { picker.selection = picker.matches.first?.id }
    }
}
