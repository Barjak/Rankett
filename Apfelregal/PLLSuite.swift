import Foundation
import Accelerate

// MARK: - Data Structures

public struct Complex {
        var real: Float
        var imag: Float
        
        static func +(lhs: Complex, rhs: Complex) -> Complex {
                return Complex(real: lhs.real + rhs.real, imag: lhs.imag + rhs.imag)
        }
        
        static func -(lhs: Complex, rhs: Complex) -> Complex {
                return Complex(real: lhs.real - rhs.real, imag: lhs.imag - rhs.imag)
        }
        
        static func *(lhs: Complex, rhs: Complex) -> Complex {
                return Complex(
                        real: lhs.real * rhs.real - lhs.imag * rhs.imag,
                        imag: lhs.real * rhs.imag + lhs.imag * rhs.real
                )
        }
        
        var magnitude: Float {
                return sqrt(real * real + imag * imag)
        }
        
        var phase: Float {
                return atan2(imag, real)
        }
}

public struct PartialEstimate {
        let frequency: Float
        let amplitude: Float
        let phase: Float
        let lockStrength: Float
        let timestamp: TimeInterval
        let isDegenerate: Bool
}

// MARK: - Bandpass Filter


// MARK: - Complex PLL

public class ComplexPLL {
        private var phase: Float = 0
        private var frequency: Float
        private var amplitude: Float = 0
        private let sampleRate: Float
        private let loopGain: Float
        private let lockThreshold: Float = 0.95
        private var lockQuality: Float = 0
        private var phaseError: Float = 0
        
        init(initialFreq: Float, sampleRate: Float = 44100, loopGain: Float = 0.01) {
                self.frequency = initialFreq
                self.sampleRate = sampleRate
                self.loopGain = loopGain
        }
        
        func track(_ input: [Complex]) -> (freq: Float, amp: Float, phase: Float, lockQuality: Float) {
                var instantFreqs = [Float]()
                var amplitudes = [Float]()
                
                for sample in input {
                        // Generate local oscillator
                        let localOsc = Complex(real: cos(phase), imag: sin(phase))
                        
                        // Mix with input (complex conjugate multiplication for downconversion)
                        let mixed = Complex(
                                real: sample.real * localOsc.real + sample.imag * localOsc.imag,
                                imag: sample.imag * localOsc.real - sample.real * localOsc.imag
                        )
                        
                        // Extract phase error
                        phaseError = atan2(mixed.imag, mixed.real)
                        
                        // Update frequency estimate
                        frequency += loopGain * phaseError * sampleRate / (2 * Float.pi)
                        
                        // Update phase
                        let phaseIncrement = 2 * Float.pi * frequency / sampleRate
                        phase += phaseIncrement
                        
                        // Wrap phase
                        while phase > Float.pi { phase -= 2 * Float.pi }
                        while phase < -Float.pi { phase += 2 * Float.pi }
                        
                        // Update amplitude estimate
                        amplitude = 0.95 * amplitude + 0.05 * sample.magnitude
                        
                        instantFreqs.append(frequency)
                        amplitudes.append(amplitude)
                }
                
                // Calculate lock quality based on phase error variance
                let avgPhaseError = phaseError
                lockQuality = exp(-abs(avgPhaseError) * 10)
                
                return (frequency, amplitude, phase, lockQuality)
        }
        
        var isLocked: Bool {
                return lockQuality > lockThreshold
        }
}

// MARK: - Signal Synthesis and Subtraction

public func synthesizeTone(freq: Float, amp: Float, phase: Float, length: Int, sampleRate: Float = 44100) -> [Complex] {
        var output = [Complex]()
        output.reserveCapacity(length)
        
        let phaseIncrement = 2 * Float.pi * freq / sampleRate
        var currentPhase = phase
        
        for _ in 0..<length {
                output.append(Complex(
                        real: amp * cos(currentPhase),
                        imag: amp * sin(currentPhase)
                ))
                currentPhase += phaseIncrement
        }
        
        return output
}

