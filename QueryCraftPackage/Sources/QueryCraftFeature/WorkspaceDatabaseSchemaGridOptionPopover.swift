import Observation
import SwiftUI

@MainActor
@Observable
final class WorkspaceDatabaseSchemaGridOptionPopoverModel {
    var options: [WorkspaceDatabaseSchemaOptionPicker.Option] = []
    var selectedValue: String?
    var accessibilityTitle = ""
    var query = ""
    var highlightedValue: String?
    private(set) var focusRequest = 0

    func prepare(
        options: [WorkspaceDatabaseSchemaOptionPicker.Option],
        selectedValue: String?,
        accessibilityTitle: String
    ) {
        self.options = options
        self.selectedValue = selectedValue
        self.accessibilityTitle = accessibilityTitle
        query = ""
        highlightedValue = selectedValue ?? options.first?.value
        focusRequest &+= 1
    }
}

struct WorkspaceDatabaseSchemaGridOptionPopover: View {
    @Bindable var model: WorkspaceDatabaseSchemaGridOptionPopoverModel
    let select: @MainActor (String) -> Void
    let dismiss: @MainActor () -> Void

    private enum Layout {
        static let width: CGFloat = 220
        static let minimumHeight: CGFloat = 240
        static let idealHeight: CGFloat = 320
        static let maximumHeight: CGFloat = 420
    }

    var body: some View {
        VStack(spacing: 0) {
            WorkspaceGridSearchField(
                text: $model.query,
                placeholder: AppCopy.current.text(
                    "搜索选项",
                    "Search Options"
                ),
                focusRequest: model.focusRequest,
                submit: selectHighlightedOption,
                cancel: dismiss,
                accessibilityIdentifier: "databaseSchemaOptionSearchField",
                moveUp: { moveHighlight(by: -1) },
                moveDown: { moveHighlight(by: 1) }
            )
            .padding()

            ScrollViewReader { proxy in
                List(selection: $model.highlightedValue) {
                    if filteredOptions.isEmpty {
                        Text(
                            AppCopy.current.text(
                                "没有匹配的选项",
                                "No Matching Options"
                            )
                        )
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .listRowSeparator(.hidden)
                    } else {
                        ForEach(filteredOptions) { option in
                            optionButton(option)
                        }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.visible)
                .onChange(of: model.highlightedValue) { _, value in
                    guard let value else { return }
                    proxy.scrollTo(value, anchor: .center)
                }
            }
        }
        .frame(width: Layout.width)
        .frame(
            minHeight: Layout.minimumHeight,
            idealHeight: Layout.idealHeight,
            maxHeight: Layout.maximumHeight
        )
        .accessibilityLabel(model.accessibilityTitle)
        .onChange(of: model.query) {
            synchronizeHighlight()
        }
    }

    private func optionButton(
        _ option: WorkspaceDatabaseSchemaOptionPicker.Option
    ) -> some View {
        Button {
            select(option.value)
        } label: {
            HStack {
                Image(systemName: "checkmark")
                    .opacity(model.selectedValue == option.value ? 1 : 0)
                    .accessibilityHidden(true)

                Text(option.title)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer()
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .tag(option.value)
        .id(option.value)
        .listRowSeparator(.hidden)
        .help(option.title)
        .accessibilityAddTraits(
            model.selectedValue == option.value ? .isSelected : []
        )
    }

    private var filteredOptions: [WorkspaceDatabaseSchemaOptionPicker.Option] {
        let trimmedQuery = model.query.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !trimmedQuery.isEmpty else { return model.options }
        return model.options.filter {
            $0.title.localizedStandardContains(trimmedQuery)
                || $0.value.localizedStandardContains(trimmedQuery)
        }
    }

    private func selectHighlightedOption() {
        guard let highlightedValue = model.highlightedValue else { return }
        select(highlightedValue)
    }

    private func moveHighlight(by offset: Int) {
        let values = filteredOptions.map(\.value)
        guard !values.isEmpty else { return }
        let currentPosition = model.highlightedValue.flatMap {
            values.firstIndex(of: $0)
        }
        let proposedPosition: Int
        if let currentPosition {
            proposedPosition = currentPosition + offset
        } else {
            proposedPosition = offset < 0 ? values.count - 1 : 0
        }
        model.highlightedValue = values[
            min(max(proposedPosition, 0), values.count - 1)
        ]
    }

    private func synchronizeHighlight() {
        let values = filteredOptions.map(\.value)
        guard !values.isEmpty else {
            model.highlightedValue = nil
            return
        }
        if let highlightedValue = model.highlightedValue,
           values.contains(highlightedValue)
        {
            return
        }
        model.highlightedValue = values.first
    }
}
