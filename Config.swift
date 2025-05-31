import Foundation
import SwiftUI
enum NoiseFloorMethod {
        case quantileRegression
}

struct AnalyzerConfig {
        
        // MARK: - Audio capture
        struct Audio {
                let sampleRate: Double = 44_100
                let nyquistMultiplier: Double = 0.5
                
                var nyquistFrequency: Double { sampleRate * nyquistMultiplier }
        }
        
        // MARK: - FFT / STFT
        struct FFT {
                let size: Int = 8192
                let outputBinCount: Int = 512
                let hopSize: Int = 512 * 8
                var frequencyResolution: Double {
                        Audio().sampleRate / Double(size)
                }
                var circularBufferSize: Int { size * 3 }
        }
        
        // MARK: - Real-time rendering
        struct Rendering {
                let targetFPS: Double = 60
                var frameInterval: TimeInterval { 1.0 / targetFPS }
                
                let smoothingFactor: Float = 0.8
                let useLogFrequencyScale: Bool = true
                let minFrequency: Double = 20
                let maxFrequency: Double = 20_000
        }
        
        // MARK: - Spectral peak detection
        struct PeakDetection {
                var minProminence: Float = 6.0
                var minDistance: Int = 5
                var minHeight: Float = -60.0
                var prominenceWindow: Int = 50
        }
        
        // MARK: - Noise-floor estimation
        struct NoiseFloor {
                var method: NoiseFloorMethod = .quantileRegression
                var thresholdOffset: Float = 0.0
                var quantile: Float = 0.02
                var smoothingSigma: Float = 0.1
        }
        
        var audio = Audio()
        var fft = FFT()
        var rendering = Rendering()
        var peakDetection = PeakDetection()
        var noiseFloor = NoiseFloor()
        
        static let `default` = AnalyzerConfig()
}