public func subtractSignal(input: [Complex], tone: [Complex]) -> [Complex] {
        guard input.count == tone.count else {
                fatalError("Signal lengths must match")
        }
        
        var output = [Complex](repeating: Complex(real: 0, imag: 0), count: input.count)
        
        // Use vDSP for efficient subtraction
        var inputReal = input.map { $0.real }
        var inputImag = input.map { $0.imag }
        let toneReal = tone.map { $0.real }
        let toneImag = tone.map { $0.imag }
        
        vDSP_vsub(toneReal, 1, inputReal, 1, &inputReal, 1, vDSP_Length(input.count))
        vDSP_vsub(toneImag, 1, inputImag, 1, &inputImag, 1, vDSP_Length(input.count))
        
        for i in 0..<output.count {
                output[i] = Complex(real: inputReal[i], imag: inputImag[i])
        }
        
        return output
}

public class OrganPipeTracker {
        private let sampleRate: Float
        private var partialEstimates: [PartialEstimate] = []
        private let convergenceTime: Float = 0.25 // 250ms
        private let frequencyTolerance: Float = 0.005 // 0.005 cents
        
        public init(sampleRate: Float = 44100) {
                self.sampleRate = sampleRate
        }
        
        public func sequentialTrack(
                input: [Complex],
                targetFreq: Float,
                nPeaks: Int,
                minFreq: Float? = nil,
                maxFreq: Float? = nil
        ) -> [PartialEstimate] {
                var residual = input
                var estimates = [PartialEstimate]()
                let samplesForConvergence = Int(convergenceTime * sampleRate)
                
                // Calculate cents spread for initial PLLs
                let centSpread: Float = 0.5
                let freqRatio = pow(2.0, centSpread / 1200.0)
                
                var attemptCount = 0
                var lockCount = 0
                
                for peakIndex in 0..<nPeaks {
                        // Calculate initial frequency with offset
                        let offset = Float(peakIndex - nPeaks/2) * (freqRatio - 1.0)
                        let initialFreq = targetFreq * (1.0 + offset)
                        
                        // Skip if outside bounds
                        if let minF = minFreq, initialFreq < minF { continue }
                        if let maxF = maxFreq, initialFreq > maxF { continue }
                        
                        attemptCount += 1
                        
                        // Create PLL
                        let pll = ComplexPLL(initialFreq: initialFreq, sampleRate: sampleRate)
                        
                        // Track for convergence time
                        let trackingSamples = min(samplesForConvergence, residual.count)
                        let trackingSlice = Array(residual.prefix(trackingSamples))
                        
                        let (freq, amp, phase, lockQuality) = pll.track(trackingSlice)
                        
                        // Skip if converged frequency is outside bounds
                        if let minF = minFreq, freq < minF { continue }
                        if let maxF = maxFreq, freq > maxF { continue }
                        
                        // Check for convergence
                        if lockQuality > 0.8 {
                                // Check for degeneracy with existing estimates
                                let isDegenerate = estimates.contains { existing in
                                        let centsDiff = 1200 * log2(freq / existing.frequency)
                                        return abs(centsDiff) < frequencyTolerance
                                }
                                
                                if !isDegenerate {
                                        lockCount += 1
                                        
                                        // Synthesize and subtract
                                        let synthesized = synthesizeTone(
                                                freq: freq,
                                                amp: amp,
                                                phase: phase,
                                                length: residual.count,
                                                sampleRate: sampleRate
                                        )
                                        
                                        residual = subtractSignal(input: residual, tone: synthesized)
                                        
                                        // Store estimate
                                        estimates.append(PartialEstimate(
                                                frequency: freq,
                                                amplitude: amp,
                                                phase: phase,
                                                lockStrength: lockQuality,
                                                timestamp: Date().timeIntervalSince1970,
                                                isDegenerate: false
                                        ))
                                }
                        }
                }
                
                // Update persistent estimates
                updatePersistentEstimates(with: estimates)
                
                return partialEstimates
        }
        
