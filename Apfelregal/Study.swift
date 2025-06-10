import Foundation
import SwiftUICore
import Accelerate
import CoreML

final class HPSProcessor {
        private let harmonicProfile: [Float]
        private let workspace: UnsafeMutablePointer<Float>
        
        init(spectrumSize: Int, harmonicProfile: [Float] = [0.1, 0.2, 0.3, 0.35]) {
                self.harmonicProfile = harmonicProfile
                self.workspace = UnsafeMutablePointer<Float>.allocate(capacity: spectrumSize)
        }
        
        deinit {
                workspace.deallocate()
        }
        
        func computeHPS(magnitudes: UnsafePointer<Float>,
                        count: Int,
                        sampleRate: Float) -> (fundamental: Float, hpsSpectrum: [Float]) {
                // 1) Compute mean, zero‐out workspace
                var meanMag: Float = 0
                vDSP_meanv(magnitudes, 1, &meanMag, vDSP_Length(count))
                memset(workspace, 0, count * MemoryLayout<Float>.size)
                
                // 2) Build the weighted harmonic product in 'workspace'
                for i in 0..<(count / harmonicProfile.count) {
                        let fundamentalMag = magnitudes[i]
                        let snr = fundamentalMag / (meanMag + 1e-10)
                        let adaptiveWeight = 1.0 - exp(-snr)
                        workspace[i] = harmonicProfile[0] * fundamentalMag * adaptiveWeight
                        
                        for (h, weight) in harmonicProfile.enumerated().dropFirst() {
                                let harmonicNumber = h + 2
                                let harmonicIndex = i * harmonicNumber
                                if harmonicIndex < count {
                                        workspace[i] += weight * magnitudes[harmonicIndex] * adaptiveWeight
                                }
                        }
                }
                
                // 3) If there is at least one coefficient, blend fundamental itself
                if !harmonicProfile.isEmpty {
                        var fundamentalWeight = harmonicProfile[0]
                        vDSP_vsmul(magnitudes, 1, &fundamentalWeight, workspace, 1, vDSP_Length(count))
                } else {
                        memcpy(workspace, magnitudes, count * MemoryLayout<Float>.size)
                }
                
                // 4) Apply the rest of the weighted multiplications (in “log domain”)
                for (h, weight) in harmonicProfile.enumerated().dropFirst() {
                        let harmonicNumber = h + 2
                        if weight > 0 {
                                for i in 0..<(count / harmonicNumber) {
                                        let harmonicIndex = i * harmonicNumber
                                        if harmonicIndex < count {
                                                workspace[i] += weight * magnitudes[harmonicIndex]
                                        }
                                }
                        }
                }
                
                // 5) Find the peak in the partial HPS result
                let validCount = count / max(harmonicProfile.count, 1)
                var maxValue: Float = -Float.infinity
                var maxIndex: vDSP_Length = 0
                vDSP_maxvi(workspace, 1, &maxValue, &maxIndex, vDSP_Length(validCount))
                let fundamental = Float(maxIndex) * sampleRate / Float(count * 2)
                
                let hpsResult = Array(UnsafeBufferPointer(start: workspace, count: validCount))
                return (fundamental, hpsResult)
        }
}

final class FFTProcessor {
        let fftSize: Int
        let halfSize: Int
        private let log2n: vDSP_Length
        
        // FFT setup
        private let fftSetup: FFTSetup
        
        // Split complex buffers
        private let splitReal: UnsafeMutablePointer<Float>
        private let splitImag: UnsafeMutablePointer<Float>
        private var splitComplex: DSPSplitComplex
        
        // Temp workspace
        private let tempReal: UnsafeMutablePointer<Float>
        private let tempImag: UnsafeMutablePointer<Float>
        private var tempSplit: DSPSplitComplex
        
        // Processing buffers
        let windowBuffer: UnsafeMutablePointer<Float>
        let windowedBuffer: UnsafeMutablePointer<Float>
        let magnitudeBuffer: UnsafeMutablePointer<Float>
        let frequencyBuffer: UnsafeMutablePointer<Float>
        
