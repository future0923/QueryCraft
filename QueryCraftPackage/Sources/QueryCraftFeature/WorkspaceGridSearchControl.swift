import SwiftUI

struct WorkspaceGridSearchControl: View {
    @Bindable var controller: WorkspaceGridSearchController

    var body: some View {
        WorkspaceSearchControl(
            isPresented: controller.isPresented,
            isEnabled: controller.canSearch,
            togglePresentation: controller.togglePresentation
        )
    }
}
