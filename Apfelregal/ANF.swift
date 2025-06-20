import Foundation

final class AdaptiveNotchTracker {
        private let sampleRate: Double
        private var omega: Double  // Notch frequency in radians/sample
        private let r: Double      // Single pole radius for bandwidth control
        private var y1: Double = 0 // Previous output y[n-1]
        private var y2: Double = 0 // Two samples ago output y[n-2]
        private var x1: Double = 0 // Previous input x[n-1]
        private var x2: Double = 0 // Two samples ago input x[n-2]
        private let mu: Double     // Base adaptation rate
        private var currentFrequency: Double
        private var residualEnergy: Double = 0
        private let energyAlpha: Double = 0.01  // Energy smoothing factor
        
        // Reference to parameter store for dynamic target frequency
        private weak var parameterStore: TuningParameterStore?
        
        // Spring regularization parameters
        private let lambda: Double = 1.0  // Spring constant
        
        // Omega smoothing parameter
        private let omegaSmoothingAlpha: Double = 0.9  // Strong smoothing
        
        // Energy gating threshold
        private let energyThreshold: Double = 1e-4
        
        // Gradient clamping parameters
        private let maxGradient: Double = 100.0
        
        // Adaptation control
        private var adaptationEnabled = true
        
        // For convergence rating calculation
        private var frequencyHistory: [Double] = []
        private let historySize = 50
        private var printDebugCounter = 0
        
        init(centerFreq: Double,
             sampleRate: Double,
             bandwidth: Double = 5.0,
             adaptationRate: Double = 1e-4,
             parameterStore: TuningParameterStore?) {
                
                self.sampleRate = sampleRate
                self.currentFrequency = centerFreq
                self.omega = 2 * .pi * centerFreq / sampleRate
                self.parameterStore = parameterStore
                
                // Convert bandwidth in Hz to pole radius
                // r closer to 1 = narrower bandwidth
                let bandwidthRad = bandwidth * .pi / sampleRate
                self.r = 1.0 - bandwidthRad
                
                self.mu = adaptationRate
                
                print("🔧 ANF initialized at \(centerFreq) Hz, omega=\(self.omega)")
                print("   Bandwidth: \(bandwidth) Hz, r=\(self.r)")
                print("   Spring constant λ=\(lambda), smoothing α=\(omegaSmoothingAlpha)")
        }
        
        func process(sample: Double) -> Double {

                let cosOmega = cos(self.omega)
                let sinOmega = sin(self.omega)
                

                let b0 = 1.0
                let b1 = -2.0 * cosOmega
                let b2 = 1.0
                let a1 = -2.0 * self.r * cosOmega
                let a2 = self.r * self.r
                

                let y = b0 * sample + b1 * self.x1 + b2 * self.x2 - a1 * self.y1 - a2 * self.y2
                

                let instantEnergy = y * y
                self.residualEnergy = (1 - self.energyAlpha) * self.residualEnergy + self.energyAlpha * instantEnergy
                

                if self.adaptationEnabled && self.residualEnergy > self.energyThreshold {

                        let dyDomega = 2.0 * sinOmega * (self.x1 + self.r * self.y1)
                        

                        let gradient = 2.0 * y * dyDomega

                        let clampedGradient = max(-self.maxGradient, min(self.maxGradient, gradient))

                        let normalizedEnergy = self.residualEnergy / (self.residualEnergy + 0.1)
                        let currentMu = self.mu * (1.0 + 4.0 * normalizedEnergy)
                        

                        let deltaOmega = currentMu * clampedGradient
                        

                        let rawOmega = self.omega - deltaOmega
                        self.omega = self.omegaSmoothingAlpha * self.omega + (1 - self.omegaSmoothingAlpha) * rawOmega
                        

                        self.omega = max(0.01, min(0.99 * .pi, self.omega))
                        
                        let newFreq = self.omega * self.sampleRate / (2 * .pi)
                        self.currentFrequency = newFreq
                        
                        self.frequencyHistory.append(newFreq)
                        if self.frequencyHistory.count > self.historySize {
                                self.frequencyHistory.removeFirst()
                        }
                        
                        self.printDebugCounter += 1
                        if self.printDebugCounter % 1000 == 0 {
                                let targetFreq = parameterStore?.targetFrequency() ?? 0
                                let freqError = self.currentFrequency - Double(targetFreq)
                                print("🔊 ANF Tracker: freq=\(self.currentFrequency) Hz, residual=\(self.residualEnergy)")
                                print("   Gradient: \(clampedGradient)")
                                print("   Freq error: \(freqError) Hz, target: \(targetFreq) Hz")
                                print("   Omega: \(self.omega) (max: \(0.99 * .pi))")
                        }
                }
                

                self.x2 = self.x1
                self.x1 = sample
                self.y2 = self.y1
                self.y1 = y
                
                return y
        }
        