        init(fftSize: Int) {
                self.fftSize = fftSize
                self.halfSize = fftSize / 2
                self.log2n = vDSP_Length(log2(Float(fftSize)))
                
                // Create FFT setup
                guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else {
                        fatalError("Failed to create FFT setup")
                }
                self.fftSetup = setup
                
                // Allocate split complex
                self.splitReal = UnsafeMutablePointer<Float>.allocate(capacity: halfSize)
                self.splitImag = UnsafeMutablePointer<Float>.allocate(capacity: halfSize)
                self.splitReal.initialize(repeating: 0, count: halfSize)
                self.splitImag.initialize(repeating: 0, count: halfSize)
                self.splitComplex = DSPSplitComplex(realp: splitReal, imagp: splitImag)
                
                // Allocate temp workspace
                self.tempReal = UnsafeMutablePointer<Float>.allocate(capacity: halfSize)
                self.tempImag = UnsafeMutablePointer<Float>.allocate(capacity: halfSize)
                self.tempReal.initialize(repeating: 0, count: halfSize)
                self.tempImag.initialize(repeating: 0, count: halfSize)
                self.tempSplit = DSPSplitComplex(realp: tempReal, imagp: tempImag)
                
                // Allocate processing buffers
                self.windowBuffer = UnsafeMutablePointer<Float>.allocate(capacity: fftSize)
                self.windowedBuffer = UnsafeMutablePointer<Float>.allocate(capacity: fftSize)
                self.magnitudeBuffer = UnsafeMutablePointer<Float>.allocate(capacity: halfSize)
                self.frequencyBuffer = UnsafeMutablePointer<Float>.allocate(capacity: halfSize)
                
                self.magnitudeBuffer.initialize(repeating: 0, count: halfSize)
                self.frequencyBuffer.initialize(repeating: 0, count: halfSize)
        }
        
        deinit {
                vDSP_destroy_fftsetup(fftSetup)
                splitReal.deallocate()
                splitImag.deallocate()
                tempReal.deallocate()
                tempImag.deallocate()
                windowBuffer.deallocate()
                windowedBuffer.deallocate()
                magnitudeBuffer.deallocate()
                frequencyBuffer.deallocate()
        }
        
        func initializeBlackmanHarrisWindow() {
                let a0: Float = 0.35875
                let a1: Float = 0.48829
                let a2: Float = 0.14128
                let a3: Float = 0.01168
                
                for i in 0..<fftSize {
                        let n = Float(i)
                        let N = Float(fftSize - 1)
                        let term1 = a1 * cos(2.0 * .pi * n / N)
                        let term2 = a2 * cos(4.0 * .pi * n / N)
                        let term3 = a3 * cos(6.0 * .pi * n / N)
                        windowBuffer[i] = a0 - term1 + term2 - term3
                }
        }
        
        func initializeFrequencies(sampleRate: Float) {
                let binWidth = sampleRate / Float(fftSize)
                for i in 0..<halfSize {
                        frequencyBuffer[i] = Float(i) * binWidth // 1024 * (22050 / 2048)
                }
        }
        
        func performFFT(input: UnsafePointer<Float>, applyWindow: Bool = true) {
                // Apply window if requested
                if applyWindow {
                        vDSP_vmul(input, 1, windowBuffer, 1, windowedBuffer, 1, vDSP_Length(fftSize))
                } else {
                        memcpy(windowedBuffer, input, fftSize * MemoryLayout<Float>.size)
                }
                
                // Pack real data into split complex
                windowedBuffer.withMemoryRebound(to: DSPComplex.self, capacity: halfSize) { complexPtr in
                        vDSP_ctoz(complexPtr, 2, &splitComplex, 1, vDSP_Length(halfSize))
                }
                
                // Forward FFT
                vDSP_fft_zript(
                        fftSetup,
                        &splitComplex,
                        1,
                        &tempSplit,
                        log2n,
                        FFTDirection(FFT_FORWARD)
                )
                
                // Compute magnitudes
                vDSP_zvmags(&splitComplex, 1, magnitudeBuffer, 1, vDSP_Length(halfSize))
                
                // Scale by 2/N
                var scaleFactor: Float = 2.0 / Float(fftSize)
                vDSP_vsmul(magnitudeBuffer, 1, &scaleFactor, magnitudeBuffer, 1, vDSP_Length(halfSize))
        }
        
        func convertMagnitudesToDB() {
                var floorDB: Float = 1e-10
                var ceilingDB: Float = .greatestFiniteMagnitude
                vDSP_vclip(magnitudeBuffer, 1, &floorDB, &ceilingDB, magnitudeBuffer, 1, vDSP_Length(halfSize))
                
                var reference: Float = 1.0
                vDSP_vdbcon(magnitudeBuffer, 1, &reference, magnitudeBuffer, 1, vDSP_Length(halfSize), 1)
        }
}


