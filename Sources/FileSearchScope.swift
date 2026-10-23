import Foundation

/// The filesystem scope used by the Files and Find right-sidebar tools.
enum FileSearchScope: Equatable, Sendable {
    case unsupported
    case local

    /// Derives the search scope from the active file provider.
    init(provider: FileExplorerProvider?) {
        if provider is LocalFileExplorerProvider {
            self = .local
        } else {
            self = .unsupported
        }
    }

    var debugName: String {
        switch self {
        case .unsupported: return "unsupported"
        case .local: return "local"
        }
    }

}
