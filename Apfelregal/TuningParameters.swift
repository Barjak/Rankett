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
        @Published var concertPitch: Double = 440.0 {
                didSet {
                        print("📻 ConcertPitch changed: \(oldValue) → \(concertPitch) Hz")
                        print("   Target frequency now: \(targetFrequency()) Hz")
                }
        }
        
        @Published var targetNote: Note = Note(name: "a1") {
                didSet {
                        print("🎵 TargetNote changed: \(oldValue.name) → \(targetNote.name)")
                        print("   Target frequency now: \(targetFrequency()) Hz")
                }
        }
        
        @Published var targetPartial: Int = 1 {
                didSet {
                        print("🎸 TargetPartial changed: \(oldValue) → \(targetPartial)")
                        print("   Target frequency now: \(targetFrequency()) Hz")
                }
        }
        
        // MARK: - Display Settings
        @Published var displayBinCount: Int = 512
        @Published var useLogFrequencyScale: Bool = true
        @Published var animationSmoothingFactor: Double = 0.7
        @Published var leftDisplayMode: NumericalDisplayMode = .cents
        @Published var rightDisplayMode: NumericalDisplayMode = .errorHz
        var targetBandwidth = 200.0
        let minDB: Double = -150.0
        let maxDB: Double = 50.0
        
        // MARK: - Zoom & Viewport
        @Published var zoomState: ZoomState = .fullSpectrum {
                didSet {
                        print("🔍 ZoomState changed: \(oldValue) → \(zoomState)")
                        updateViewportForZoom()  // No parameters - use current values
                }
        }
        
        let fullSpectrumMinFreq: Double = 20
        let fullSpectrumMaxFreq: Double = 20_000
        
        @Published var viewportMinFreq: Double = 20 {
                didSet {
                        print("📊 ViewportMinFreq changed: \(String(format: "%.2f", oldValue)) → \(String(format: "%.2f", viewportMinFreq)) Hz")
                }
        }
        
        @Published var viewportMaxFreq: Double = 20_000 {
                didSet {
                        print("📊 ViewportMaxFreq changed: \(String(format: "%.2f", oldValue)) → \(String(format: "%.2f", viewportMaxFreq)) Hz")
                        print("   Viewport range: \(String(format: "%.2f", viewportMaxFreq/viewportMinFreq))x")
                }
        }
        
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
        let musicSourceCount: Int = 1          // Fundamental + 3 harmonics typical for organ
        let musicGridResolution: Int = 1024    // Good balance of precision vs computation
        let musicMinSamples: Int = 500          // Minimum for stable covariance estimation
        @Published var musicEnabled: Bool = false
        
        @Published var centsError: Double = 0.0
        
        private var cancellables = Set<AnyCancellable>()
        
        // MARK: - Initialization
        
        init() {
                setupViewportSubscriptions()
        }
        
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
        
        // MARK: - Private Methods
        
        private func setupViewportSubscriptions() {
                Publishers.CombineLatest3($targetNote, $targetPartial, $concertPitch)
                        .sink { [weak self] note, partial, pitch in
                                guard let self = self else { return }
                                print("🔄 Viewport subscription triggered: note=\(note.name), partial=\(partial), pitch=\(pitch)")
                                if self.zoomState != .fullSpectrum {
                                        // Pass the new values directly instead of reading from properties
                                        self.updateViewportForZoom(note: note, partial: partial, pitch: pitch)
                                }
                        }
                        .store(in: &cancellables)
        }
        
        private func updateViewportForZoom(note: Note? = nil, partial: Int? = nil, pitch: Double? = nil) {
                let oldMin = viewportMinFreq
                let oldMax = viewportMaxFreq
                
                // Use passed values if available, otherwise use stored values
                let currentNote = note ?? targetNote
                let currentPartial = partial ?? targetPartial
                let currentPitch = pitch ?? concertPitch
                
                switch zoomState {
                case .fullSpectrum:
                        print("🔍 Updating viewport for FULL SPECTRUM")
                        viewportMinFreq = fullSpectrumMinFreq
                        viewportMaxFreq = fullSpectrumMaxFreq
                        
                case .threeOctaves:
                        let clampedNote = clampToPianoRange(currentNote)
                        let targetFreq = Double(clampedNote.frequency(concertA: currentPitch)) * Double(currentPartial)
                        print("🔍 Updating viewport for THREE OCTAVES")
                        print("   Clamped note: \(clampedNote.name) (was: \(currentNote.name))")
                        print("   Target freq: \(String(format: "%.2f", targetFreq)) Hz")
                        
                        viewportMinFreq = targetFreq * pow(2, -targetBandwidth/1200.0)
                        viewportMaxFreq = targetFreq * pow(2, (36*100 + targetBandwidth)/1200.0)
                        
                case .targetFundamental:
                        let centerFreq = Double(currentNote.frequency(concertA: currentPitch)) * Double(currentPartial)
                        print("🔍 Updating viewport for TARGET FUNDAMENTAL")
                        print("   Center freq: \(String(format: "%.2f", centerFreq)) Hz")
                        
                        viewportMinFreq = centerFreq * pow(2, -targetBandwidth/1200.0)
                        viewportMaxFreq = centerFreq * pow(2, targetBandwidth/1200.0)
                }
                
                print("   Viewport: \(String(format: "%.2f-%.2f", viewportMinFreq, viewportMaxFreq)) Hz")
                print("   Changed: \(oldMin != viewportMinFreq || oldMax != viewportMaxFreq)")
        }
        
        private func clampToPianoRange(_ note: Note) -> Note {
                let a0 = Note(name: "A0")
                let c8 = Note(name: "C8")
                
                if note < a0 {
                        return a0
                } else if note > c8 {
                        return c8
                } else {
                        return note
                }
        }
        
        static let `default` = TuningParameterStore()
}
