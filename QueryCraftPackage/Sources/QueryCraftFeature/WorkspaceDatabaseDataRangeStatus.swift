import SwiftUI

struct WorkspaceDatabaseDataRangeStatus: View {
    let page: WorkspaceDatabaseDataPage?
    let countState: WorkspaceDatabaseDataCountState
    let isFetching: Bool
    let isStopped: Bool

    var body: some View {
        HStack(spacing: 6) {
            if let rangeText {
                Text(rangeText)
                    .monospacedDigit()
            }

            if isFetching {
                ProgressView()
                    .controlSize(.mini)
                Text(AppCopy.current.text("正在获取…", "Fetching..."))
            } else if countState == .loading {
                ProgressView()
                    .controlSize(.mini)
                Text(AppCopy.current.text("正在加载数据行…", "Loading rows..."))
            } else if isStopped {
                Label(AppCopy.current.text("已停止", "Stopped"), systemImage: "stop.fill")
            }
        }
        .font(.callout)
    }

    private var rangeText: String? {
        guard let page else { return nil }
        guard
            let firstRowNumber = page.firstRowNumber,
            let lastRowNumber = page.lastRowNumber
        else {
            if case let .loaded(count) = countState {
                return count == 0
                    ? AppCopy.current.text("0 行", "0 rows")
                    : AppCopy.current.text(
                        "共 \(count.formatted()) 行，当前 0 行",
                        "0 of \(count.formatted()) rows"
                    )
            }
            return AppCopy.current.text("0 行", "0 rows")
        }

        let range = "\(firstRowNumber)-\(lastRowNumber)"
        if case let .loaded(count) = countState {
            return AppCopy.current.text(
                "\(range)，共 \(count.formatted()) 行",
                "\(range) of \(count.formatted()) rows"
            )
        }
        return AppCopy.current.text("\(range) 行", "\(range) rows")
    }
}
