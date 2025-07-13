import Foundation
import Combine
import Accelerate

struct AutoTuneJob: StudyJob {
        // MARK: - Public
        let id = UUID()
        var remainingFrames = Int.max
        
        // MARK: - Config
        private static let minFreq      = 55.0      // A1
        private static let maxFreq      = 2000.0    // about C7
        private static let hpsHarmonics = 4
        private static let centsTol     = 45.0
        private static let snrDbNeeded  = 30.0
        private static let obviousSnrDb = 30.0
        
        // EWMA confidence: new = α*old + (1-α)*signal
        private static let ewmaAlpha    = 0.85
        private static let exitScore    = 0.75      // adjusted for EWMA scale
        
        // MARK: - State
        private let startTime = CFAbsoluteTimeGetCurrent()
        private let timeout: Double = 10.0
        
        private var confidence = 0.0
        private var lastGoodF0: Double? = nil
        private var hpsBuffer: [Double] = []
        
        // MARK: - Per-frame ingestion
        mutating func ingest(frame: StudyResults, context: StudyContext) {
                guard shouldContinue else {
                        remainingFrames = 0
                        return
                }
                
                guard let (f0, snrDb) = estimateF0(from: context.fullSpectrum,
                                                   freqs: context.fullFrequencies) else {
                        updateConfidence(hit: false)
                        return
                }
                
                if snrDb >= Self.obviousSnrDb {
                        lastGoodF0 = f0
                        remainingFrames = 0
                        return
                }
                
                let isStable = lastGoodF0.map { centsBetween(f0, $0) < Self.centsTol } ?? false
                updateConfidence(hit: isStable)
                lastGoodF0 = f0
                
                if confidence >= Self.exitScore {
                        remainingFrames = 0
                }
        }
        
        // MARK: - Result
        func finish(using study: Study) -> Note? {
                guard let f0 = lastGoodF0 else { return nil }
                let (note, cents) = Note.getClosestNote(frequency: f0,
                                                        concertA: study.store.concertPitch)
                return abs(cents) <= Self.centsTol ? note : nil
        }
        
        // MARK: - Private
        private var shouldContinue: Bool {
                CFAbsoluteTimeGetCurrent() - startTime < timeout && remainingFrames > 0
        }
        
        private mutating func updateConfidence(hit: Bool) {
                confidence = Self.ewmaAlpha * confidence + (1 - Self.ewmaAlpha) * (hit ? 1.0 : 0.0)
        }
        
        private mutating func estimateF0(from spectrum: ArraySlice<Double>,
                                         freqs: ArraySlice<Double>) -> (Double, Double)? {
                guard spectrum.count == freqs.count else { return nil }
                let N = spectrum.count
                
                let noiseDb = noiseFloor(spectrum)
                
                // Ensure buffer is sized correctly
                if hpsBuffer.count != N {
                        hpsBuffer = Array(repeating: 0, count: N)
                }
                
                // Initialize HPS with original spectrum
                spectrum.withUnsafeBufferPointer { src in
                        hpsBuffer.withUnsafeMutableBufferPointer { dst in
                                vDSP_mmovD(src.baseAddress!, dst.baseAddress!,
                                           vDSP_Length(N), 1, vDSP_Length(N), vDSP_Length(N))
                        }
                }
                
                // Accumulate downsampled harmonics
                for h in 2...Self.hpsHarmonics {
                        let stride = h
                        let count = N / stride
                        spectrum.withUnsafeBufferPointer { src in
                                hpsBuffer.withUnsafeMutableBufferPointer { dst in
                                        vDSP_vaddD(dst.baseAddress!, 1,
                                                   src.baseAddress!, stride,
                                                   dst.baseAddress!, 1,
                                                   vDSP_Length(count))
                                }
                        }
                }
                
                let validBins = N / Self.hpsHarmonics
                
                // Find search range
                guard let lo = freqs.firstIndex(where: { $0 >= Self.minFreq }),
                      let hi = freqs.firstIndex(where: { $0 > Self.maxFreq }),
                      lo < validBins else { return nil }
                
                let searchEnd = min(hi, validBins)
                
                // Find peak above SNR threshold
                var maxIdx = -1
                var maxVal = -Double.infinity
                var maxSnr = 0.0
                
                for i in lo..<searchEnd {
                        let snr = spectrum[i] - noiseDb
                        if snr >= Self.snrDbNeeded && hpsBuffer[i] > maxVal {
                                maxVal = hpsBuffer[i]
                                maxIdx = i
                                maxSnr = snr
                        }
                }
                
                guard maxIdx >= 1 && maxIdx < validBins - 1 else { return nil }
                
                // Parabolic interpolation
                let y0 = hpsBuffer[maxIdx - 1]
                let y1 = hpsBuffer[maxIdx]
                let y2 = hpsBuffer[maxIdx + 1]
                
                let denom = 2 * (y0 - 2 * y1 + y2)
                let delta = denom == 0 ? 0 : (y0 - y2) / denom
                
                let binWidth = freqs[maxIdx + 1] - freqs[maxIdx]
                let f0 = freqs[maxIdx] + delta * binWidth
                
                return (f0, maxSnr)
        }
        
