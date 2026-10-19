import SwiftUI

/// Embedded editors use their own bounds, rather than the window's safe area,
/// and clip the text and gutter before they reach adjacent workflow controls.
struct SchemaComparisonSQLView: View {
    let ddl: String
    var body: some View {
        WorkspaceDatabaseDDLView(ddl: ddl, wrapsLines: true, usesLocalContentInsets: true)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
    }
}
