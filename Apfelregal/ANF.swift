import Foundation

final class AdaptiveNotchTracker {
        private let sampleRate: Double
        private var omega: Double  // Notch frequency in radians/sample
        private let r: Double      // Pole radius (controls bandwidth)
        private var y1: Double = 0 // Previous output
        private var y2: Double = 0 // Two samples ago output
        private var x1: Double = 0 // Previous input
        private var x2: Double = 0 // Two samples ago input
        private let mu: Double     // Fixed adaptation rate
        private var currentFrequency: Double
        private var residualEnergy: Double = 0
        private let energyAlpha: Double = 0.01  // Energy smoothing factor
        
        // Adaptation control
        private var adaptationEnabled = true
        
        // For convergence rating calculation
        private var frequencyHistory: [Double] = []
        private let historySize = 50
        private var printDebugCounter = 0
        
        init(centerFreq: Double, sampleRate: Double, bandwidth: Double = 5.0, adaptationRate: Double = 1e-3) {
                self.sampleRate = sampleRate
                self.currentFrequency = centerFreq
                self.omega = 2 * .pi * centerFreq / sampleRate
                self.r = 1.0 - (bandwidth * .pi / sampleRate)
                self.mu = adaptationRate  // Fixed rate
                
                print("🔧 ANF initialized at \(centerFreq) Hz, omega=\(self.omega), r=\(self.r), mu=\(self.mu)")
        }
        
        func process(sample: Double) -> Double {
                // Notch filter coefficients
                let cosOmega = cos(self.omega)
                let sinOmega = sin(self.omega)
                
                // Direct form II implementation
                let b0 = 1.0
                let b1 = -2 * cosOmega
                let b2 = 1.0
                let a1 = -2 * self.r * cosOmega
                let a2 = self.r * self.r
                
                // Compute output
                let y = b0 * sample + b1 * self.x1 + b2 * self.x2 - a1 * self.y1 - a2 * self.y2
                
                // Update residual energy
                let instantEnergy = y * y
                self.residualEnergy = (1 - self.energyAlpha) * self.residualEnergy + self.energyAlpha * instantEnergy
                
                if self.adaptationEnabled {
                        // Improved gradient calculation
                        // The gradient of output energy w.r.t. omega
                        let s1 = self.x1 - self.r * self.y1  // Intermediate signal
                        let gradient = 2 * y * sinOmega * (2 * s1)
                        
                        // Adaptive step size based on residual energy
                        let normalizedEnergy = self.residualEnergy / (self.residualEnergy + 0.1)
                        let currentMu = self.mu * (1.0 + 4.0 * normalizedEnergy)  // Larger steps when energy is high
                        
                        // Update omega
                        let deltaOmega = currentMu * gradient
                        
                        self.omega -= deltaOmega
                        
                        // Constrain omega to valid range
                        self.omega = max(0.01, min(0.99 * .pi, self.omega))
                        
                        // Update frequency
                        let newFreq = self.omega * self.sampleRate / (2 * .pi)
                        
                        self.currentFrequency = newFreq
                        
                        // Update frequency history
                        self.frequencyHistory.append(newFreq)
                        if self.frequencyHistory.count > self.historySize {
                                self.frequencyHistory.removeFirst()
                        }
                        
                        self.printDebugCounter += 1
                        if self.printDebugCounter % 1000 == 0 {
                                print("🔊 ANF Tracker: freq=\(self.currentFrequency) Hz, residual=\(self.residualEnergy)")
                        }
                }
                
                // Shift delay lines
                self.x2 = self.x1
                self.x1 = sample
                self.y2 = self.y1
                self.y1 = y
                
                return y
        }
        
        func getFrequencyEstimate() -> Double { self.currentFrequency }
        func getResidualEnergy() -> Double { self.residualEnergy }
        func getAmplitudeEstimate() -> Double {
                // Better amplitude estimation from notch depth
                if self.residualEnergy > 0 {
                        // If we're notching out a tone, estimate its amplitude from energy reduction
                        return sqrt(max(0, 1.0 - self.residualEnergy))
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
                self.y1 = 0; self.y2 = 0
                self.x1 = 0; self.x2 = 0
                self.residualEnergy = 0
                self.frequencyHistory.removeAll()
                self.printDebugCounter = 0
        }
}


final class CascadedANFTracker {
        private let buffer: FilteredCircularBuffer
        private var trackers: [AdaptiveNotchTracker]
        private let targetFreq: Double
        private let frequencyWindow: (Double, Double)
        private let sampleRate: Double
        private let trackingWindowSize: Int
        
        init(buffer: FilteredCircularBuffer,
             targetFreq: Double,
             frequencyWindow: (Double, Double),
             bandwidth: Double = 5.0,
             numTrackers: Int = 4) {
                
                self.buffer = buffer
                self.targetFreq = targetFreq
                self.frequencyWindow = frequencyWindow
                self.sampleRate = Double(buffer.sampleRate)
                self.trackingWindowSize = Int(0.1 * self.sampleRate) // 100ms window
                
                // Initialize trackers at different starting frequencies within the window
                self.trackers = []
                let freqStep = (frequencyWindow.1 - frequencyWindow.0) / Double(numTrackers + 1)
                
                for i in 0..<numTrackers {
                        let offset = frequencyWindow.0 + freqStep * Double(i + 1)
                        let initialFreq = targetFreq + offset
                        let tracker = AdaptiveNotchTracker(
                                centerFreq: initialFreq,
                                sampleRate: self.sampleRate,
                                bandwidth: bandwidth,
                                adaptationRate: 1e+1
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
