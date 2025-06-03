import SwiftUI

struct LayoutParameters {
        var studyHeightFraction: CGFloat = 0.4  // Default to 85%
        var minStudyHeightFraction: CGFloat = 0.25  // Minimum 25%
        var maxPanelHeight: CGFloat? = nil
}

private struct LayoutParametersKey: EnvironmentKey {
        static let defaultValue: LayoutParameters = LayoutParameters()
}

extension EnvironmentValues {
        var layoutParameters: LayoutParameters {
                get { self[LayoutParametersKey.self] }
                set { self[LayoutParametersKey.self] = newValue }
        }
}

@main
struct SpectrumAnalyzerApp: App {
        var body: some Scene {
                WindowGroup {
                        ContentView()
                                .preferredColorScheme(.dark)
                                .environment(\.layoutParameters, layoutParameters)  // Use the computed property
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
