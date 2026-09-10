import SwiftUI

struct WorkspaceToolbarConnectionIdentity: View {
    @Bindable var model: WorkspaceToolbarModel

    var body: some View {
        WorkspaceConnectionIdentity(
            profileName: model.model.profileName,
            endpoint: model.model.connectionEndpoint,
            databaseName: model.model.databaseContextName,
            showsDatabase: model.showsDatabaseSelection,
            connectionState: model.model.connectionState
        )
        .fixedSize(horizontal: false, vertical: true)
    }
}
