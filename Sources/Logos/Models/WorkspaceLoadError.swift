import Foundation

/// A user-facing classification of why a workspace load failed. Surfaced via
/// `WorkspaceModel.lastError` and rendered as a banner (Issue #9). Maps the
/// internal `WorkspaceLoader.LoaderError` (and any other thrown error) to a
/// readable message and a `isStale` flag that decides whether the persisted
/// path should be cleared.
public enum WorkspaceLoadError: Equatable, Sendable {
    /// Path no longer exists (deleted / moved).
    case notFound
    /// Persisted path resolved to a file, not a directory.
    case notADirectory
    /// Loader refused a system path (e.g. a persisted `/`).
    case refused
    /// Directory exceeded the file-count cap.
    case tooLarge(found: Int, cap: Int)
    /// Permission denied / I/O error / anything else.
    case unknown

    public init(from error: Error) {
        if let loaderError = error as? WorkspaceLoader.LoaderError {
            switch loaderError {
            case .notFound:            self = .notFound
            case .refusedSystemPath:   self = .refused
            case .tooManyFiles(let f, let c): self = .tooLarge(found: f, cap: c)
            }
        } else {
            self = .unknown
        }
    }

    public var message: String {
        switch self {
        case .notFound:
            return "That workspace no longer exists. It may have been moved or deleted."
        case .notADirectory:
            return "That path is a file, not a folder. Pick a folder to open as a workspace."
        case .refused:
            return "That location can't be opened as a workspace (system folder)."
        case .tooLarge(let found, let cap):
            return "That folder is too large to open (\(found)+ files, limit \(cap)). Pick a more specific subfolder."
        case .unknown:
            return "Couldn't open that workspace. Check that it's readable and try again."
        }
    }

    /// Whether this error means the persisted path is permanently bad and
    /// should be cleared (vs a transient condition worth retrying). Transient
    /// errors (`.unknown` — permission/IO) keep the persisted path so a brief
    /// outage doesn't discard a valid workspace (Issue #9 D4).
    public var isStale: Bool {
        switch self {
        case .notFound, .notADirectory, .refused: return true
        case .tooLarge, .unknown:                  return false
        }
    }
}
