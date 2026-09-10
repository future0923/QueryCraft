import SwiftUI

struct WorkspaceDatabaseSchemaOptionPicker: View {
    struct Option: Equatable, Identifiable {
        let value: String
        let title: String

        var id: String { value }
    }

    @Binding var selection: String
    let options: [Option]
    let placeholder: String
    let accessibilityTitle: String
    let allowsCustomValue: Bool
    let usesMonospacedFont: Bool
    let isTextEditingEnabled: Bool
    let startsFocused: Bool
    let usesSearch: Bool
    let usesPlainMenuStyle: Bool
    let alignsSelectionTrailing: Bool
    let editingEnded: @MainActor () -> Void

    @State private var isPresented = false
    @State private var query = ""
    @State private var highlightedValue: String?
    @State private var focusRequest = 0
    @FocusState private var isInlineTextFieldFocused: Bool

    init(
        selection: Binding<String>,
        options: [Option],
        placeholder: String,
        accessibilityTitle: String,
        allowsCustomValue: Bool = false,
        usesMonospacedFont: Bool = false,
        isTextEditingEnabled: Bool = true,
        startsFocused: Bool = false,
        usesSearch: Bool = true,
        usesPlainMenuStyle: Bool = false,
        alignsSelectionTrailing: Bool = false,
        editingEnded: @escaping @MainActor () -> Void = {}
    ) {
        _selection = selection
        self.options = options
        self.placeholder = placeholder
        self.accessibilityTitle = accessibilityTitle
        self.allowsCustomValue = allowsCustomValue
        self.usesMonospacedFont = usesMonospacedFont
        self.isTextEditingEnabled = isTextEditingEnabled
        self.startsFocused = startsFocused
        self.usesSearch = usesSearch
        self.usesPlainMenuStyle = usesPlainMenuStyle
        self.alignsSelectionTrailing = alignsSelectionTrailing
        self.editingEnded = editingEnded
    }

