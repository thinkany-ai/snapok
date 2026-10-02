import Foundation
import ScreenCaptureKit

@main
struct LogErrorTests {
    static func main() {
        let denied = NSError(
            domain: SCStreamErrorDomain,
            code: SCStreamError.Code.userDeclined.rawValue,
            userInfo: [NSLocalizedDescriptionKey: "用户拒绝了应用程序、窗口、显示器捕捉的TCC"]
        )
        precondition(logErrorDetails(denied) ==
            "Screen recording permission denied by the user (TCC); domain=\(SCStreamErrorDomain), code=-3801")

        let unknown = NSError(domain: "ExampleError", code: -3801, userInfo: [
            NSLocalizedDescriptionKey: "操作失败",
            NSUnderlyingErrorKey: denied,
        ])
        precondition(logErrorDetails(unknown) == "domain=ExampleError, code=-3801")
        print("Passed log error checks: English permission denial and locale-independent fallback")
    }
}
