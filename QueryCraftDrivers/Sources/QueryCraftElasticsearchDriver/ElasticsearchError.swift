import Foundation
import QueryCraftFeature

enum ElasticsearchError: LocalizedError, Equatable {
    case invalidEndpoint
    case invalidRelativePath
    case unsupportedProduct
    case unsupportedVersion(String)
    case unauthorized
    case forbidden
    case rateLimited
    case certificateValidationFailed
    case timedOut
    case network(String)
    case responseTooLarge(Int)
    case invalidResponse
    case server(status: Int, message: String)
    case unsupportedRequest(String)
    case mappingConflict(String)
    case deepPageUnavailable
    case pitExpired

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint:
            AppCopy.current.text("Elasticsearch 地址无效。", "The Elasticsearch endpoint is invalid.")
        case .invalidRelativePath:
            AppCopy.current.text("请求只能使用以 / 开头的相对路径。", "Requests must use a relative path beginning with /.")
        case .unsupportedProduct:
            AppCopy.current.text("目标服务不是受支持的 Elasticsearch。", "The target service is not a supported Elasticsearch server.")
        case .unsupportedVersion(let version):
            AppCopy.current.text("需要 Elasticsearch 7.10 或更高版本，当前为 \(version)。", "Elasticsearch 7.10 or later is required; the server is \(version).")
        case .unauthorized:
            AppCopy.current.text("Elasticsearch 认证失败，请检查凭据。", "Elasticsearch authentication failed. Check the credentials.")
        case .forbidden:
            AppCopy.current.text("当前凭据没有执行此请求的权限。", "The current credentials do not have permission for this request.")
        case .rateLimited:
            AppCopy.current.text("Elasticsearch 请求过多，请稍后重试。", "Elasticsearch is rate limiting requests. Try again later.")
        case .certificateValidationFailed:
            AppCopy.current.text(
                "无法验证 Elasticsearch 的 TLS 证书。",
                "The Elasticsearch TLS certificate could not be verified."
            )
        case .timedOut:
            AppCopy.current.text(
                "连接 Elasticsearch 超时。",
                "The Elasticsearch connection timed out."
            )
        case .network(let message):
            AppCopy.current.text(
                "无法连接 Elasticsearch：\(message)",
                "Unable to connect to Elasticsearch: \(message)"
            )
        case .responseTooLarge(let limit):
            AppCopy.current.text("响应超过 \(limit) 字节上限。", "The response exceeds the \(limit)-byte limit.")
        case .invalidResponse:
            AppCopy.current.text("Elasticsearch 返回了无法识别的响应。", "Elasticsearch returned an unrecognized response.")
        case .server(_, let message):
            message
        case .unsupportedRequest(let request):
            AppCopy.current.text("只读控制台拒绝请求：\(request)", "The read-only console rejected the request: \(request)")
        case .mappingConflict(let field):
            AppCopy.current.text("字段 \(field) 存在 Mapping 类型冲突，无法排序或筛选。", "Field \(field) has conflicting mapping types and cannot be sorted or filtered.")
        case .deepPageUnavailable:
            AppCopy.current.text("超过 10,000 条后只能进入已顺序访问过的页面，请先逐页进入。", "Beyond 10,000 rows, only pages already visited sequentially can be opened. Visit the pages in order first.")
        case .pitExpired:
            AppCopy.current.text(
                "Elasticsearch 分页上下文已过期，请重试。",
                "The Elasticsearch paging context expired. Try again."
            )
        }
    }

    static func from(_ error: URLError) -> Self {
        switch error.code {
        case .serverCertificateUntrusted,
             .serverCertificateHasBadDate,
             .serverCertificateHasUnknownRoot,
             .serverCertificateNotYetValid,
             .clientCertificateRejected,
             .clientCertificateRequired,
             .secureConnectionFailed:
            .certificateValidationFailed
        case .timedOut:
            .timedOut
        default:
            .network(error.localizedDescription)
        }
    }
}
