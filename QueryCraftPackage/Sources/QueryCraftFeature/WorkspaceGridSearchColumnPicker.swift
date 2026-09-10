import AppKit
import Foundation
import SwiftUI

struct WorkspaceGridSearchColumnPicker: View {
    @Binding var selectedDataColumnIndex: Int?
    let columns: [WorkspaceDatabaseDataColumn]
    let includesAllColumns: Bool
    let accessibilityTitle: String
    let triggerWidth: CGFloat?
    let expandsTrigger: Bool
    let presentationRequest: Int
    let dismissalRequest: Int
    let presentationChanged: @MainActor @Sendable (Bool) -> Void

    @State private var isPresented = false
    @State private var query = ""
    @State private var highlightedOption: Int?
    @State private var focusRequest = 0
    @State private var pickerWidth = Layout.defaultWidth
    @State private var dragStartWidth: CGFloat?

    private static let allColumnsOption = -1

    init(
        selectedDataColumnIndex: Binding<Int?>,
        columns: [WorkspaceDatabaseDataColumn],
        includesAllColumns: Bool = true,
        accessibilityTitle: String? = nil,
        triggerWidth: CGFloat? = nil,
        expandsTrigger: Bool = false,
        presentationRequest: Int = 0,
        dismissalRequest: Int = 0,
        presentationChanged: @escaping @MainActor @Sendable (Bool) -> Void = {
            _ in
        }
    ) {
        _selectedDataColumnIndex = selectedDataColumnIndex
        self.columns = columns
        self.includesAllColumns = includesAllColumns
        self.accessibilityTitle = accessibilityTitle
            ?? AppCopy.current.text("搜索列", "Search Column")
        self.triggerWidth = triggerWidth
        self.expandsTrigger = expandsTrigger
        self.presentationRequest = presentationRequest
        self.dismissalRequest = dismissalRequest
        self.presentationChanged = presentationChanged
    }

    private enum Layout {
        static let defaultWidth: CGFloat = 220
        static let minimumWidth: CGFloat = 180
        static let maximumWidth: CGFloat = 480
        static let resizeHandleWidth: CGFloat = 8
        static let minimumHeight: CGFloat = 240
        static let idealHeight: CGFloat = 320
        static let maximumHeight: CGFloat = 420
    }