final class NoiseFloorEstimator {
        private let store: TuningParameterStore
        private let halfSize: Int
        private let fftSize: Int
        private let currentNoiseFloor: UnsafeMutablePointer<Float>
        private let previousNoiseFloor: UnsafeMutablePointer<Float>
        private let tempNoiseFloor: UnsafeMutablePointer<Float>
        private let qrResultBuffer: UnsafeMutablePointer<Float>
        private let qrTvBuffer: UnsafeMutablePointer<Float>
        
        private var isFirstRun = true
        
        init(store: TuningParameterStore) {
                self.store = store
                self.fftSize = store.fftSize
                self.halfSize = fftSize / 2
                
                // Allocate buffers
                self.currentNoiseFloor = UnsafeMutablePointer<Float>.allocate(capacity: halfSize)
                self.previousNoiseFloor = UnsafeMutablePointer<Float>.allocate(capacity: halfSize)
                self.tempNoiseFloor = UnsafeMutablePointer<Float>.allocate(capacity: halfSize)
                self.qrResultBuffer = UnsafeMutablePointer<Float>.allocate(capacity: halfSize)
                self.qrTvBuffer = UnsafeMutablePointer<Float>.allocate(capacity: halfSize)
                
                // Initialize to -60 dB
                currentNoiseFloor.initialize(repeating: -60, count: halfSize)
                previousNoiseFloor.initialize(repeating: -60, count: halfSize)
                tempNoiseFloor.initialize(repeating: -60, count: halfSize)
                qrResultBuffer.initialize(repeating: 0, count: halfSize)
                qrTvBuffer.initialize(repeating: 0, count: halfSize)
        }
        
        deinit {
                currentNoiseFloor.deallocate()
                previousNoiseFloor.deallocate()
                tempNoiseFloor.deallocate()
                qrResultBuffer.deallocate()
                qrTvBuffer.deallocate()
        }
        
        func estimateNoiseFloor(magnitudesDB: UnsafePointer<Float>,
                                frequencies: UnsafePointer<Float>) -> UnsafePointer<Float> {
                if isFirstRun {
                        initializeNoiseFloor(firstMagnitudeSpectrum: magnitudesDB, count: halfSize)
                        isFirstRun = false
                }
                
                fitNoiseFloor(
                        magnitudesDB: magnitudesDB,
                        frequencies: frequencies,
                        count: halfSize
                )
                
                // Apply temporal smoothing using alpha from store
                let alpha = store.noiseFloorAlpha
                var alphaVar = alpha
                var oneMinusAlpha: Float = 1 - alpha
                vDSP_vsmul(currentNoiseFloor, 1, &alphaVar, tempNoiseFloor, 1, vDSP_Length(halfSize))
                vDSP_vsmul(previousNoiseFloor, 1, &oneMinusAlpha, previousNoiseFloor, 1, vDSP_Length(halfSize))
                vDSP_vadd(tempNoiseFloor, 1, previousNoiseFloor, 1, currentNoiseFloor, 1, vDSP_Length(halfSize))
                memcpy(previousNoiseFloor, currentNoiseFloor, halfSize * MemoryLayout<Float>.size)
                
                return UnsafePointer(currentNoiseFloor)
        }
        
        // MARK: - Fit Noise Floor
        private func fitNoiseFloor(magnitudesDB: UnsafePointer<Float>,
                                   frequencies: UnsafePointer<Float>,
                                   count: Int) {
                
                switch store.noiseMethod {
                case .quantileRegression:
                        fitNoiseFloorQuantile(
                                magnitudesDB: magnitudesDB,
                                output: currentNoiseFloor,
                                count: count,
                                quantile: store.noiseQuantile
                        )
                }
                
                // Apply threshold offset in-place
                var offset = store.noiseThresholdOffset
                vDSP_vsadd(currentNoiseFloor, 1, &offset, currentNoiseFloor, 1, vDSP_Length(count))
        }
        
