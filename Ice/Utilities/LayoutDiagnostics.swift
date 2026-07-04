//
//  LayoutDiagnostics.swift
//  Ice
//

import Cocoa

/// File-based menu bar layout dumper for diagnosing Tahoe persistence issues.
///
/// Appends timestamped blocks to /tmp/barkeep_diag.txt. Off by default; enable with:
/// `defaults write <bundle id> LayoutDiagnosticsEnabled -bool YES`
@MainActor
enum LayoutDiagnostics {
    private static let filePath = "/tmp/barkeep_diag.txt"

    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: "LayoutDiagnosticsEnabled")
    }

    /// Formats a single item line. Pure; unit-tested.
    nonisolated static func formatItemLine(
        windowID: CGWindowID,
        title: String?,
        ownerName: String?,
        ownerPID: pid_t,
        frame: CGRect,
        orderIndex: Int,
        section: String?
    ) -> String {
        let f = "(\(Int(frame.origin.x)),\(Int(frame.origin.y)),\(Int(frame.width))x\(Int(frame.height)))"
        return "#\(orderIndex) wid=\(windowID) title=\(title ?? "<nil>") owner=\(ownerName ?? "<nil>") pid=\(ownerPID) frame=\(f) section=\(section ?? "<uncached>")"
    }

    /// Dumps the full current layout state under the given label.
    static func dump(label: String, appState: AppState) {
        guard isEnabled else {
            return
        }

        var lines = ["", "===== [\(Date.now)] \(label) ====="]

        // Raw window order as the window server reports it.
        let rawIDs = Bridging.getWindowList(option: [.menuBarItems, .activeSpace])
        lines.append("raw window order: \(rawIDs)")

        // One line per item, in window list order, with cached section when known.
        let items = MenuBarItem.getMenuBarItems(onScreenOnly: false, activeSpaceOnly: true)
        let cache = appState.itemManager.itemCache
        for (index, item) in items.enumerated() {
            let section: String? = cache.section(for: item).map { name in
                switch name {
                case .visible: "visible"
                case .hidden: "hidden"
                case .alwaysHidden: "alwaysHidden"
                }
            }
            lines.append(formatItemLine(
                windowID: item.windowID,
                title: item.title,
                ownerName: item.ownerName,
                ownerPID: item.ownerPID,
                frame: item.frame,
                orderIndex: index,
                section: section
            ))
        }

        // Control item preferred positions as stored in defaults.
        for identifier in ControlItem.Identifier.allCases {
            let position: CGFloat? = StatusItemDefaults[.preferredPosition, identifier.rawValue]
            lines.append("preferredPosition[\(identifier.rawValue)]=\(position.map(String.init(describing:)) ?? "<nil>")")
        }

        appendToFile(lines.joined(separator: "\n") + "\n")
    }

    /// Appends raw text to the diagnostics file (also used by the persistence
    /// manager to log match/move outcomes).
    static func appendText(_ text: String) {
        guard isEnabled else {
            return
        }
        appendToFile(text.hasSuffix("\n") ? text : text + "\n")
    }

    private static func appendToFile(_ text: String) {
        guard let data = text.data(using: .utf8) else {
            return
        }
        if let handle = FileHandle(forWritingAtPath: filePath) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: URL(filePath: filePath))
        }
    }
}
