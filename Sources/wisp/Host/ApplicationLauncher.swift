// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import Network
import WispCommon

/// Catalog I/O runs on its own queue. LaunchServices and window lookup run on the main actor.
enum ApplicationLauncher {
    private static let queue = DispatchQueue(label: "wisp.app-catalog", qos: .userInitiated)
    private static let installedRoot = URL(fileURLWithPath: "/Applications", isDirectory: true)
    private static let systemRoot = URL(fileURLWithPath: "/System/Applications", isDirectory: true)
    private static let finder = URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app", isDirectory: true)
    private static let systemPaths = [systemRoot.path, "/System/Cryptexes/App/System/Applications"].map {
        URL(fileURLWithPath: $0, isDirectory: true).resolvingSymlinksInPath().path + "/"
    }

    private struct Entry {
        let id: String
        let name: String
        let url: URL
    }

    static func handle(id: UInt32, app: String?, server: Server, connection: NWConnection) {
        queue.async {
            guard server.isCurrentViewer(connection) else { return }
            let apps = installedApps()
            func send(_ reply: Data) { server.sendAppReply(reply, to: connection) }
            guard let app else {
                for entry in apps {
                    send(message(.appCatalogEntry) { $0.u32(id); $0.str(entry.id, max: 4096); $0.str(entry.name, max: 1024) })
                }
                send(message(.appCatalogEntry) { $0.u32(id) })
                return
            }
            guard let entry = apps.first(where: { $0.id == app }) else {
                send(result(id, status: "This app is no longer in the catalog. Reopen the picker to refresh."))
                return
            }
            Task { @MainActor in
                await launch(entry, request: id, server: server, connection: connection)
            }
        }
    }

    private static func installedApps() -> [Entry] {
        var seen = Set<String>()
        let builtIn = entry(at: finder, id: finder.path).map { [$0] } ?? []
        return (entries(in: installedRoot) + entries(in: systemRoot) + builtIn)
            .filter { seen.insert($0.url.path).inserted }
            .sorted {
                let order = $0.name.localizedStandardCompare($1.name)
                return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
            }
    }

    private static func entries(in root: URL) -> [Entry] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .isHiddenKey]
        guard let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys, options: [.skipsPackageDescendants]) else { return [] }
        let rootPath = root.path + "/"
        let physicalRoot = root.resolvingSymlinksInPath().path + "/"
        var apps: [Entry] = []
        for case let url as URL in files {
            guard let attributes = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            if attributes.isSymbolicLink == true || attributes.isHidden == true { files.skipDescendants() }
            guard url.pathExtension.lowercased() == "app",
                  attributes.isDirectory == true || attributes.isSymbolicLink == true else { continue }
            files.skipDescendants()
            let resolved = url.resolvingSymlinksInPath()
            // Safari's link in /Applications is marked hidden by macOS.
            let systemLink = attributes.isSymbolicLink == true && systemPaths.contains { resolved.path.hasPrefix($0) }
            let visibleApp = attributes.isHidden != true && resolved.path.hasPrefix(physicalRoot)
            guard url.path.hasPrefix(rootPath), visibleApp || systemLink else { continue }
            let id = root == installedRoot ? String(url.path.dropFirst(rootPath.count)) : url.path
            if let app = entry(at: resolved, id: id) { apps.append(app) }
        }
        return apps
    }

    private static func entry(at url: URL, id: String) -> Entry? {
        guard let bundle = Bundle(url: url), bundle.bundleIdentifier != Brand.bundleID,
              bundle.executableURL != nil else { return nil }
        let name = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? url.deletingPathExtension().lastPathComponent
        return Entry(id: id, name: name, url: url)
    }

    @MainActor
    private static func launch(_ entry: Entry, request: UInt32, server: Server, connection: NWConnection) async {
        // LaunchServices and window checks must wait for virtual-display changes to finish.
        await withCheckedContinuation { continuation in DisplayGate.whenIdle { continuation.resume() } }
        guard server.isCurrentViewer(connection) else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.addsToRecentItems = false
        do {
            let running = try await NSWorkspace.shared.openApplication(at: entry.url, configuration: configuration)
            Log.info(.host, "launched from app catalog: \(entry.id) (pid \(running.processIdentifier))")
            let deadline = ContinuousClock.now + .seconds(10)
            while ContinuousClock.now < deadline, server.isCurrentViewer(connection), !running.isTerminated {
                if !DisplayGate.busy, let windows = await Host.windows(for: "finding a launched app's window"),
                   let window = windows.first(where: { $0.owningApplication?.processID == running.processIdentifier }) {
                    server.sendAppReply(result(request, window: window.windowID), to: connection)
                    return
                }
                try await Task.sleep(for: .milliseconds(300))
            }
            let status = running.isTerminated ? "\(entry.name) exited before opening a window." : "\(entry.name) is running on the remote Mac. Open a window there to view it here."
            server.sendAppReply(result(request, status: status), to: connection)
        } catch {
            server.sendAppReply(result(request, status: "Couldn’t open \(entry.name): \(error.localizedDescription)"), to: connection)
        }
    }

    private static func result(_ request: UInt32, window: UInt32 = 0, status: String = "") -> Data {
        message(.appLaunchResult) { $0.u32(request); $0.u32(window); $0.str(status, max: 1024) }
    }
}
