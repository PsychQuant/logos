import SwiftUI

struct MainScene: Scene {

    @State private var layout = WindowLayoutState()
    @State private var activityBar = ActivityBarSelection()
    @State private var statusBar = StatusBarViewModel()

    var body: some Scene {
        WindowGroup("Logos") {
            MainView()
                .environment(layout)
                .environment(activityBar)
                .environment(statusBar)
                .frame(
                    minWidth: 900,
                    idealWidth: 1400,
                    minHeight: 600,
                    idealHeight: 900
                )
        }
        .windowResizability(.contentSize)
    }
}
