import AppKit

@main
struct FocusGeometryTests {
    static func main() {
        testCoordinatesOnPrimaryAndOffsetDisplays()
        testPartiallyClippedComponentUsesVisibleWindowBounds()
        testRejectsOffCursorTinyAndInvalidComponents()
        print("Passed 3 focus geometry checks")
    }

    static func expectEqual<T: Equatable>(_ actual: T, _ expected: T) {
        precondition(actual == expected, "Unexpected geometry: \(actual), expected \(expected)")
    }

    static func expectNil<T>(_ actual: T?) {
        precondition(actual == nil, "Expected rejected component")
    }
    static func testCoordinatesOnPrimaryAndOffsetDisplays() {
        expectEqual(FocusGeometry.cocoaRect(CGRect(x: 100, y: 80, width: 600, height: 400), primaryHeight: 900),
                       CGRect(x: 100, y: 420, width: 600, height: 400))
        // A monitor to the left and above the primary display has negative AX coordinates.
        expectEqual(FocusGeometry.cocoaRect(CGRect(x: -1400, y: -600, width: 400, height: 200), primaryHeight: 900),
                       CGRect(x: -1400, y: 1300, width: 400, height: 200))
    }

    static func testPartiallyClippedComponentUsesVisibleWindowBounds() {
        let window = CGRect(x: 100, y: 100, width: 600, height: 400)
        expectEqual(FocusGeometry.candidate(CGRect(x: 50, y: 50, width: 200, height: 200), in: window,
                                               at: CGPoint(x: 120, y: 120)),
                       CGRect(x: 100, y: 100, width: 150, height: 150))
    }

    static func testRejectsOffCursorTinyAndInvalidComponents() {
        let window = CGRect(x: 0, y: 0, width: 800, height: 600)
        let cursor = CGPoint(x: 100, y: 100)
        expectNil(FocusGeometry.candidate(CGRect(x: 300, y: 300, width: 100, height: 100), in: window, at: cursor))
        expectNil(FocusGeometry.candidate(CGRect(x: 95, y: 95, width: 10, height: 10), in: window, at: cursor))
        expectNil(FocusGeometry.candidate(CGRect(x: CGFloat.infinity, y: 0, width: 100, height: 100), in: window, at: cursor))
    }
}
