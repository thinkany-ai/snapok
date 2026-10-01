import AppKit
import ApplicationServices

@main
struct FocusGeometryTests {
    @MainActor static func main() async {
        testCoordinatesOnPrimaryAndOffsetDisplays()
        testPartiallyClippedComponentUsesVisibleWindowBounds()
        testRejectsOffCursorTinyAndInvalidComponents()
        testDockRegions()
        testSystemContainers()
        testReservedDockArea()
        print("Passed 6 focus geometry checks")
        if CommandLine.arguments.contains("--live") {
            let targets = await WindowDetector.visibleWindowFrames()
            let systems = targets.filter(\.isSystemUI)
            precondition(!systems.isEmpty, "Expected visible system UI targets")
            let dockPID = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first?.processIdentifier
            for target in systems {
                let point = CGPoint(x: target.frame.midX, y: target.frame.midY)
                let components = await FocusDetector.shared.regions(in: target, at: point, primaryHeight: NSScreen.screens.first!.frame.height)
                precondition(components.allSatisfy { target.selectionFrame.contains($0) && $0.contains(point) })
                print("System target: \(target.pid == dockPID ? "Dock" : "menu/status") \(target.frame), components: \(components.count)")
            }
            if AXIsProcessTrusted() {
                precondition(systems.contains(where: { $0.pid == dockPID }), "Expected visible Dock from AX")
            }
        }
    }

    static func testReservedDockArea() {
        let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
        // Bottom Dock: visibleFrame starts above the Dock and stops below the menu bar.
        expectEqual(FocusGeometry.reservedDockArea(screen: screen, visible: CGRect(x: 0, y: 90, width: 1512, height: 859)),
                    CGRect(x: 0, y: 0, width: 1512, height: 90))
        expectEqual(FocusGeometry.reservedDockArea(screen: screen, visible: CGRect(x: 80, y: 0, width: 1432, height: 949)),
                    CGRect(x: 0, y: 0, width: 80, height: 949))
        expectEqual(FocusGeometry.reservedDockArea(screen: screen, visible: CGRect(x: 0, y: 0, width: 1430, height: 949)),
                    CGRect(x: 1430, y: 0, width: 82, height: 949))
        // Auto-hidden Dock reserves a few points only; a display without a Dock reserves nothing.
        expectNil(FocusGeometry.reservedDockArea(screen: screen, visible: CGRect(x: 0, y: 4, width: 1512, height: 945)))
        expectNil(FocusGeometry.reservedDockArea(screen: screen, visible: CGRect(x: 0, y: 0, width: 1512, height: 949)))
        // The reserved strip passes the Dock region filter that rejects full-display surfaces.
        precondition(FocusGeometry.dockRegion(CGRect(x: 0, y: 0, width: 1512, height: 90), on: screen) != nil)
    }

    static func testDockRegions() {
        let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
        expectEqual(FocusGeometry.dockRegion(CGRect(x: 271, y: 10, width: 970, height: 80), on: screen),
                    CGRect(x: 263, y: 2, width: 986, height: 96))
        expectNil(FocusGeometry.dockRegion(screen, on: screen))
        expectNil(FocusGeometry.dockRegion(CGRect(x: 270, y: -79, width: 970, height: 80), on: screen))
        let leftScreen = CGRect(x: -1200, y: 200, width: 1200, height: 900)
        expectEqual(FocusGeometry.dockRegion(CGRect(x: -1200, y: 350, width: 70, height: 500), on: leftScreen),
                    CGRect(x: -1200, y: 342, width: 78, height: 516))
    }

    static func testSystemContainers() {
        let bar = CGRect(x: 0, y: 949, width: 1512, height: 33)
        let status = CGRect(x: 1300, y: 949, width: 32, height: 33)
        let target = WindowTarget(frame: status, pid: 1, isSystemUI: true, containerFrame: bar)
        expectEqual(target.selectionFrame, bar)
        expectEqual(FocusGeometry.candidate(status, in: bar, at: CGPoint(x: 1310, y: 960)), status)
        expectEqual(WindowTarget(frame: status, pid: 1).selectionFrame, status)
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
