import SwiftUI

struct RedisCollectionRemoteSearchBar: View {
    let keyType: RedisKeyType
    @Bindable var state: RedisCollectionRemoteSearchState
    let isEnabled: Bool

    var body: some View {
        HStack(spacing: 8) {
            Group {
                Menu(fieldTitle(state.field)) {
                    ForEach(
                        state.availableFields(for: keyType),
                        id: \.self
                    ) { field in
                        Button {
                            state.field = field
                        } label: {
                            if state.field == field {
                                Label(
                                    fieldTitle(field),
                                    systemImage: "checkmark"
                                )
                            } else {
                                Text(fieldTitle(field))
                            }
                        }
                    }
                }
                .fixedSize(horizontal: true, vertical: false)
                .help(AppCopy.current.text("搜索范围", "Search Field"))

                Menu(matchModeTitle(state.mode)) {
                    ForEach(matchModes, id: \.self) { mode in
                        Button {
                            state.mode = mode
                        } label: {
                            if state.mode == mode {
                                Label(
                                    matchModeTitle(mode),
                                    systemImage: "checkmark"
                                )
                            } else {
                                Text(matchModeTitle(mode))
                            }
                        }
                    }
                }
                .fixedSize(horizontal: true, vertical: false)
                .help(AppCopy.current.text("匹配方式", "Match"))

                WorkspaceGridSearchField(
                    text: $state.draftText,
                    placeholder: AppCopy.current.text(
                        "在整个 Key 中查找，按 Return 搜索",
                        "Find in Entire Key, press Return"
                    ),
                    focusRequest: state.focusRequest,
                    submit: state.submit,
                    cancel: state.dismiss,
                    accessibilityIdentifier: "redisCollectionRemoteSearchField"
                )
                .frame(maxWidth: .infinity)

                Toggle(
                    AppCopy.current.text("区分大小写", "Match Case"),
                    isOn: $state.isCaseSensitive
                )
                .toggleStyle(.checkbox)
                .fixedSize()

                if state.submittedSearch != nil || !state.draftText.isEmpty {
                    WorkspaceInlineIconButton(
                        systemImageName: "xmark",
                        title: AppCopy.current.text("清除搜索", "Clear Search"),
                        isEnabled: isEnabled,
                        action: state.clear
                    )
                }
            }
            .disabled(!isEnabled)

            Button(
                AppCopy.current.text("完成", "Done"),
                action: state.dismiss
            )
            .buttonStyle(.bordered)
            .fixedSize(horizontal: true, vertical: false)
        }
        .padding()
        .background(.bar)
        .overlay(alignment: .bottom) {
            Divider()
        }
        .accessibilityIdentifier("redisCollectionRemoteSearchBar")
    }

    private var matchModes: [RedisCollectionMatchMode] {
        [.contains, .prefix, .exact]
    }

    private func fieldTitle(
        _ field: RedisCollectionSearchField
    ) -> String {
        switch field {
        case .all: AppCopy.current.text("全部", "All")
        case .value: AppCopy.current.text("值", "Value")
        case .field: AppCopy.current.text("字段", "Field")
        case .member: AppCopy.current.text("成员", "Member")
        case .score: AppCopy.current.text("分数", "Score")
        }
    }

    private func matchModeTitle(
        _ mode: RedisCollectionMatchMode
    ) -> String {
        switch mode {
        case .contains: AppCopy.current.text("包含", "Contains")
        case .prefix: AppCopy.current.text("前缀", "Prefix")
        case .exact: AppCopy.current.text("精确", "Exact")
        }
    }
}
