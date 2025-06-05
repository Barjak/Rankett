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


// MARK: - Result Types
struct StudyResult {
        let originalSpectrum: [Float]
        let noiseFloor: [Float]
        let denoisedSpectrum: [Float]
        let frequencies: [Float]
        let hpsSpectrum: [Float]
        let hpsFundamental: Float
        let timestamp: Date
        let processingTime: TimeInterval
}


// MARK: - Study Analysis Class
final class Study: ObservableObject {
        // Inputs
        private let audioProcessor: AudioProcessor
        private let store: TuningParameterStore
        
        // Queue
        private let studyQueue = DispatchQueue(label: "com.app.study", qos: .userInitiated)
        private var isRunning = false
        private var isFirstRun = true
        
        // HPS
        private let hpsProcessor: HPSProcessor
        
        // FFT configuration
        private let fftSize: Int
        private let halfSize: Int
        private let log2n: vDSP_Length
        
        // —— For “in-place real FFT” (vDSP_fft_zript) ——
        private let fftSetup: FFTSetup                    // C‐API FFT setup
        private let splitReal: UnsafeMutablePointer<Float> // real part of main SPLIT‐CMPLX (length=halfSize)
        private let splitImag: UnsafeMutablePointer<Float> // imag part of main SPLIT‐CMPLX (length=halfSize)
        private var splitComplex: DSPSplitComplex         // (wraps realp & imagp)
        
        private let tempReal: UnsafeMutablePointer<Float>  // workspace real (length=halfSize)
        private let tempImag: UnsafeMutablePointer<Float>  // workspace imag (length=halfSize)
        private var tempSplit: DSPSplitComplex             // (wraps tempReal & tempImag)
        
        // Buffers for windowing & magnitude
        private let windowBuffer:        UnsafeMutablePointer<Float> // length = fftSize
        private let windowedAudioBuffer: UnsafeMutablePointer<Float> // length = fftSize
        private let magnitudeBuffer:     UnsafeMutablePointer<Float> // length = halfSize
        
        // Buffers for denoising & frequencies
        private let denoisedBuffer: UnsafeMutablePointer<Float> // length = halfSize
        private let frequencyBuffer: UnsafeMutablePointer<Float> // length = halfSize
        
        // Noise-floor tracking
        private let currentNoiseFloor:  UnsafeMutablePointer<Float> // length = halfSize
        private let previousNoiseFloor: UnsafeMutablePointer<Float> // length = halfSize
        private let tempNoiseFloor:     UnsafeMutablePointer<Float> // length = halfSize
        private let noiseFloorAlpha: Float = 1.0
        
        // Buffers for quantile regression
        private let qrResultBuffer: UnsafeMutablePointer<Float> // length = halfSize
        private let qrTvBuffer:     UnsafeMutablePointer<Float> // length = halfSize
        
        // Published (for SwiftUI view binding)
        @Published var targetOriginalSpectrum: [Float] = []
        @Published var targetNoiseFloor:       [Float] = []
        @Published var targetDenoisedSpectrum: [Float] = []
        @Published var targetFrequencies:      [Float] = []
        @Published var targetHPSSpectrum:      [Float] = []
        @Published var targetHPSFundamental:   Float     = 0
        
