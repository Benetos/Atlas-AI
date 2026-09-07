import Foundation
import SwiftUI

@main
struct AtlasApp: App {
    @State private var model = AppModel()
    @State private var router = AtlasRouter()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .environment(router)
                .task {
                    await model.bootstrap()
                }
        }
    }
}
