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

enum ZoomState: Int, CaseIterable {
        case fullSpectrum = 0
        case threeOctaves = 1
        case targetFundamental = 2
        
        var iconName: String {
                switch self {
                case .fullSpectrum: return "magnifyingglass"
                case .threeOctaves: return "magnifyingglass.circle"
                case .targetFundamental: return "magnifyingglass.circle.fill"
                }
        }
}

class TuningParameterStore: ObservableObject {
        // MARK: - Audio Configuration
        var audioSampleRate: Double = 44_100
        let fftSize: Int = 2048 * 4
        let hopSize: Int = 512
        
        // MARK: - Target Pitch Settings
        @Published var concertPitch: Double = 440.0
        @Published var targetNote: Note = Note(name: "a1")
        @Published var targetPartial: Int = 1
        
        // MARK: - Display Settings
        @Published var displayBinCount: Int = 512
        @Published var useLogFrequencyScale: Bool = true
        @Published var animationSmoothingFactor: Double = 0.7
        @Published var leftDisplayMode: NumericalDisplayMode = .cents
        @Published var rightDisplayMode: NumericalDisplayMode = .errorHz
        let minDB: Double = -180.0
        let maxDB: Double = 20.0
        
        // MARK: - Zoom & Viewport
        @Published var zoomState: ZoomState = .fullSpectrum {
                didSet {
                        updateViewportForZoom()
                }
        }
        
        let fullSpectrumMinFreq: Double = 20
        let fullSpectrumMaxFreq: Double = 20_000
        
        @Published var viewportMinFreq: Double = 20
        @Published var viewportMaxFreq: Double = 20_000
        
        // MARK: - Processing Settings
        @Published var usePreprocessor: Bool = true
        @Published var endCorrectionAlgorithm: EndCorrectionAlgorithm = .naive
        @Published var gateTime: Double = 100.0
        
        // MARK: - Instrument & Tuning
        @Published var selectedInstrument: Instrument = Instrument(
                name: "Principal 8'",
                overtoneProfile: [1.0, 0.5, 0.33, 0.25, 0.2, 0.17, 0.14, 0.125],
                pipeScale: 138.0,
                wallThickness: 0.0
        )
        @Published var temperament: Temperament = .equal
        @Published var audibleToneEnabled: Bool = false
        @Published var pitchIncrementSemitones: Int = 1
        @Published var mutationStopTranspose: Int = 0
        
        @Published var centsError: Double = 0.0
        
        // MARK: - Computed Properties
        var nyquistFrequency: Double {
                audioSampleRate * 0.5
        }
        
        var frequencyResolution: Double {
                audioSampleRate / Double(fftSize)
        }
        
        var circularBufferSize: Int {
                fftSize * 3
        }
        
        func targetFrequency() -> Double {
                Double(targetNote.frequency(concertA: concertPitch))
        }
        
        private func updateViewportForZoom() {
                switch zoomState {
                case .fullSpectrum:
                        viewportMinFreq = fullSpectrumMinFreq
                        viewportMaxFreq = fullSpectrumMaxFreq
                        
                case .threeOctaves:
                        let baseFreq = targetNote.transposed(by: -1).frequency(concertA: concertPitch)
                        let maxFreq = targetNote.transposed(by: 12 * 3).frequency(concertA: concertPitch)
                        viewportMinFreq = Double(baseFreq)
                        viewportMaxFreq = min(Double(maxFreq), fullSpectrumMaxFreq)
                        
                case .targetFundamental:
                        let centerFreq = targetFrequency()
                        viewportMinFreq = centerFreq * pow(2, -50.0/1200.0)
                        viewportMaxFreq = centerFreq * pow(2, 50.0/1200.0)
                }
        }
        
        static let `default` = TuningParameterStore()
}