        // MARK: - Fit Noise Floor Quantile
        private func fitNoiseFloorQuantile(magnitudesDB: UnsafePointer<Float>,
                                           output: UnsafeMutablePointer<Float>,
                                           count: Int,
                                           quantile: Float) {
                let maxIterations = store.noiseFloorMaxIterations
                let convergenceThreshold = store.noiseFloorConvergenceThreshold
                let bandwidthSemitones = store.noiseFloorBandwidthSemitones
                let lambda = store.noiseFloorLambda
                
                // Copy previous noise floor as starting point
                memcpy(tempNoiseFloor, previousNoiseFloor, count * MemoryLayout<Float>.size)
                
                // Iterative quantile regression
                for _ in 0..<maxIterations {
                        // Copy current state
                        memcpy(output, tempNoiseFloor, count * MemoryLayout<Float>.size)
                        
                        // Perform quantile regression step
                        quantileRegressionStepMusical(
                                data: magnitudesDB,
                                current: output,
                                output: tempNoiseFloor,
                                count: count,
                                quantile: quantile,
                                lambda: lambda,
                                bandwidthSemitones: bandwidthSemitones
                        )
                        
                        // Check convergence
                        var change: Float = 0
                        vDSP_vsub(output, 1, tempNoiseFloor, 1, qrResultBuffer, 1, vDSP_Length(count))
                        vDSP_vabs(qrResultBuffer, 1, qrResultBuffer, 1, vDSP_Length(count))
                        vDSP_maxv(qrResultBuffer, 1, &change, vDSP_Length(count))
                        
                        if change < convergenceThreshold {
                                break
                        }
                }
                
                // Final smoothing
                gaussianSmoothMusical(tempNoiseFloor, output: output, count: count, bandwidthSemitones: bandwidthSemitones / 2)
        }
        
        // MARK: - Quantile Regression with Musical Bandwidth
        private func quantileRegressionStepMusical(data: UnsafePointer<Float>,
                                                   current: UnsafeMutablePointer<Float>,
                                                   output: UnsafeMutablePointer<Float>,
                                                   count: Int,
                                                   quantile: Float,
                                                   lambda: Float,
                                                   bandwidthSemitones: Float) {
                let sampleRate = Float(store.audioSampleRate)
                let binWidth = sampleRate / Float(fftSize)
                let stepSize = Float(0.6) //store.noiseFloorStepSize // Add to store if needed, or use fixed 0.6
                
                // Compute subgradients for quantile loss
                for i in 0..<count {
                        let residual = data[i] - current[i]
                        let subgradient: Float
                        
                        if residual > 0 {
                                subgradient = quantile
                        } else if residual < 0 {
                                subgradient = quantile - 1
                        } else {
                                subgradient = 0
                        }
                        
                        // Update with gradient descent step
                        qrResultBuffer[i] = current[i] + stepSize * subgradient
                }
                
                // Apply total variation regularization
                let tvIterations = 3 // store.noiseFloorTVIterations // Add to store if needed, or use fixed 3
                for _ in 0..<tvIterations {
                        memcpy(qrTvBuffer, qrResultBuffer, count * MemoryLayout<Float>.size)
                        
                        for i in 1..<(count-1) {
                                let centerFreq = Float(i) * binWidth
                                
                                let freqWeight = centerFreq > 20 ? log10(centerFreq / 20) + 1 : 1
                                let adjustedLambda = lambda / freqWeight
                                
                                let diff1 = qrResultBuffer[i] - qrResultBuffer[i-1]
                                let diff2 = qrResultBuffer[i+1] - qrResultBuffer[i]
                                let tvGrad = sign(diff1) - sign(diff2)
                                qrTvBuffer[i] = qrResultBuffer[i] - adjustedLambda * tvGrad
                        }
                        memcpy(qrResultBuffer, qrTvBuffer, count * MemoryLayout<Float>.size)
                }
                
                // Ensure noise floor doesn't exceed data
                vDSP_vmin(qrResultBuffer, 1, data, 1, output, 1, vDSP_Length(count))
        }
        
