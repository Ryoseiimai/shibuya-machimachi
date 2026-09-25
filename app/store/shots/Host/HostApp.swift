import SwiftUI

// UIテストの実行に必要なだけの空のホストアプリ(撮影対象は本体アプリで、bundle IDで起動する)
@main
struct HostApp: App {
    var body: some Scene {
        WindowGroup { Text("Shots host") }
    }
}
