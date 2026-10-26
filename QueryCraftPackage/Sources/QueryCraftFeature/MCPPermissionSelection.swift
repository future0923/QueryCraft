import Foundation

/// Presentation of explicit access and inherited defaults; connection grants are independent.
enum MCPPermissionSelection: String, CaseIterable, Identifiable {
    case denied, inherited, readOnly, dataWrite, fullAccess, custom

    var id: String { rawValue }
    var mode: MCPExecutionMode? {
        switch self {
        case .readOnly: .readOnly
        case .dataWrite: .dataWrite
        case .fullAccess: .fullAccess
        default: nil
        }
    }
    init(_ mode: MCPExecutionMode) {
        self = switch mode {
        case .readOnly: .readOnly
        case .dataWrite: .dataWrite
        case .fullAccess: .fullAccess
        }
    }
    var title: String {
        let copy = AppCopy.current
        return switch self {
        case .denied: copy.text("禁止访问", "No access")
        case .inherited: copy.text("使用默认权限", "Use default access")
        case .custom: copy.text("逐个连接设置", "Individual connections")
        default: mode?.title ?? ""
        }
    }
    static var accessChoices: [Self] { [.denied, .readOnly, .dataWrite, .fullAccess] }
}
