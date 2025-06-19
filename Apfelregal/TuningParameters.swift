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
        case werkmeister      = "Wankmeister III"
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
        @Published var audioSampleRate: Double = 44_100
        
        @Published var concertPitch: Double = 440.0
        @Published var targetNote: Note = Note(name: "a1")
        @Published var targetPartial: Int = 1
        
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
        
        @Published var centsError: Float = 0.0
        // Nyquist is derived automatically
        var nyquistFrequency: Double { audioSampleRate * 0.5 }
        
        // fftSize is a constant 8192 (immutable)
        let fftSize: Int = 2048 * 4
        let hopSize: Int = 512
        

        @Published var downscaleBinCount: Int = 512
        
        // Derived values:
        var frequencyResolution: Double {
                audioSampleRate / Double(fftSize)
        }
        var circularBufferSize: Int {
                fftSize * 3
        }
        let renderingTargetFPS: Double = 60
        var frameInterval: TimeInterval {
                1.0 / renderingTargetFPS
        }
        
        // Animation smoothing, log‐scale flag, min/max frequency are constants
        // TODO: make these mutable with a slider in the UI
        @Published var animationSmoothingFactor: Float = 0.7
        @Published var renderWithLogFrequencyScale: Bool = true
        @Published var renderMinFrequency: Double = 20
        @Published var renderMaxFrequency: Double = 20_000
        @Published var resolutionMUSIC: Double = 200
        @Published var currentMinFreq: Double = 20
        @Published var currentMaxFreq: Double = 20_000
        
        
        let currentMinDB = -180.0
        let currentMaxDB = 20.0

        func targetFrequency() -> Float {
                return Float(targetNote.frequency(concertA: concertPitch))
        }
        
        
        let anfWindowSizeCents: Double = 100.0
        func anfFrequencyWindow() -> (Double, Double) {
                let halfWindow: Double = anfWindowSizeCents / 2.0
                let center = Double(targetFrequency())
                let lower: Double = center * pow(2, -halfWindow/1200.0)
                let upper: Double = center * pow(2, halfWindow/1200.0)
                return (lower, upper)
        }
        
        func zoomCenterFrequencies(totalWindowCents: Float = 100.0) -> (lower: Double, upper: Double) {
                let center = self.targetNote.frequency(concertA: concertPitch)
                let (lowerF, upperF) = Note.calculateZoomCenterFrequency(centerFreq: center,
                                                                         totalWindowCents: totalWindowCents)
                return (Double(lowerF), Double(upperF))
        }

        static let `default` = TuningParameterStore()
}