        //--------------------------------------------------------------------------------
        init(audioProcessor: AudioProcessor, store: TuningParameterStore) {
                self.audioProcessor = audioProcessor
                self.store = store
                self.fftSize = store.fftSize
                self.halfSize = fftSize / 2
                self.log2n = vDSP_Length(log2(Float(fftSize)))
                self.hpsProcessor = HPSProcessor(spectrumSize: halfSize, harmonicProfile: [1.0])
                
                // 1) Create a C‐API FFT setup for “real-to-complex (in-place)”
                guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else {
                        fatalError("Failed to create FFT setup")
                }
                self.fftSetup = setup
                
                // 2) Allocate the main DSPSplitComplex (this is where we’ll pack and overwrite in-place)
                self.splitReal = UnsafeMutablePointer<Float>.allocate(capacity: halfSize)
                self.splitImag = UnsafeMutablePointer<Float>.allocate(capacity: halfSize)
                // Always zero the imaginary part initially
                self.splitImag.initialize(repeating: 0, count: halfSize)
                self.splitReal.initialize(repeating: 0, count: halfSize)
                self.splitComplex = DSPSplitComplex(realp: splitReal, imagp: splitImag)
                
                // 3) Allocate the “temp” DSPSplitComplex (workspace) for zRIP:
                self.tempReal = UnsafeMutablePointer<Float>.allocate(capacity: halfSize)
                self.tempImag = UnsafeMutablePointer<Float>.allocate(capacity: halfSize)
                self.tempReal.initialize(repeating: 0, count: halfSize)
                self.tempImag.initialize(repeating: 0, count: halfSize)
                self.tempSplit = DSPSplitComplex(realp: tempReal, imagp: tempImag)
                
                // 4) Allocate window + windowed‐audio buffers
                self.windowBuffer        = UnsafeMutablePointer<Float>.allocate(capacity: fftSize)
                self.windowedAudioBuffer = UnsafeMutablePointer<Float>.allocate(capacity: fftSize)
                
                // 5) Allocate a buffer for the magnitude (halfSize)
                self.magnitudeBuffer = UnsafeMutablePointer<Float>.allocate(capacity: halfSize)
                self.magnitudeBuffer.initialize(repeating: 0, count: halfSize)
                
                // 6) Allocate “denoised” + “frequency” + noise‐floor + QR buffers
                self.denoisedBuffer     = UnsafeMutablePointer<Float>.allocate(capacity: halfSize)
                self.frequencyBuffer    = UnsafeMutablePointer<Float>.allocate(capacity: halfSize)
                self.currentNoiseFloor  = UnsafeMutablePointer<Float>.allocate(capacity: halfSize)
                self.previousNoiseFloor = UnsafeMutablePointer<Float>.allocate(capacity: halfSize)
                self.tempNoiseFloor     = UnsafeMutablePointer<Float>.allocate(capacity: halfSize)
                self.qrResultBuffer     = UnsafeMutablePointer<Float>.allocate(capacity: halfSize)
                self.qrTvBuffer         = UnsafeMutablePointer<Float>.allocate(capacity: halfSize)
                
                // Initialize frequencyBuffer once
                generateFrequencyArray(into: frequencyBuffer, count: halfSize, sampleRate: Float(store.audioSampleRate))
                
                // Initialize window (Blackman-Harris)
                generateBlackmanHarrisWindow(into: windowBuffer, size: fftSize)
                
                // Initialize noise‐floor arrays to a low dB value (e.g. –60 dB)
                currentNoiseFloor.initialize(repeating: -60, count: halfSize)
                previousNoiseFloor.initialize(repeating: -60, count: halfSize)
                tempNoiseFloor.initialize(repeating: -60, count: halfSize)
                
                // Zero out other buffers
                denoisedBuffer.initialize(repeating: 0, count: halfSize)
                qrResultBuffer.initialize(repeating: 0, count: halfSize)
                qrTvBuffer.initialize(repeating: 0, count: halfSize)
        }
        
