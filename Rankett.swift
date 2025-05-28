import SwiftUI

@main
struct SpectrumAnalyzerApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .preferredColorScheme(.dark)  // Looks better for spectrum analyzer
        }
    }
}
