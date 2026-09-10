import SwiftUI

struct WorkspaceDataExportControl: View {
    @Bindable var controller: WorkspaceDataExportController
    @State private var jobManager = WorkspaceDataExportJobManager.shared

    var body: some View {
        HStack(spacing: 6) {
            Button(
                AppCopy.current.text("导出…", "Export..."),
                action: { controller.presentOptions() }
            )
            .buttonStyle(.bordered)
            .buttonBorderShape(.roundedRectangle)
            .controlSize(.regular)
            .frame(height: WorkspaceDataActionControlMetrics.height)
            .help(AppCopy.current.text("导出数据", "Export Data"))
            .accessibilityIdentifier("exportDataButton")

            if jobManager.activeJobCount > 0 {
                Button(
                    AppCopy.current.text("打开导出中心", "Open Export Center"),
                    systemImage: "arrow.down.doc",
                    action: WorkspaceDataExportCenterWindowController.show
                )
                .labelStyle(.iconOnly)
                .buttonStyle(.bordered)
                .buttonBorderShape(.roundedRectangle)
                .controlSize(.regular)
                .frame(height: WorkspaceDataActionControlMetrics.height)
                .help(
                    AppCopy.current.text(
                        "\(jobManager.activeJobCount) 个导出任务",
                        "\(jobManager.activeJobCount) active exports"
                    )
                )
            }
        }
        .sheet(isPresented: $controller.isPresentingOptions) {
            WorkspaceDataExportOptionsView(controller: controller)
        }
        .alert(
            AppCopy.current.text("无法导出数据", "Unable to Export Data"),
            isPresented: $controller.showsError
        ) {
            Button(AppCopy.current.text("好", "OK"), role: .cancel) {}
                .keyboardShortcut(.defaultAction)
        } message: {
            Text(controller.errorMessage)
        }
    }
}
