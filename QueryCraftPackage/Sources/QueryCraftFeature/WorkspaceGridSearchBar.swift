import SwiftUI

struct WorkspaceGridSearchBar: View {
    @Bindable var controller: WorkspaceGridSearchController

    var body: some View {
        HStack(spacing: 8) {
            WorkspaceGridSearchColumnPicker(
                selectedDataColumnIndex:
                    $controller.selectedDataColumnIndex,
                columns: controller.columns
            )

            Menu(controller.searchOperator.title) {
                ForEach(WorkspaceGridSearchOperator.allCases) {
                    searchOperator in
                    Button {
                        controller.searchOperator = searchOperator
                    } label: {
                        if controller.searchOperator == searchOperator {
                            Label(
                                searchOperator.title,
                                systemImage: "checkmark"
                            )
                        } else {
                            Text(searchOperator.title)
                        }
                    }
                }
            }
            .fixedSize(horizontal: true, vertical: false)
            .help(AppCopy.current.text("匹配方式", "Match"))
            .accessibilityLabel(
                AppCopy.current.text("匹配方式", "Match")
            )
            .accessibilityValue(controller.searchOperator.title)

            WorkspaceGridSearchField(
                text: $controller.query,
                placeholder: AppCopy.current.text(
                    "在数据中查找",
                    "Find in Data"
                ),
                focusRequest: controller.focusRequest,
                submit: controller.selectNextMatch,
                cancel: controller.dismiss
            )
            .frame(maxWidth: .infinity)

            if !controller.query.isEmpty {
                ZStack(alignment: .trailing) {
                    Text(
                        "\(WorkspaceGridSearchWorker.maximumMatchCount) / "
                            + "\(WorkspaceGridSearchWorker.maximumMatchCount)+"
                    )
                    .hidden()

                    HStack {
                        if controller.isSearching {
                            ProgressView()
                                .controlSize(.small)
                        }

                        Text(controller.matchStatus)
                    }
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .lineLimit(1)
            }

            Toggle(
                AppCopy.current.text("区分大小写", "Match Case"),
                isOn: $controller.isCaseSensitive
            )
            .toggleStyle(.checkbox)
            .fixedSize()

            WorkspaceInlineIconButton(
                systemImageName: "chevron.up",
                title: AppCopy.current.text(
                    "上一个匹配项",
                    "Previous Match"
                ),
                isEnabled: !controller.matches.isEmpty,
                action: controller.selectPreviousMatch
            )

            WorkspaceInlineIconButton(
                systemImageName: "chevron.down",
                title: AppCopy.current.text(
                    "下一个匹配项",
                    "Next Match"
                ),
                isEnabled: !controller.matches.isEmpty,
                action: controller.selectNextMatch
            )

            Button(
                AppCopy.current.text("完成", "Done"),
                action: controller.dismiss
            )
            .buttonStyle(.bordered)
            .fixedSize(horizontal: true, vertical: false)
        }
        .padding()
        .background(.bar)
        .overlay(alignment: .bottom) {
            Divider()
        }
        .accessibilityIdentifier("gridSearchBar")
    }
}