        func getFrequencyEstimate() -> Double { self.currentFrequency }
        func getResidualEnergy() -> Double { self.residualEnergy }
        
        func getAmplitudeEstimate() -> Double {
                // Estimate amplitude from notch depth
                // When notching a pure tone, residual energy is minimal
                // Original signal amplitude ≈ sqrt(input_energy - residual_energy)
                // This is a rough estimate
                if self.residualEnergy < 0.5 {
                        return sqrt(1.0 - 2.0 * self.residualEnergy)
                }
                return 0.0
        }
        
        func getBandwidth() -> Double {
                // Convert pole radius back to bandwidth in Hz
                return (1.0 - self.r) * self.sampleRate / .pi
        }
        
        func getConvergenceRating() -> Double {
                // Calculate convergence rating based on frequency stability
                guard self.frequencyHistory.count >= 10 else { return 0.0 }
                
                // Calculate standard deviation of recent frequencies
                let recentHistory = Array(self.frequencyHistory.suffix(10))
                let mean = recentHistory.reduce(0.0, +) / Double(recentHistory.count)
                let variance = recentHistory.reduce(0.0) { sum, freq in
                        sum + pow(freq - mean, 2)
                } / Double(recentHistory.count)
                let stdDev = sqrt(variance)
                
                // Convert to rating (lower std dev = higher rating)
                return max(0.0, min(1.0, 1.0 - stdDev / 10.0))
        }
        
        func reset() {
                self.y1 = 0
                self.y2 = 0
                self.x1 = 0
                self.x2 = 0
                self.residualEnergy = 0
                self.frequencyHistory.removeAll()
                self.printDebugCounter = 0
        }
}

// CascadedANFTracker remains unchanged
final class CascadedANFTracker {
        private let buffer: FilteredCircularBuffer
        private var trackers: [AdaptiveNotchTracker]
        private let parameterStore: TuningParameterStore
        private let frequencyWindow: (Double, Double)
        private let sampleRate: Double
        private let trackingWindowSize: Int
        
        init(buffer: FilteredCircularBuffer,
             parameterStore: TuningParameterStore,
             frequencyWindow: (Double, Double),
             bandwidth: Double = 5.0,
             numTrackers: Int = 4) {
                
                self.buffer = buffer
                self.parameterStore = parameterStore
                self.frequencyWindow = frequencyWindow
                self.sampleRate = Double(buffer.sampleRate)
                self.trackingWindowSize = Int(0.1 * self.sampleRate) // 100ms window
                
                // Initialize trackers at different starting frequencies within the window
                self.trackers = []
                let targetFreq = parameterStore.targetFrequency()
                let freqStep = (frequencyWindow.1 - frequencyWindow.0) / Double(numTrackers + 1)
                
                for i in 0..<numTrackers {
                        let offset = frequencyWindow.0 + freqStep * Double(i + 1)
                        let initialFreq = Double(targetFreq) + offset
                        let tracker = AdaptiveNotchTracker(
                                centerFreq: initialFreq,
                                sampleRate: self.sampleRate,
                                bandwidth: bandwidth,
                                adaptationRate: 1e-2,
                                parameterStore: parameterStore
                        )
                        self.trackers.append(tracker)
                }
        }
        
        func track() -> [ANFDatum] {
                // Get latest samples for processing
                guard let samples = self.buffer.getLatest(size: self.trackingWindowSize) else {
                        return []
                }
                
                // Process samples through all trackers
                for sample in samples {
                        for tracker in self.trackers {
                                _ = tracker.process(sample: Double(sample))
                        }
                }
                
                // Collect results
                var results: [ANFDatum] = []
                
                for tracker in self.trackers {
                        let freq = tracker.getFrequencyEstimate()
                        let amp = tracker.getAmplitudeEstimate()
                        let bandwidth = tracker.getBandwidth()
                        let convergenceRating = tracker.getConvergenceRating()
                        
                        results.append(ANFDatum(
                                freq: freq,
                                amp: amp,
                                bandwidth: bandwidth,
                                convergenceRating: convergenceRating
                        ))
                }
                
                // Sort by amplitude (strongest first)
                results.sort { $0.amp > $1.amp }
                
                print("  ✅ Found \(results.count) frequencies:")
                for (i, result) in results.enumerated() {
                        print("    [\(i)]: \(result.freq) Hz, amp=\(result.amp)")
                }
                
                return self.deduplicateResults(results)
        }
        
        private func deduplicateResults(_ results: [ANFDatum]) -> [ANFDatum] {
                var deduplicated: [ANFDatum] = []
                let freqTolerance = 0.1  // Hz
                
                for result in results {
                        let isDuplicate = deduplicated.contains { existing in
                                abs(existing.freq - result.freq) < freqTolerance
                        }
                        
                        if !isDuplicate {
                                deduplicated.append(result)
                        }
                }
                
                return deduplicated
        }
        
        func reset() {
                for tracker in self.trackers {
                        tracker.reset()
                }
        }
}