        deinit {
                isRunning = false
                
                // Destroy the FFT setup
                vDSP_destroy_fftsetup(fftSetup)
                
                // Deallocate every pointer we allocated
                splitReal.deallocate()
                splitImag.deallocate()
                
                tempReal.deallocate()
                tempImag.deallocate()
                
                windowBuffer.deallocate()
                windowedAudioBuffer.deallocate()
                magnitudeBuffer.deallocate()
                
                denoisedBuffer.deallocate()
                frequencyBuffer.deallocate()
                
                currentNoiseFloor.deallocate()
                previousNoiseFloor.deallocate()
                tempNoiseFloor.deallocate()
                
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
                                        self?.targetNoiseFloor       = result.noiseFloor
                                        self?.targetDenoisedSpectrum = result.denoisedSpectrum
                                        self?.targetFrequencies      = result.frequencies
                                        self?.targetHPSSpectrum      = result.hpsSpectrum
                                        self?.targetHPSFundamental   = result.hpsFundamental
                                }
                        }
                        Thread.sleep(forTimeInterval: 0.005) // ~200 Hz update
                }
        }
        
        // MARK: - Main Analysis
        private func perform(audioWindow: [Float]) -> StudyResult {
                let overallStart = CFAbsoluteTimeGetCurrent()
                
                // 1️⃣ Apply window (time‐domain multiply)
                audioWindow.withUnsafeBufferPointer { audioPtr in
                        vDSP_vmul(
                                audioPtr.baseAddress!, 1,
                                windowBuffer,           1,
                                windowedAudioBuffer,    1,
                                vDSP_Length(fftSize)
                        )
                }
                
                // 2️⃣ Pack real data → splitComplex (even‐odd) using vDSP_ctoz(stride:2)
                windowedAudioBuffer.withMemoryRebound(to: DSPComplex.self, capacity: halfSize) { complexPtr in
                        vDSP_ctoz(
                                complexPtr,   2,              // stride=2: (x[2*i], x[2*i+1]) → DSPComplex
                                &splitComplex, 1,             // destination, stride=1
                                vDSP_Length(halfSize)
                        )
                }
                // Now splitComplex.realp[i] = windowedAudioBuffer[2*i]
                //     splitComplex.imagp[i] = windowedAudioBuffer[2*i + 1]
                
                // 3️⃣ Forward real FFT → in-place (use tempSplit as workspace)
                vDSP_fft_zript(
                        fftSetup,
                        &splitComplex,    // input/output (packed real → packed spectrum)
                        1,                // stride = 1
                        &tempSplit,       // workspace (realp/imagp each length = halfSize)
                        log2n,
                        FFTDirection(FFT_FORWARD)
                )
                
                // 4️⃣ Compute |X[k]|^2 for each bin (packed length = halfSize)
                vDSP_zvmags(
                        &splitComplex,    // splitComplex now contains packed frequency bins
                        1,                // stride = 1
                        magnitudeBuffer,  // output array = |real + i*imag|^2
                        1,
                        vDSP_Length(halfSize)
                )
                
                // 5️⃣ Scale magnitudes by (2/fftSize)
                var scaleFactor: Float = 2.0 / Float(fftSize)
                vDSP_vsmul(
                        magnitudeBuffer, 1,
                        &scaleFactor,
                        magnitudeBuffer, 1,
                        vDSP_Length(halfSize)
                )
                
                // 6️⃣ Convert to dB
                var floorDB: Float   = 1e-10
                var ceilingDB: Float = .greatestFiniteMagnitude
                vDSP_vclip(
                        magnitudeBuffer, 1,
                        &floorDB, &ceilingDB,
                        magnitudeBuffer, 1,
                        vDSP_Length(halfSize)
                )
                var reference: Float = 1.0
                vDSP_vdbcon(
                        magnitudeBuffer, 1,
                        &reference,
                        magnitudeBuffer, 1,
                        vDSP_Length(halfSize),
                        1 // use 10*log10(x) style
                )
                
                // 7️⃣ Noise‐floor estimation (quantile regression, etc.)
                if isFirstRun {
                        initializeNoiseFloor(
                                firstMagnitudeSpectrum: magnitudeBuffer,
                                count: halfSize
                        )
                        isFirstRun = false
                }
                fitNoiseFloor(
                        magnitudesDB: magnitudeBuffer,
                        frequencies:  frequencyBuffer,
                        count:        halfSize,
                        store:        store
                )
                var α: Float         = noiseFloorAlpha
                var oneMinusα: Float = 1 - noiseFloorAlpha
                vDSP_vsmul(currentNoiseFloor, 1, &α,           tempNoiseFloor, 1, vDSP_Length(halfSize))
                vDSP_vsmul(previousNoiseFloor, 1, &oneMinusα, previousNoiseFloor, 1, vDSP_Length(halfSize))
                vDSP_vadd(tempNoiseFloor, 1, previousNoiseFloor, 1, currentNoiseFloor, 1, vDSP_Length(halfSize))
                memcpy(previousNoiseFloor, currentNoiseFloor, halfSize * MemoryLayout<Float>.size)
                
                // 8️⃣ Denoise
                denoiseSpectrum(
                        magnitudesDB: magnitudeBuffer,
                        noiseFloorDB: currentNoiseFloor,
                        output:       denoisedBuffer,
                        count:        halfSize
                )
                
                // 9️⃣ Harmonic Product Spectrum
                let (hpsFundamental, hpsSpectrum) = hpsProcessor.computeHPS(
                        magnitudes: denoisedBuffer,
                        count:      halfSize,
                        sampleRate: Float(store.audioSampleRate)
                )
                
                // 🔟 Package results
                let magnitudesDBArray = Array( UnsafeBufferPointer(start: magnitudeBuffer,  count: halfSize) )
                let noiseFloorArray   = Array( UnsafeBufferPointer(start: currentNoiseFloor, count: halfSize) )
                let denoisedArray     = Array( UnsafeBufferPointer(start: denoisedBuffer,   count: halfSize) )
                let freqsArray        = Array( UnsafeBufferPointer(start: frequencyBuffer,  count: halfSize) )
                
                let processingTime = CFAbsoluteTimeGetCurrent() - overallStart
                
                return StudyResult(
                        originalSpectrum:  magnitudesDBArray,
                        noiseFloor:       noiseFloorArray,
                        denoisedSpectrum: denoisedArray,
                        frequencies:      freqsArray,
                        hpsSpectrum:      hpsSpectrum,
                        hpsFundamental:   hpsFundamental,
                        timestamp:        Date(),
                        processingTime:   processingTime
                )
        }
        
        // MARK: - Generate Frequency Array
        private func generateFrequencyArray(into buffer: UnsafeMutablePointer<Float>, count: Int, sampleRate: Float) {
                let binWidth = sampleRate / Float(count * 2)
                for i in 0..<count {
                        buffer[i] = Float(i) * binWidth
                }
        }
        
        // MARK: - Sign
        private func sign(_ x: Float) -> Float {
                if x > 0 { return 1 }
                else if x < 0 { return -1 }
                else { return 0 }
        }
        
        
        private func generateBlackmanHarrisWindow(into buffer: UnsafeMutablePointer<Float>, size: Int) {
                let a0: Float = 0.35875
                let a1: Float = 0.48829
                let a2: Float = 0.14128
                let a3: Float = 0.01168
                
                for i in 0..<size {
                        let n = Float(i)
                        let N = Float(size - 1)
                        let term1 = a1 * cos(2.0 * .pi * n / N)
                        let term2 = a2 * cos(4.0 * .pi * n / N)
                        let term3 = a3 * cos(6.0 * .pi * n / N)
                        buffer[i] = a0 - term1 + term2 - term3
                }
        }
        
        // MARK: - Fit Noise Floor
        private func fitNoiseFloor(magnitudesDB: UnsafeMutablePointer<Float>,
                                   frequencies: UnsafeMutablePointer<Float>,
                                   count: Int,
                                   store: TuningParameterStore) {
                
                switch store.noiseMethod {
                case .quantileRegression:
                        fitNoiseFloorQuantile(
                                magnitudesDB: magnitudesDB,
                                output: currentNoiseFloor,
                                count: count,
                                quantile: store.noiseQuantile,
                        )
                }
                
                // Apply threshold offset in-place
                var offset = store.noiseThresholdOffset
                vDSP_vsadd(currentNoiseFloor, 1, &offset, currentNoiseFloor, 1, vDSP_Length(count))
        }
        
        // MARK: - Fit Noise Floor Quantile
        private func fitNoiseFloorQuantile(magnitudesDB: UnsafeMutablePointer<Float>,
                                           output: UnsafeMutablePointer<Float>,
                                           count: Int,
                                           quantile: Float) {
                let maxIterations = store.noiseFloorMaxIterations
                let convergenceThreshold: Float = store.noiseFloorConvergenceThreshold
                let bandwidthSemitones: Float = store.noiseFloorBandwidthSemitones
                
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
                                lambda: 10, // TODO: is this redunant?
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
        private func quantileRegressionStepMusical(data: UnsafeMutablePointer<Float>,
                                                   current: UnsafeMutablePointer<Float>,
                                                   output: UnsafeMutablePointer<Float>,
                                                   count: Int,
                                                   quantile: Float,
                                                   lambda: Float,
                                                   bandwidthSemitones: Float) {
                let sampleRate = Float(store.audioSampleRate)
                let binWidth = sampleRate / Float(fftSize)
                
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
                        qrResultBuffer[i] = current[i] + 0.6 * subgradient
                }
                
                // Apply total variation regularization
                for _ in 0..<3 {
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
                        let sigma = Float(windowSize) / 1.0
                        
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
        
        // MARK: - Denoising
        private func denoiseSpectrum(magnitudesDB: UnsafeMutablePointer<Float>,
                                     noiseFloorDB: UnsafeMutablePointer<Float>,
                                     output: UnsafeMutablePointer<Float>,
                                     count: Int) {
                // Subtract noise floor from signal
                vDSP_vsub(noiseFloorDB, 1, magnitudesDB, 1, output, 1, vDSP_Length(count))
                
                // Clip negative values to 0
                var zero: Float = 0
                var ceiling = Float.greatestFiniteMagnitude
                vDSP_vclip(output, 1, &zero, &ceiling, output, 1, vDSP_Length(count))
        }

        private func initializeNoiseFloor(firstMagnitudeSpectrum: UnsafeMutablePointer<Float>, count: Int) {
                // Copy the magnitude spectrum to the noise floor buffers
                memcpy(currentNoiseFloor, firstMagnitudeSpectrum, count * MemoryLayout<Float>.size)
                memcpy(previousNoiseFloor, firstMagnitudeSpectrum, count * MemoryLayout<Float>.size)
                
                // Apply heavy smoothing multiple times to get a good initial estimate
                for _ in 0..<3 {
                        // Apply moving minimum to remove peaks
                        movingMinimumInPlace(currentNoiseFloor, output: tempNoiseFloor, count: count, windowSize: 20)
                        memcpy(currentNoiseFloor, tempNoiseFloor, count * MemoryLayout<Float>.size)
                        
                        // Apply gaussian smoothing with wide bandwidth
                        gaussianSmoothMusical(currentNoiseFloor, output: tempNoiseFloor, count: count, bandwidthSemitones: 12.0)
                        memcpy(currentNoiseFloor, tempNoiseFloor, count * MemoryLayout<Float>.size)
                }
                
                // Subtract a few dB to ensure we start below the signal
                var offset: Float = -3.0
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
}
