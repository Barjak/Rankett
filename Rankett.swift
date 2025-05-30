import SwiftUI

@main
struct SpectrumAnalyzerApp: App {
        var body: some Scene {
                WindowGroup {
                        ContentView()
                                .preferredColorScheme(.dark)
                                .environment(\.layoutParameters, layoutParameters)
                }
        }
        
        // Customize layout parameters based on device
        private var layoutParameters: LayoutParameters {
                var params = LayoutParameters()
                
#if os(iOS)
                if UIDevice.current.userInterfaceIdiom == .pad {
                        params.maxPanelHeight = 400  // Limit panel height on iPad
                }
#endif
                
                return params
        }
}