        // MARK: - Gaussian Smooth with Musical Bandwidth
        private func gaussianSmoothMusical(_ data: UnsafeMutablePointer<Float>,
                                           output: UnsafeMutablePointer<Float>,
                                           count: Int,
                                           bandwidthSemitones: Float) {
                let sampleRate = Float(store.audioSampleRate)
                let binWidth = sampleRate / Float(fftSize)
                let sigmaFactor = 1.0//store.noiseFloorSigmaFactor // Add to store if needed, or use fixed 1.0
                
                for i in 0..<count {
                        let centerFreq = Float(i) * binWidth
                        
                        // Skip DC and very low frequencies
                        if centerFreq < 20 {
                                output[i] = data[i]
                                continue
                        }
                        
                        // Calculate frequency range for the musical bandwidth
                        let semitoneRatio = pow(2.0, bandwidthSemitones / 12.0)
                        let lowerFreq = centerFreq / pow(semitoneRatio, 0.5)
                        let upperFreq = centerFreq * pow(semitoneRatio, 0.5)
                        
                        // Convert to bin indices
                        let lowerBin = max(0, Int(lowerFreq / binWidth))
                        let upperBin = min(count - 1, Int(upperFreq / binWidth))
                        
                        // Create Gaussian weights
                        let windowSize = upperBin - lowerBin + 1
                        let sigma = Float(windowSize) / Float(sigmaFactor)
                        
                        var sum: Float = 0
                        var weightSum: Float = 0
                        
                        for j in lowerBin...upperBin {
                                let distance = Float(j - i)
                                let weight = exp(-(distance * distance) / (2 * sigma * sigma))
                                sum += data[j] * weight
                                weightSum += weight
                        }
                        
                        output[i] = sum / weightSum
                }
        }
        
        private func initializeNoiseFloor(firstMagnitudeSpectrum: UnsafePointer<Float>, count: Int) {
                // Copy the magnitude spectrum to the noise floor buffers
                memcpy(currentNoiseFloor, firstMagnitudeSpectrum, count * MemoryLayout<Float>.size)
                memcpy(previousNoiseFloor, firstMagnitudeSpectrum, count * MemoryLayout<Float>.size)
                
                // Apply heavy smoothing multiple times to get a good initial estimate
                let initialSmoothingPasses = 10 //store.noiseFloorInitialSmoothingPasses // Add to store if needed
                for _ in 0..<initialSmoothingPasses {
                        // Apply moving minimum to remove peaks
                        movingMinimumInPlace(currentNoiseFloor, output: tempNoiseFloor, count: count, windowSize: 20)
                        memcpy(currentNoiseFloor, tempNoiseFloor, count * MemoryLayout<Float>.size)
                        
                        // Apply gaussian smoothing with wide bandwidth
                        gaussianSmoothMusical(currentNoiseFloor, output: tempNoiseFloor, count: count, bandwidthSemitones: 12.0)
                        memcpy(currentNoiseFloor, tempNoiseFloor, count * MemoryLayout<Float>.size)
                }
                
                // Subtract a few dB to ensure we start below the signal
                var offset = store.noiseThresholdOffset
                vDSP_vsadd(currentNoiseFloor, 1, &offset, currentNoiseFloor, 1, vDSP_Length(count))
                
                // Copy to previousNoiseFloor so both start the same
                memcpy(previousNoiseFloor, currentNoiseFloor, count * MemoryLayout<Float>.size)
        }
        
        // Helper function for moving minimum
        private func movingMinimumInPlace(_ data: UnsafeMutablePointer<Float>,
                                          output: UnsafeMutablePointer<Float>,
                                          count: Int,
                                          windowSize: Int) {
                for i in 0..<count {
                        let start = max(0, i - windowSize/2)
                        let end = min(count, i + windowSize/2 + 1)
                        
                        var minValue: Float = Float.infinity
                        for j in start..<end {
                                if data[j] < minValue {
                                        minValue = data[j]
                                }
                        }
                        output[i] = minValue
                }
        }
        
        // MARK: - Sign
        private func sign(_ x: Float) -> Float {
                if x > 0 { return 1 }
                else if x < 0 { return -1 }
                else { return 0 }
        }
}




// MARK: - Result Types
struct StudyResult {
        let originalSpectrum: [Float]
        let noiseFloor: [Float]
        let denoisedSpectrum: [Float]
        let frequencies: [Float]
        let hpsSpectrum: [Float]
        let hpsFundamental: Float
        let musicPeaks: [Double]  // Add MUSIC results
        let musicSpectrum: [Double]     // Add MUSIC pseudospectrum
        let musicGrid: [Double]
        let timestamp: Date
        let processingTime: TimeInterval
}