        private func updatePersistentEstimates(with newEstimates: [PartialEstimate]) {
                let currentTime = Date().timeIntervalSince1970
                let decayTime: TimeInterval = 2.0 // 2 seconds decay
                
                // Decay existing estimates
                partialEstimates = partialEstimates.compactMap { estimate in
                        let age = currentTime - estimate.timestamp
                        let decayFactor = Float(exp(-age / decayTime))
                        let decayedLockStrength = estimate.lockStrength * decayFactor
                        
                        if decayedLockStrength > 0.1 {
                                return PartialEstimate(
                                        frequency: estimate.frequency,
                                        amplitude: estimate.amplitude,
                                        phase: estimate.phase,
                                        lockStrength: decayedLockStrength,
                                        timestamp: estimate.timestamp,
                                        isDegenerate: estimate.isDegenerate
                                )
                        }
                        return nil
                }
                
                // Add new estimates
                partialEstimates.append(contentsOf: newEstimates)
        }
        
        public func getPersistentEstimates() -> [PartialEstimate] {
                return partialEstimates
        }
}

// MARK: - Main Processing Module

// MARK: - Updated OrganTunerModule
public class OrganTunerModule {
        private let sampleRate: Float
        private let store: TuningParameterStore
        private var trackers: [Int: OrganPipeTracker] = [:] // Keyed by partial index
        
        init(sampleRate: Float, store: TuningParameterStore) {
                self.sampleRate = sampleRate
                self.store = store
        }
        
        public func processAudioBlock(
                audioSamples: [Float],
                targetPitch: Float,
                partialIndices: [Int],
                expectedPeaksPerPartial: [Int: Int]
        ) -> [Int: [PartialEstimate]] {
                
                // Convert to complex (analytical signal via Hilbert transform would be ideal)
                let complexInput = audioSamples.map { Complex(real: $0, imag: 0) }
                
                var results: [Int: [PartialEstimate]] = [:]
                
                // Get filter bounds from store
                let minFreq = Float(store.currentMinFreq)
                let maxFreq = Float(store.currentMaxFreq)
                
                var totalLocks = 0
                var locksByPartial: [(Int, Int)] = [] // (partialIndex, lockCount)
                
                for partialIndex in partialIndices {
                        let partialFreq = targetPitch * Float(partialIndex)
                        
                        // Double-check this partial is within bounds
                        guard partialFreq >= minFreq && partialFreq <= maxFreq else {
                                continue
                        }
                        
                        let expectedPeaks = expectedPeaksPerPartial[partialIndex] ?? 1
                        
                        // Get or create tracker for this partial
                        if trackers[partialIndex] == nil {
                                trackers[partialIndex] = OrganPipeTracker(sampleRate: sampleRate)
                        }
                        
                        // Track peaks
                        let estimates = trackers[partialIndex]!.sequentialTrack(
                                input: complexInput,
                                targetFreq: partialFreq,
                                nPeaks: expectedPeaks,
                                minFreq: minFreq,
                                maxFreq: maxFreq
                        )
                        
                        results[partialIndex] = estimates
                        
                        let activeLocks = estimates.filter { $0.lockStrength > 0.8 }.count
                        if activeLocks > 0 {
                                totalLocks += activeLocks
                                locksByPartial.append((partialIndex, activeLocks))
                        }
                }
                
                // Debug output
                if totalLocks == 0 {
                        print("🔍 No PLL locks found for pitch \(targetPitch) Hz")
                } else {
                        print("✅ PLL locks: \(totalLocks) total")
                        for (partial, count) in locksByPartial.prefix(3) {
                                let freq = targetPitch * Float(partial)
                                print("   Partial \(partial) (\(String(format: "%.1f", freq)) Hz): \(count) locks")
                        }
                        if locksByPartial.count > 3 {
                                print("   ... and \(locksByPartial.count - 3) more partials")
                        }
                }
                
                return results
        }
}
