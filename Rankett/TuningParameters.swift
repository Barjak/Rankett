import SwiftUI
import Combine
import Foundation

enum NoiseFloorMethod {
        case quantileRegression
}

// MARK: – Enums and Supporting Types

enum EndCorrectionAlgorithm: String, CaseIterable {
        case naive                     = "Naive"
        case rayleigh                  = "Rayleigh's Simple Rule-of-Thumb"
        case parvs                     = "PARVS Model"
        case levineSchwinger           = "Levine & Schwinger Series #1"
        case morseIngard               = "Morse & Ingard First-Order"
        case ingardEmpirical           = "Ingard's Empirical Polynomial"
        case nomuraTsukamoto           = "Nomura & Tsukamoto Polynomial"
        case flanged                   = "Flanged Pipe Expansion"
        case partialFlange             = "Partial Flange"
        case ingardThickWall           = "Ingard's Thick-Wall"
        case nakamuraUeda              = "Nakamura & Ueda Thick-Wall"
        case directNumerical           = "Direct Numerical Integration"
}

enum NumericalDisplayMode: String, CaseIterable {
        case cents             = "Cents"
        case beat              = "Beat"
        case errorHz           = "Error (Hz)"
        case targetHz          = "Target (Hz)"
        case actualHz          = "Actual (Hz)"
        case theoreticalLength = "Pipe Length (Naive)"
        case lengthCorrectionNaive = "Length Correction (Naive)"
        case amplitudeBar      = "Amplitude"
        case finePitchBar      = "Fine Pitch"
}

enum Temperament: String, CaseIterable {
        case equal            = "Equal"
        case justIntonation   = "Just Intonation"
        case pythagorean      = "Pythagorean"
        case meantone         = "Meantone"
        case werkmeister      = "Werkmeister III"
        case valotti          = "Valotti"
}

struct Instrument: Identifiable, Equatable {
        let id = UUID()
        let name: String
        let overtoneProfile: [Double]   // Relative magnitudes for overtones 1–8
        let pipeScale: Double           // Diameter in mm
        let wallThickness: Double       // in mm
}

// MARK: – TuningParameterStore (now contains everything from AnalyzerConfig + your tuning params)

class TuningParameterStore: ObservableObject {
        @Published var concertPitch: Double = 440.0
        @Published var targetPitch: Double = 440.0
        @Published var targetPartial: Int = 1
        
        @Published var overtoneProfile: [Double] =
        [1.0, 0.5, 0.33, 0.25, 0.2, 0.17, 0.14, 0.125]
        
        @Published var pipeScale: Double = 138.0   // mm
        @Published var wallThickness: Double = 0.0 // mm
        @Published var endCorrectionAlgorithm: EndCorrectionAlgorithm = .naive
        
        @Published var temperament: Temperament = .equal
        @Published var gateTime: Double = 100.0    // milliseconds
        @Published var audibleToneEnabled: Bool = false
        @Published var pitchIncrementSemitones: Int = 1
        @Published var mutationStopTranspose: Int = 0
        
        @Published var leftDisplayMode: NumericalDisplayMode = .cents
        @Published var rightDisplayMode: NumericalDisplayMode = .errorHz
        
        @Published var selectedInstrument: Instrument = Instrument(
                name: "Principal 8'",
                overtoneProfile: [1.0, 0.5, 0.33, 0.25, 0.2, 0.17, 0.14, 0.125],
                pipeScale: 138.0,
                wallThickness: 0.0
        )
        
        // Calculated (read‐only) properties for the tuner:
        var actualPitch: Double = 440.0 // (would come from your audio processor)
        var centsError: Double {
                1200 * log2(actualPitch / targetPitch)
        }
        var beatFrequency: Double {
                abs(actualPitch - targetPitch)
        }

        
        // sampleRate is fixed at 44 100 Hz (immutable)
        let audioSampleRate: Double = 44_100
        // Nyquist is derived automatically
        var nyquistFrequency: Double { audioSampleRate * 0.5 }
        

        
        // fftSize is a constant 8192 (immutable)
        let fftSize: Int = 8192
        let hopSize: Int = 512

        
        // outputBinCount was 512 (we keep it @Published so it’s adjustable if you want):
        @Published var downscaleBinCount: Int = 512
        
        // Derived values:
        var frequencyResolution: Double {
                audioSampleRate / Double(fftSize)
        }
        var circularBufferSize: Int {
                fftSize * 3
        }
        
        
        // targetFPS is fixed at 60 (unpublished)
        let renderingTargetFPS: Double = 60
        var frameInterval: TimeInterval {
                1.0 / renderingTargetFPS
        }
        
        // Animation smoothing, log‐scale flag, min/max frequency are constants
        // TODO: make these mutable with a slider in the UI
        let animationSmoothingFactor: Float = 0.7
        let renderWithLogFrequencyScale: Bool = true
        let renderMinFrequency: Double = 20
        let renderMaxFrequency: Double = 20_000
        
        let noiseFloorMaxIterations = 10
        let noiseFloorConvergenceThreshold: Float = 1e-4
        let noiseFloorBandwidthSemitones: Float = 5.0
        

        
        @Published var noiseMethod: NoiseFloorMethod = .quantileRegression
        @Published var noiseThresholdOffset: Float = 10.0
        @Published var noiseQuantile: Float = 0.02
        

        
        static let `default` = TuningParameterStore()
}