// MARK: - Simplified Study Class
final class Study: ObservableObject {
        // Core components
        private let audioProcessor: AudioProcessor
        private let store: TuningParameterStore
        private let studyQueue = DispatchQueue(label: "com.app.study", qos: .userInitiated)
        
        // FFT processors
        private let mainFFT: FFTProcessor
        private let hpsProcessor: HPSProcessor
        private let noiseFloorEstimator: NoiseFloorEstimator
        private var musicProcessor: MUSIC?
        private let musicSourceCount = 2
        private let musicSubarrayLength = 40
        
        private let denoisedBuffer: UnsafeMutablePointer<Float>
        private let qrResultBuffer: UnsafeMutablePointer<Float>
        private let qrTvBuffer: UnsafeMutablePointer<Float>
        
        // State
        private var isRunning = false
        private var isFirstRun = true
        
        // Published results
        @Published var targetOriginalSpectrum: [Float] = []
        @Published var targetNoiseFloor: [Float] = []
        @Published var targetDenoisedSpectrum: [Float] = []
        @Published var targetFrequencies: [Float] = []
        @Published var targetHPSSpectrum: [Float] = []
        @Published var targetHPSFundamental: Float = 0
        @Published var zoomSpectrum: [Float] = []
        @Published var zoomFrequencies: [Float] = []
        
        @Published var musicPeaks: [Double] = []
        @Published var musicSpectrum: [Double] = []
        @Published var musicGrid: [Double] = []
        
        init(audioProcessor: AudioProcessor, store: TuningParameterStore) {
                self.audioProcessor = audioProcessor
                self.store = store
                
                let fftSize = store.fftSize
                let halfSize = fftSize / 2
                
                // Initialize FFT processors
                self.mainFFT = FFTProcessor(fftSize: fftSize)

                self.hpsProcessor = HPSProcessor(
                        spectrumSize: halfSize,
                        harmonicProfile: [0.3, 0.3, 0.3]
                )
                self.noiseFloorEstimator = NoiseFloorEstimator(store: self.store)
                
                // Initialize windows and frequencies
                mainFFT.initializeBlackmanHarrisWindow()
                mainFFT.initializeFrequencies(sampleRate: Float(store.audioSampleRate))
                
                
                // Allocate processing buffers
                self.denoisedBuffer = UnsafeMutablePointer<Float>.allocate(capacity: halfSize)
                self.qrResultBuffer = UnsafeMutablePointer<Float>.allocate(capacity: halfSize)
                self.qrTvBuffer = UnsafeMutablePointer<Float>.allocate(capacity: halfSize)
                
                denoisedBuffer.initialize(repeating: 0, count: halfSize)
                qrResultBuffer.initialize(repeating: 0, count: halfSize)
                qrTvBuffer.initialize(repeating: 0, count: halfSize)
                
                self.musicProcessor = MUSIC(
                        store: store,
                        sourceCount: musicSourceCount,
                        subarrayLength: musicSubarrayLength,
                        snapshotCount: 50  // Default snapshot count
                )
        }
        
        deinit {
                isRunning = false
                denoisedBuffer.deallocate()
                qrResultBuffer.deallocate()
                qrTvBuffer.deallocate()
        }
        
        // MARK: - Start / Stop
        func start() {
                guard !isRunning else { return }
                isRunning = true
                
                studyQueue.async { [weak self] in
                        self?.continuousStudyLoop()
                }
        }
        