        private func noiseFloor(_ x: ArraySlice<Double>) -> Double {
                let n = Double(x.count)
                var mean = 0.0
                var sumSq = 0.0
                
                x.withUnsafeBufferPointer { ptr in
                        vDSP_meanvD(ptr.baseAddress!, 1, &mean, vDSP_Length(x.count))
                        vDSP_measqvD(ptr.baseAddress!, 1, &sumSq, vDSP_Length(x.count))
                }
                
                let variance = sumSq - mean * mean
                let sd = sqrt(max(variance, 0))
                
                return mean + 2.0 * sd  // ~97.5th percentile for normal distribution
        }
        
        private func centsBetween(_ f1: Double, _ f2: Double) -> Double {
                abs(1200.0 * log2(f1 / f2))
        }
}


struct AutoConcertPitchJob: StudyJob {
        let id = UUID()
        var remainingFrames = Int.max
        
        private static let stabilityThresholdCents = 10.5
        private static let snrDbNeeded = 20.0
        private static let maxDeviationCents = 50.0
        private static let ewmaAlpha = 0.85
        private static let exitConfidence = 0.75
        
        private let startTime = CFAbsoluteTimeGetCurrent()
        private let timeout: Double = 10.0
        
        private var confidence = 0.0
        private var referenceFrequency: Double?
        private var frequencyAccumulator = 0.0
        private var sampleCount = 0
        private var frameCount = 0
        
        mutating func ingest(frame: StudyResults, context: StudyContext) {
                frameCount += 1
                
                guard CFAbsoluteTimeGetCurrent() - startTime < timeout else {
                        print("AutoConcertPitch: Timeout reached")
                        remainingFrames = 0
                        return
                }
                
                guard let preprocessor = context.preprocessor else {
                        print("Missing preprocessor")
                        updateConfidence(hit: false)
                        return
                }
                guard let ekfFreq = context.ekfFrequency,
                      let ekfAmp  = context.ekfAmplitude else {
                        print("Missing EKF data")
                        updateConfidence(hit: false)
                        return
                }
                
                let noiseFloorDb = noiseFloor(context.fullSpectrum)
                
                // Find the spectral peak near the EKF frequency
                let currentFrequency = preprocessor.fBaseband + ekfFreq
                guard let peakBin = context.fullFrequencies.firstIndex(where: { $0 >= currentFrequency }),
                      peakBin > 0 && peakBin < context.fullSpectrum.count else {
                        updateConfidence(hit: false)
                        return
                }
                
                let peakDb = context.fullSpectrum[peakBin]
                let snrDb = peakDb - noiseFloorDb
                
                print("AutoConcertPitch frame \(frameCount): peak=\(peakDb)dB, noise=\(noiseFloorDb)dB, SNR=\(snrDb)dB, confidence=\(confidence)")
                
                if snrDb < Self.snrDbNeeded {
                        updateConfidence(hit: false)
                        return
                }
                
                let deviationCents = abs(1200.0 * log2(1.0 + ekfFreq / preprocessor.fBaseband))
                
                if deviationCents >= Self.maxDeviationCents {
                        print("AutoConcertPitch frame \(frameCount): Large deviation \(deviationCents) cents")
                        updateConfidence(hit: false)
                        return
                }
                
                if let refFreq = referenceFrequency {
                        let cents = abs(1200.0 * log2(currentFrequency / refFreq))
                        let isStable = cents < Self.stabilityThresholdCents
                        updateConfidence(hit: isStable)
                        
                        if isStable {
                                frequencyAccumulator += currentFrequency
                                sampleCount += 1
                        } else if cents > Self.stabilityThresholdCents * 2 {
                                print("AutoConcertPitch: Reset reference, deviation \(cents) cents")
                                referenceFrequency = currentFrequency
                                frequencyAccumulator = currentFrequency
                                sampleCount = 1
                        }
                } else {
                        referenceFrequency = currentFrequency
                        frequencyAccumulator = currentFrequency
                        sampleCount = 1
                        updateConfidence(hit: true)
                        print("AutoConcertPitch: Set initial reference to \(currentFrequency) Hz")
                }
                
                if confidence >= Self.exitConfidence {
                        print("AutoConcertPitch: Exit condition met! confidence=\(confidence), samples=\(sampleCount)")
                        remainingFrames = 0
                }
        }
        
        func finish(using study: Study) -> Double? {
                guard confidence >= Self.exitConfidence, sampleCount > 0 else {
                        print("AutoConcertPitch: Failed - confidence=\(confidence), samples=\(sampleCount)")
                        return nil
                }
                
                let averageFreq = frequencyAccumulator / Double(sampleCount)
                let targetFreq = study.store.targetFrequency()
                guard targetFreq > 0 else { return nil }
                
                let newPitch = study.store.concertPitch * (averageFreq / targetFreq)
                print("AutoConcertPitch: Success! avg=\(averageFreq), target=\(targetFreq), newPitch=\(newPitch)")
                return newPitch
        }
        
        private mutating func updateConfidence(hit: Bool) {
                confidence = Self.ewmaAlpha * confidence + (1 - Self.ewmaAlpha) * (hit ? 1.0 : 0.0)
        }
        
        private func noiseFloor(_ x: ArraySlice<Double>) -> Double {
                let n = Double(x.count)
                var mean = 0.0
                var sumSq = 0.0
                
                x.withUnsafeBufferPointer { ptr in
                        vDSP_meanvD(ptr.baseAddress!, 1, &mean, vDSP_Length(x.count))
                        vDSP_measqvD(ptr.baseAddress!, 1, &sumSq, vDSP_Length(x.count))
                }
                
                let variance = sumSq - mean * mean
                let sd = sqrt(max(variance, 0))
                
                return mean + 2.0 * sd
        }
}