    var body: some View {
        Button(action: present) {
            HStack {
                Text(selectedColumnTitle)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: 4)

                Image(systemName: "chevron.down")
                    .imageScale(.small)
            }
        }
        .buttonStyle(.bordered)
        .frame(width: triggerWidth)
        .fixedSize(
            horizontal: triggerWidth == nil && !expandsTrigger,
            vertical: false
        )
        .frame(maxWidth: expandsTrigger ? .infinity : nil)
        .help(accessibilityTitle)
        .accessibilityLabel(accessibilityTitle)
        .accessibilityValue(selectedColumnTitle)
        .accessibilityIdentifier("gridSearchColumnPicker")
        .popover(
            isPresented: $isPresented,
            arrowEdge: .bottom
        ) {
            pickerContent
        }
        .onChange(of: presentationRequest) {
            present()
        }
        .onChange(of: dismissalRequest) {
            dismiss()
        }
        .onChange(of: isPresented) { _, isPresented in
            presentationChanged(isPresented)
        }
    }

    private var pickerContent: some View {
        VStack(spacing: 0) {
            WorkspaceGridSearchField(
                text: $query,
                placeholder: AppCopy.current.text(
                    "搜索字段",
                    "Search Columns"
                ),
                focusRequest: focusRequest,
                submit: selectHighlightedOption,
                cancel: dismiss,
                accessibilityIdentifier: "gridSearchColumnField",
                moveUp: { moveHighlight(by: -1) },
                moveDown: { moveHighlight(by: 1) }
            )
            .padding()

            ScrollViewReader { proxy in
                List(selection: $highlightedOption) {
                    if includesAllColumns {
                        optionButton(
                            title: AppCopy.current.text(
                                "所有列",
                                "All Columns"
                            ),
                            option: Self.allColumnsOption,
                            isSelected: selectedDataColumnIndex == nil
                        )
                    }

                    if filteredColumnIndices.isEmpty {
                        Text(
                            AppCopy.current.text(
                                "没有匹配的字段",
                                "No Matching Columns"
                            )
                        )
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .listRowSeparator(.hidden)
                        .accessibilityIdentifier(
                            "gridSearchColumnNoMatches"
                        )
                    } else {
                        ForEach(
                            filteredColumnIndices,
                            id: \.self
                        ) { columnIndex in
                            optionButton(
                                title: columns[columnIndex].name,
                                option: columnIndex,
                                isSelected:
                                    selectedDataColumnIndex == columnIndex
                            )
                        }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.visible)
                .onChange(of: highlightedOption) { _, option in
                    guard let option else { return }
                    withAnimation {
                        proxy.scrollTo(option, anchor: .center)
                    }
                }
            }
        }
        .frame(width: pickerWidth)
        .frame(
            minHeight: Layout.minimumHeight,
            idealHeight: Layout.idealHeight,
            maxHeight: Layout.maximumHeight
        )
        .overlay(alignment: .trailing) {
            Color.clear
                .frame(width: Layout.resizeHandleWidth)
                .contentShape(.rect)
                .onContinuousHover { phase in
                    switch phase {
                    case .active:
                        NSCursor.resizeLeftRight.set()
                    case .ended:
                        NSCursor.arrow.set()
                    }
                }
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged(resizePicker)
                        .onEnded { _ in
                            dragStartWidth = nil
                        }
                )
                .help(
                    AppCopy.current.text(
                        "拖动调整宽度",
                        "Drag to Resize"
                    )
                )
                .accessibilityHidden(true)
        }
        .onChange(of: query) {
            synchronizeHighlightWithQuery()
        }
        .onChange(of: columns) {
            synchronizeHighlightWithQuery()
        }
        .onDisappear {
            query = ""
            highlightedOption = nil
            dragStartWidth = nil
            NSCursor.arrow.set()
        }
    }

    private func optionButton(
        title: String,
        option: Int,
        isSelected: Bool
    ) -> some View {
        Button {
            select(option)
        } label: {
            HStack {
                Image(systemName: "checkmark")
                    .opacity(isSelected ? 1 : 0)
                    .accessibilityHidden(true)

                Text(title)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer()
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .tag(option)
        .id(option)
        .listRowSeparator(.hidden)
        .help(title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var selectedColumnTitle: String {
        guard
            let selectedDataColumnIndex,
            columns.indices.contains(selectedDataColumnIndex)
        else {
            return includesAllColumns
                ? AppCopy.current.text("所有列", "All Columns")
                : AppCopy.current.text("选择列", "Select Column")
        }
        return columns[selectedDataColumnIndex].name
    }

    private var filteredColumnIndices: [Int] {
        Self.filteredColumnIndices(
            in: columns,
            matching: query
        )
    }

    private var visibleOptions: [Int] {
        includesAllColumns
            ? [Self.allColumnsOption] + filteredColumnIndices
            : filteredColumnIndices
    }

    private func present() {
        query = ""
        highlightedOption = selectedDataColumnIndex
            ?? (includesAllColumns ? Self.allColumnsOption : filteredColumnIndices.first)
        focusRequest &+= 1
        isPresented = true
    }

    private func dismiss() {
        isPresented = false
    }

    private func selectHighlightedOption() {
        guard let highlightedOption else { return }
        select(highlightedOption)
    }

    private func select(_ option: Int) {
        if includesAllColumns, option == Self.allColumnsOption {
            selectedDataColumnIndex = nil
        } else if columns.indices.contains(option) {
            selectedDataColumnIndex = option
        } else {
            return
        }
        dismiss()
    }

    private func moveHighlight(by offset: Int) {
        let options = visibleOptions
        guard !options.isEmpty else { return }

        let currentPosition = highlightedOption.flatMap {
            options.firstIndex(of: $0)
        }
        let proposedPosition: Int
        if let currentPosition {
            proposedPosition = currentPosition + offset
        } else {
            proposedPosition = offset < 0 ? options.count - 1 : 0
        }
        highlightedOption = options[
            min(max(proposedPosition, 0), options.count - 1)
        ]
    }

    private func synchronizeHighlightWithQuery() {
        let matches = filteredColumnIndices
        let trimmedQuery = query.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !trimmedQuery.isEmpty else {
            highlightedOption = selectedDataColumnIndex
                ?? Self.allColumnsOption
            return
        }
        guard
            let highlightedOption,
            matches.contains(highlightedOption)
        else {
            self.highlightedOption = matches.first
            return
        }
    }

    private func resizePicker(_ value: DragGesture.Value) {
        let startingWidth = dragStartWidth ?? pickerWidth
        dragStartWidth = startingWidth
        pickerWidth = Self.resizedWidth(
            startingWidth: startingWidth,
            translation: value.translation.width
        )
    }

    static func resizedWidth(
        startingWidth: CGFloat,
        translation: CGFloat
    ) -> CGFloat {
        min(
            max(
                startingWidth + translation,
                Layout.minimumWidth
            ),
            Layout.maximumWidth
        )
    }

    static func filteredColumnIndices(
        in columns: [WorkspaceDatabaseDataColumn],
        matching query: String
    ) -> [Int] {
        let normalizedQuery = query.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !normalizedQuery.isEmpty else {
            return Array(columns.indices)
        }
        return columns.indices.filter {
            columns[$0].name.localizedStandardContains(normalizedQuery)
        }
    }
}
