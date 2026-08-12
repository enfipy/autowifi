import SwiftUI

@main
struct AutowifiApp: App {
    @StateObject private var model = AccessorySessionModel()

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
        }
    }
}
