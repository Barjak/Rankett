import Foundation

enum NoiseFloorMethod {
        case quantileRegression
        case huberAsymmetric
        case parametric1OverF
        case whittaker
}


struct LayoutParameters {
        var spectrumHeightFraction: CGFloat = 0.40
        var studyHeightFraction: CGFloat    = 0.40
        var maxPanelHeight: CGFloat?        = nil      // e.g. 420 to clamp on iPad
        // add more UI knobs here as needed (button sizes, corner radii, etc.)
}


struct AnalyzerConfig {
        
        // MARK: - Audio capture
        struct Audio {
                let sampleRate: Double       = 44_100
                let nyquistMultiplier: Double = 0.5     // mostly for clarity
                
                var nyquistFrequency: Double { sampleRate * nyquistMultiplier }
        }
        
        // MARK: - FFT / STFT
        struct FFT {
                let size: Int                = 512 * 8
                let outputBinCount: Int      = 512
                let hopSize: Int             = 512                    // ≈ 86 windows/s
                var frequencyResolution: Double {
                        Audio().sampleRate / Double(size)
                }
                var circularBufferSize: Int { size * 3 }
        }
        
        // MARK: - Real-time rendering
        struct Rendering {
                let targetFPS: Double = 60
                var frameInterval: TimeInterval { 1.0 / targetFPS }
                
                let smoothingFactor: Float        = 0.85
                let useLogFrequencyScale: Bool    = true
                let minFrequency: Double          = 20
                let maxFrequency: Double          = 20_000
        }
        
        // MARK: - Spectral peak detection
        struct PeakDetection {
                var minProminence: Float  = 6.0   // dB
                var minDistance: Int      = 5     // bins
                var minHeight: Float      = -60.0 // dBFS
                var prominenceWindow: Int = 50    // bins
        }
        
        // MARK: - Noise-floor estimation

        
        struct NoiseFloor {
                var method: NoiseFloorMethod = .whittaker
                var thresholdOffset: Float = 0.0      // dB above fitted floor
                
                // Quantile regression
                var quantile: Float        = 0.1
                
                // Huber loss
                var huberDelta: Float      = 1.0
                var huberAsymmetry: Float  = 2.0
                
                // Common smoothing
                var smoothingSigma: Float  = 1.0
                
                // Whittaker smoother
                var whittakerLambda: Float = 1_000.0
                var whittakerOrder: Int    = 2
        }

        // MARK: - Members & defaults
        var audio         = Audio()
        var fft           = FFT()
        var rendering     = Rendering()
        var peakDetection = PeakDetection()
        var noiseFloor    = NoiseFloor()
        
        static let `default` = AnalyzerConfig()
}
