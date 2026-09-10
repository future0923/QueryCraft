extension ConnectionTLSMode {
    var title: String {
        switch self {
        case .disabled: AppCopy.current.text("关闭", "Disabled")
        case .required: AppCopy.current.text("必需", "Required")
        case .verifyCA: AppCopy.current.text("验证 CA", "Verify CA")
        case .verifyIdentity: AppCopy.current.text("验证身份", "Verify Identity")
        }
    }
}
