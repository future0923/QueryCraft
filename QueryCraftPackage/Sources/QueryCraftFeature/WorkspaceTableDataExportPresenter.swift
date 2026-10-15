import AppKit

@MainActor
enum WorkspaceTableDataExportPresenter {
    static func chooseDestination(
        target: WorkspaceTableDataExportTarget,
        format: WorkspaceDataExportFormat,
        preferences: WorkspaceDataExportPreferences
    ) {
        let options = preferences.options(for: format)
        let panel = NSSavePanel()
        panel.title = AppCopy.current.text("导出数据", "Export Data")
        panel.prompt = AppCopy.current.text("导出", "Export")
        panel.message = AppCopy.current.text(
            "导出整张表：\(target.selection.databaseName) / \(target.selection.objectName)",
            "Export entire table: \(target.selection.databaseName) / \(target.selection.objectName)"
        )
        panel.canCreateDirectories = true
        panel.allowedContentTypes = [options.contentType]
        panel.isExtensionHidden = false
        let fileName = target.selection.objectName
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        panel.nameFieldStringValue = "\(fileName).\(options.fileExtension)"
        panel.begin { response in
            guard response == .OK, let destination = panel.url else { return }
            WorkspaceDataExportJobManager.shared.enqueue(
                format: format,
                destination: destination,
                makeRequest: { try await target.makeRequest(format: format, preferences: preferences) }
            )
        }
    }
}