        func stop() {
                isRunning = false
        }
        

        
        // MARK: - Main Analysis
        private func perform(audioWindow: [Float]) -> StudyResult {
                let overallStart = CFAbsoluteTimeGetCurrent()
                
                // Perform main FFT
                audioWindow.withUnsafeBufferPointer { audioPtr in
                        mainFFT.performFFT(input: audioPtr.baseAddress!)
                }
                mainFFT.convertMagnitudesToDB()
                
                // Estimate noise floor
                let noiseFloor = noiseFloorEstimator.estimateNoiseFloor(
                        magnitudesDB: mainFFT.magnitudeBuffer,
                        frequencies: mainFFT.frequencyBuffer,
                )
                
                // Denoise spectrum
                denoiseSpectrum(
                        magnitudesDB: mainFFT.magnitudeBuffer,
                        noiseFloorDB: noiseFloor,
                        output: denoisedBuffer,
                        count: mainFFT.halfSize
                )
                
                // Compute HPS
                let (hpsFundamental, hpsSpectrum) = hpsProcessor.computeHPS(
                        magnitudes: denoisedBuffer,
                        count: mainFFT.halfSize,
                        sampleRate: Float(store.audioSampleRate)
                )
                
                // Perform MUSIC analysis
                let (musicPeaks, musicSpec, musicGrid) = performMUSICAnalysis(audioWindow: audioWindow)
                
                // Package and return results
                return StudyResult(
                        originalSpectrum: Array(UnsafeBufferPointer(start: mainFFT.magnitudeBuffer, count: mainFFT.halfSize)),
                        noiseFloor: Array(UnsafeBufferPointer(start: noiseFloor, count: mainFFT.halfSize)),
                        denoisedSpectrum: Array(UnsafeBufferPointer(start: denoisedBuffer, count: mainFFT.halfSize)),
                        frequencies: Array(UnsafeBufferPointer(start: mainFFT.frequencyBuffer, count: mainFFT.halfSize)),
                        hpsSpectrum: hpsSpectrum,
                        hpsFundamental: hpsFundamental,
                        musicPeaks: musicPeaks,
                        musicSpectrum: musicSpec,
                        musicGrid: musicGrid,
                        timestamp: Date(),
                        processingTime: CFAbsoluteTimeGetCurrent() - overallStart
                )
        }
        private func performMUSICAnalysis(audioWindow: [Float]) -> ([Double], [Double], [Double]) {
                guard var music = musicProcessor else {
                        return ([], [], [])
                }
                
                // Update frequency grid if target has changed
                let currentTargetFreq = Double(store.targetFrequency())
                music.updateFrequencyGrid(targetFrequency: currentTargetFreq)
                
                // Update snapshot matrix with current audio window
                music.updateSnapshotMatrix(audioWindow: audioWindow)
                
                // Compute pseudospectrum and estimate frequencies
                let spectrum = music.pseudospectrum()
                let estimatedPeaks = music.estimatePeaks()
                
                // Store the updated processor
                musicProcessor = music
                
                // Note: music.freqGrid is already in normalized frequency (radians/sample)
                // The conversion to Hz happens in StudyGraphView.updateTargets()
                return (estimatedPeaks, spectrum, music.freqGrid)
        }

        // MARK: - Separate Denoising Function (moved out of NoiseFloorEstimator)
        func denoiseSpectrum(magnitudesDB: UnsafePointer<Float>,
                             noiseFloorDB: UnsafePointer<Float>,
                             output: UnsafeMutablePointer<Float>,
                             count: Int) {
                // Subtract noise floor from signal
                vDSP_vsub(noiseFloorDB, 1, magnitudesDB, 1, output, 1, vDSP_Length(count))
                
                // Clip negative values to 0
                var zero: Float = 0
                var ceiling = Float.greatestFiniteMagnitude
                vDSP_vclip(output, 1, &zero, &ceiling, output, 1, vDSP_Length(count))
        }

        private func continuousStudyLoop() {
                while isRunning {
                        autoreleasepool {
                                guard let audioWindow = audioProcessor.getWindow(size: store.fftSize) else {
                                        Thread.sleep(forTimeInterval: 0.001)
                                        return
                                }
                                
                                let result = perform(audioWindow: audioWindow)
                                
                                DispatchQueue.main.async { [weak self] in
                                        self?.targetOriginalSpectrum = result.originalSpectrum
                                        self?.targetNoiseFloor = result.noiseFloor
                                        self?.targetDenoisedSpectrum = result.denoisedSpectrum
                                        self?.targetFrequencies = result.frequencies
                                        self?.targetHPSSpectrum = result.hpsSpectrum
                                        self?.targetHPSFundamental = result.hpsFundamental
                                        self?.musicPeaks = result.musicPeaks
                                        self?.musicSpectrum = result.musicSpectrum
                                        self?.musicGrid = result.musicGrid
                                }
                        }
                        Thread.sleep(forTimeInterval: 0.005) // ~200 Hz update
                }
        }
        
        private func updatePublishedResults(_ result: StudyResult) {
                targetOriginalSpectrum = result.originalSpectrum
                targetNoiseFloor = result.noiseFloor
                targetDenoisedSpectrum = result.denoisedSpectrum
                targetFrequencies = result.frequencies
                targetHPSSpectrum = result.hpsSpectrum
                targetHPSFundamental = result.hpsFundamental
                
        }
}