    var body: some View {
        Group {
            if usesSearch {
                searchableControl
            } else {
                compactControl
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .help(accessibilityTitle)
        .accessibilityLabel(accessibilityTitle)
        .accessibilityValue(selectedTitle)
    }

    private var searchableControl: some View {
        Group {
            if allowsCustomValue {
                editableControl
            } else {
                selectionButton
            }
        }
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            pickerContent
        }
        .onChange(of: query) {
            synchronizeHighlight()
        }
        .onChange(of: selection) {
            guard isPresented else { return }
            synchronizeHighlight()
        }
        .onChange(of: isInlineTextFieldFocused) { _, isFocused in
            guard isTextEditingEnabled, !isFocused else { return }
            editingEnded()
        }
        .onChange(of: startsFocused) { _, shouldFocus in
            guard shouldFocus, !allowsCustomValue else { return }
            present()
        }
        .onChange(of: isPresented) { _, isPresented in
            guard !isPresented, startsFocused, !allowsCustomValue else {
                return
            }
            editingEnded()
        }
    }

    private var compactControl: some View {
        Group {
            if allowsCustomValue {
                HStack(spacing: 3) {
                    if isTextEditingEnabled {
                        TextField(placeholder, text: $selection)
                            .font(valueFont)
                            .textFieldStyle(.plain)
                            .frame(maxWidth: .infinity)
                            .focused($isInlineTextFieldFocused)
                            .onSubmit(editingEnded)
                            .onExitCommand(perform: editingEnded)
                    } else {
                        Text(selectedTitle)
                            .font(valueFont)
                            .foregroundStyle(
                                selection.isEmpty ? .tertiary : .primary
                            )
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    compactMenu(iconOnly: true)
                }
                .frame(maxWidth: .infinity)
            } else {
                compactMenu(iconOnly: false)
            }
        }
    }

    private func compactMenu(iconOnly: Bool) -> some View {
        Group {
            if usesPlainMenuStyle {
                Menu {
                    compactMenuItems
                } label: {
                    compactMenuLabel(iconOnly: iconOnly)
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
            } else {
                Menu {
                    compactMenuItems
                } label: {
                    compactMenuLabel(iconOnly: iconOnly)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
            }
        }
    }

    @ViewBuilder
    private var compactMenuItems: some View {
        ForEach(Array(resolvedOptions.enumerated()), id: \.element.id) {
            offset, option in
            if offset > 0, compactMenuNeedsSeparator(option.value) {
                Divider()
            }
            Button {
                selection = option.value
            } label: {
                if selection == option.value {
                    Label(option.title, systemImage: "checkmark")
                } else {
                    Text(option.title)
                }
            }
        }
    }

    @ViewBuilder
    private func compactMenuLabel(iconOnly: Bool) -> some View {
        if iconOnly {
            Image(systemName: "chevron.up.chevron.down")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .frame(width: 24, height: 22)
                .contentShape(.rect)
        } else {
            selectionLabel
        }
    }

    private var selectionLabel: some View {
        HStack(spacing: 4) {
            Text(selectedTitle)
                .font(valueFont)
                .foregroundStyle(selection.isEmpty ? .tertiary : .primary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(
                    maxWidth: .infinity,
                    alignment: alignsSelectionTrailing ? .trailing : .leading
                )

            Image(systemName: "chevron.up.chevron.down")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
        .contentShape(.rect)
    }

    private func compactMenuNeedsSeparator(_ value: String) -> Bool {
        value == WorkspaceDatabaseSchemaEditorState.DefaultPreset
            .currentTimestamp.rawValue
            || value == WorkspaceDatabaseSchemaEditorState.DefaultPreset
            .custom.rawValue
            || value == WorkspaceDatabaseSchemaEditorState.ExtraPreset.custom.rawValue
    }

    private var selectionButton: some View {
        Button(action: present) {
            selectionLabel
        }
        .buttonStyle(.plain)
    }

    private var editableControl: some View {
        HStack(spacing: 3) {
            if isTextEditingEnabled {
                TextField(placeholder, text: $selection)
                    .font(valueFont)
                    .textFieldStyle(.plain)
                    .frame(maxWidth: .infinity)
                    .focused($isInlineTextFieldFocused)
                    .onSubmit(editingEnded)
                    .onExitCommand(perform: editingEnded)
                    .onAppear {
                        guard startsFocused else { return }
                        isInlineTextFieldFocused = true
                    }
            } else {
                Text(selectedTitle)
                    .font(valueFont)
                    .foregroundStyle(selection.isEmpty ? .tertiary : .primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Button(
                AppCopy.current.text("显示候选项", "Show Suggestions"),
                systemImage: "chevron.up.chevron.down",
                action: present
            )
            .labelStyle(.iconOnly)
            .buttonStyle(.plain)
            .font(.caption)
            .foregroundStyle(.tertiary)
            .frame(width: 24, height: 22)
            .contentShape(.rect)
        }
        .frame(maxWidth: .infinity)
        .contentShape(.rect)
    }

    private var valueFont: Font {
        usesMonospacedFont
            ? .system(.body, design: .monospaced)
            : .body
    }

    private var pickerContent: some View {
        VStack(spacing: 0) {
            WorkspaceGridSearchField(
                text: $query,
                placeholder: allowsCustomValue
                    ? AppCopy.current.text(
                        "搜索或输入值…",
                        "Search or enter a value..."
                    )
                    : AppCopy.current.text(
                        "搜索选项…",
                        "Search options..."
                    ),
                focusRequest: focusRequest,
                submit: submit,
                cancel: dismiss,
                accessibilityIdentifier: "databaseSchemaOptionSearchField",
                moveUp: { moveHighlight(by: -1) },
                moveDown: { moveHighlight(by: 1) }
            )
            .padding(8)

            Divider()

            List(selection: $highlightedValue) {
                if filteredOptions.isEmpty {
                    Text(
                        allowsCustomValue && !trimmedQuery.isEmpty
                            ? AppCopy.current.text(
                                "按回车使用输入值",
                                "Press Return to use this value"
                            )
                            : AppCopy.current.text(
                                "没有匹配的选项",
                                "No matching options"
                            )
                    )
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .listRowSeparator(.hidden)
                } else {
                    ForEach(filteredOptions) { option in
                        Button {
                            select(option.value)
                        } label: {
                            HStack {
                                Image(systemName: "checkmark")
                                    .opacity(selection == option.value ? 1 : 0)
                                    .accessibilityHidden(true)

                                Text(option.title)
                                    .font(
                                        usesMonospacedFont
                                            ? .system(.body, design: .monospaced)
                                            : .body
                                    )
                                    .lineLimit(1)
                                    .truncationMode(.tail)

                                Spacer()
                            }
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .tag(option.value)
                        .listRowSeparator(.hidden)
                        .help(option.title)
                        .accessibilityAddTraits(
                            selection == option.value ? .isSelected : []
                        )
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.visible)
        }
        .frame(width: 260, height: 300)
        .onDisappear {
            query = ""
            highlightedValue = nil
        }
    }

    private var selectedTitle: String {
        resolvedOptions.first { $0.value == selection }?.title
            ?? (selection.isEmpty ? placeholder : selection)
    }

    private var resolvedOptions: [Option] {
        var seen = Set<String>()
        var result = options.filter { seen.insert($0.value).inserted }
        if !selection.isEmpty,
           !result.contains(where: { $0.value == selection })
        {
            result.insert(Option(value: selection, title: selection), at: 0)
        }
        return result
    }

    private var filteredOptions: [Option] {
        guard !trimmedQuery.isEmpty else { return resolvedOptions }
        return resolvedOptions.filter {
            $0.title.localizedStandardContains(trimmedQuery)
                || $0.value.localizedStandardContains(trimmedQuery)
        }
    }

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func present() {
        query = ""
        highlightedValue = selection.isEmpty
            ? resolvedOptions.first?.value
            : selection
        focusRequest &+= 1
        isPresented = true
    }

    private func dismiss() {
        isPresented = false
    }

    private func submit() {
        if allowsCustomValue, !trimmedQuery.isEmpty {
            if let exactMatch = resolvedOptions.first(where: {
                $0.title.caseInsensitiveCompare(trimmedQuery) == .orderedSame
                    || $0.value.caseInsensitiveCompare(trimmedQuery) == .orderedSame
            }) {
                select(exactMatch.value)
            } else {
                select(trimmedQuery)
            }
            return
        }
        guard let highlightedValue else { return }
        select(highlightedValue)
    }

    private func select(_ value: String) {
        selection = value
        dismiss()
    }

    private func moveHighlight(by offset: Int) {
        let values = filteredOptions.map(\.value)
        guard !values.isEmpty else { return }
        let current = highlightedValue.flatMap(values.firstIndex(of:))
        let proposed = current.map { $0 + offset }
            ?? (offset < 0 ? values.count - 1 : 0)
        highlightedValue = values[min(max(proposed, 0), values.count - 1)]
    }

    private func synchronizeHighlight() {
        let values = filteredOptions.map(\.value)
        guard !values.isEmpty else {
            highlightedValue = nil
            return
        }
        if let highlightedValue, values.contains(highlightedValue) {
            return
        }
        highlightedValue = values.first
    }
}
