import Foundation
import ScreenCaptureKit

/// Never include localizedDescription or NSError.userInfo in diagnostic logs:
/// both can contain system-localized text, even when the app uses English.
func logErrorDetails(_ error: Error) -> String {
    let error = error as NSError
    let identifier = "domain=\(error.domain), code=\(error.code)"
    if error.domain == SCStreamErrorDomain,
       error.code == SCStreamError.Code.userDeclined.rawValue {
        return "Screen recording permission denied by the user (TCC); \(identifier)"
    }
    return identifier
}
