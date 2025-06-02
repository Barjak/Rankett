import Foundation
import Accelerate
import CoreML

final class HPSProcessor {
        private let harmonicProfile: [Float]
        private let workspace: UnsafeMutablePointer<Float>
        
        init(spectrumSize: Int, harmonicProfile: [Float] = [1.0, 0.8, 0.6, 0.4, 0.2]) {
                self.harmonicProfile = harmonicProfile
                self.workspace = UnsafeMutablePointer<Float>.allocate(capacity: spectrumSize)
        }
        
        deinit {
                workspace.deallocate()
        }
        
        func computeHPS(magnitudes: UnsafePointer<Float>,
                        count: Int,
                        sampleRate: Float) -> (fundamental: Float, hpsSpectrum: [Float]) {
                // Initialize workspace with the fundamental weighted by first profile value
                if !harmonicProfile.isEmpty {
                        var fundamentalWeight = harmonicProfile[0]
                        vDSP_vsmul(magnitudes, 1, &fundamentalWeight, workspace, 1, vDSP_Length(count))
                } else {
                        memcpy(workspace, magnitudes, count * MemoryLayout<Float>.size)
                }
                
                // Apply weighted harmonic product based on profile
                for (h, weight) in harmonicProfile.enumerated().dropFirst() {
                        let harmonicNumber = h + 2 // Since we dropped first, h=0 means 2nd harmonic
                        
                        if weight > 0 { // Only process non-zero weights
                                for i in 0..<(count / harmonicNumber) {
                                        let harmonicIndex = i * harmonicNumber
                                        if harmonicIndex < count {
                                                // Apply weighted multiplication in log domain (addition)
                                                workspace[i] += weight * magnitudes[harmonicIndex]
                                        }
                                }
                        }
                }
                
                // Find peak in HPS spectrum
                let validCount = count / max(harmonicProfile.count, 1)
                var maxValue: Float = -Float.infinity
                var maxIndex: vDSP_Length = 0
                vDSP_maxvi(workspace, 1, &maxValue, &maxIndex, vDSP_Length(validCount))
                
                let fundamental = Float(maxIndex) * sampleRate / Float(count * 2)
                
                // Create array for return (only valid portion of HPS spectrum)
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

struct Peak {
        let index: Int
        let frequency: Float
        let magnitude: Float
        let prominence: Float
        let leftBase: Int
        let rightBase: Int
}

// MARK: - Study Analysis Class
final class Study: ObservableObject {
        private let audioProcessor: AudioProcessor
        private let config: AnalyzerConfig
        private let studyQueue = DispatchQueue(label: "com.app.study", qos: .userInitiated)
        private var isRunning = false
        private var isFirstRun = true
        
        private let hpsProcessor: HPSProcessor

        
        // Pre-allocated buffers
        private let fftSize: Int
        private let halfSize: Int
        private let fftSetup: vDSP.FFT<DSPSplitComplex>
        private let realBuffer: UnsafeMutablePointer<Float>
        private let imagBuffer: UnsafeMutablePointer<Float>
        private let magnitudeBuffer: UnsafeMutablePointer<Float>
        private var splitComplex: DSPSplitComplex
        
        // Pre-allocated working buffers
        private let denoisedBuffer: UnsafeMutablePointer<Float>
        private let frequencyBuffer: UnsafeMutablePointer<Float>
        
        // Noise floor tracking buffers
        private let currentNoiseFloor: UnsafeMutablePointer<Float>
        private let previousNoiseFloor: UnsafeMutablePointer<Float>
        private let tempNoiseFloor: UnsafeMutablePointer<Float>
        private let noiseFloorAlpha: Float = 1.0
        
        // Buffers for quantile regression
        private let qrResultBuffer: UnsafeMutablePointer<Float>
        private let qrTvBuffer: UnsafeMutablePointer<Float>
        
        // Peak tracking
        private var previousPeakPositions: [Int: (x: Float, y: Float)] = [:]
        private let peakPositionAlpha: Float = 0.7
        
        // Published target buffers for StudyView
        @Published var targetOriginalSpectrum: [Float] = []
        @Published var targetNoiseFloor: [Float] = []
        @Published var targetDenoisedSpectrum: [Float] = []
        @Published var targetFrequencies: [Float] = []
        @Published var targetPeaks: [Peak] = []
        @Published var targetHPSSpectrum: [Float] = []
        @Published var targetHPSFundamental: Float = 0
        
        init(audioProcessor: AudioProcessor, config: AnalyzerConfig) {
                self.audioProcessor = audioProcessor
                self.config = config
                
                
                // Pre-allocate FFT buffers
                self.fftSize = config.fft.size
                self.halfSize = fftSize / 2
                let harmonicProfile: [Float] = [1.0]
                self.hpsProcessor = HPSProcessor(spectrumSize: halfSize, harmonicProfile: harmonicProfile)
                
                
                let log2n = vDSP_Length(log2(Float(fftSize)))
                guard let setup = vDSP.FFT(log2n: log2n, radix: .radix2, ofType: DSPSplitComplex.self) else {
                        fatalError("Failed to create FFT setup")
                }
                self.fftSetup = setup
                
                // Allocate all buffers
                self.realBuffer = UnsafeMutablePointer<Float>.allocate(capacity: halfSize)
                self.imagBuffer = UnsafeMutablePointer<Float>.allocate(capacity: halfSize)
                self.magnitudeBuffer = UnsafeMutablePointer<Float>.allocate(capacity: halfSize)
                self.splitComplex = DSPSplitComplex(realp: realBuffer, imagp: imagBuffer)
                
                self.denoisedBuffer = UnsafeMutablePointer<Float>.allocate(capacity: halfSize)
                self.frequencyBuffer = UnsafeMutablePointer<Float>.allocate(capacity: halfSize)
                
                self.currentNoiseFloor = UnsafeMutablePointer<Float>.allocate(capacity: halfSize)
                self.previousNoiseFloor = UnsafeMutablePointer<Float>.allocate(capacity: halfSize)
                self.tempNoiseFloor = UnsafeMutablePointer<Float>.allocate(capacity: halfSize)
                
                self.qrResultBuffer = UnsafeMutablePointer<Float>.allocate(capacity: halfSize)
                self.qrTvBuffer = UnsafeMutablePointer<Float>.allocate(capacity: halfSize)
                
                // Initialize buffers
                realBuffer.initialize(repeating: 0, count: halfSize)
                imagBuffer.initialize(repeating: 0, count: halfSize)
                magnitudeBuffer.initialize(repeating: 0, count: halfSize)
                denoisedBuffer.initialize(repeating: 0, count: halfSize)
                currentNoiseFloor.initialize(repeating: -60, count: halfSize)  // Start with reasonable noise floor
                previousNoiseFloor.initialize(repeating: -60, count: halfSize)
                tempNoiseFloor.initialize(repeating: -60, count: halfSize)
                qrResultBuffer.initialize(repeating: 0, count: halfSize)
                qrTvBuffer.initialize(repeating: 0, count: halfSize)
                
                // Pre-compute frequency array once
                generateFrequencyArray(into: frequencyBuffer, count: halfSize, sampleRate: Float(config.audio.sampleRate))
        }
        
        deinit {
                isRunning = false
                realBuffer.deallocate()
                imagBuffer.deallocate()
                magnitudeBuffer.deallocate()
                denoisedBuffer.deallocate()
                frequencyBuffer.deallocate()
                currentNoiseFloor.deallocate()
                previousNoiseFloor.deallocate()
                tempNoiseFloor.deallocate()
                qrResultBuffer.deallocate()
                qrTvBuffer.deallocate()
        }
        
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
                                // Get the latest window
                                guard let audioWindow = audioProcessor.getWindow(size: config.fft.size) else {
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
                                }
                        }
                }
        }
        
        // MARK: - Main Analysis
        fileprivate func perform(audioWindow: [Float]) -> StudyResult {
                // ───── helpers ───────────────────────────────────────────────────────────
                @inline(__always)
                func log(_ label: String, _ last: inout CFAbsoluteTime) {
                        let now = CFAbsoluteTimeGetCurrent()
                        print("[Study] \(label): \(String(format: "%.3f", (now - last) * 1_000)) ms")
                        last = now
                }
                // ─────────────────────────────────────────────────────────────────────────
                
                let overallStart = CFAbsoluteTimeGetCurrent()
                var checkpoint   = overallStart
                defer {
                        let total = (CFAbsoluteTimeGetCurrent() - overallStart) * 1_000
                        print("[Study] perform(total): \(String(format: "%.3f", total)) ms\n")
                }
                
                // 1️⃣  Pack real input -----------------------------------------------------
                audioWindow.withUnsafeBufferPointer { windowPtr in
                        memcpy(realBuffer, windowPtr.baseAddress!, halfSize * MemoryLayout<Float>.size)
                }
                memset(imagBuffer, 0, halfSize * MemoryLayout<Float>.size)
                log("pack window", &checkpoint)
                
                // 2️⃣  FFT (forward) -------------------------------------------------------
                fftSetup.forward(input: splitComplex, output: &splitComplex)
                var scaleFactor: Float = 2.0 / Float(fftSize)
                vDSP_vsmul(magnitudeBuffer, 1, &scaleFactor, magnitudeBuffer, 1, vDSP_Length(halfSize))
                vDSP_zvmags(&splitComplex, 1, magnitudeBuffer, 1, vDSP_Length(halfSize))
                log("fft & magnitude", &checkpoint)
                
                // 3️⃣  Convert to dB -------------------------------------------------------
                var floor: Float    = 1e-10
                var ceiling: Float  = .greatestFiniteMagnitude
                vDSP_vclip(magnitudeBuffer, 1, &floor, &ceiling, magnitudeBuffer, 1, vDSP_Length(halfSize))
                var reference: Float = 1.0
                vDSP_vdbcon(magnitudeBuffer, 1, &reference, magnitudeBuffer, 1, vDSP_Length(halfSize), 1)
                log("to dB", &checkpoint)
                
                // 4️⃣  Noise‑floor estimation --------------------------------------------
                if isFirstRun {
                        initializeNoiseFloor(firstMagnitudeSpectrum: magnitudeBuffer, count: halfSize)
                        isFirstRun = false
                }
                fitNoiseFloor(
                        magnitudesDB: magnitudeBuffer,
                        frequencies: frequencyBuffer,
                        count: halfSize,
                        config: config.noiseFloor
                )
                var alpha: Float         = noiseFloorAlpha
                var oneMinusAlpha: Float = 1 - noiseFloorAlpha
                vDSP_vsmul(currentNoiseFloor, 1, &alpha, tempNoiseFloor,   1, vDSP_Length(halfSize))
                vDSP_vsmul(previousNoiseFloor, 1, &oneMinusAlpha, previousNoiseFloor, 1, vDSP_Length(halfSize))
                vDSP_vadd(tempNoiseFloor, 1, previousNoiseFloor, 1, currentNoiseFloor, 1, vDSP_Length(halfSize))
                memcpy(previousNoiseFloor, currentNoiseFloor, halfSize * MemoryLayout<Float>.size)
                log("noise‑floor", &checkpoint)
                
                // 5️⃣  Denoise spectrum ---------------------------------------------------
                denoiseSpectrum(
                        magnitudesDB: magnitudeBuffer,
                        noiseFloorDB: currentNoiseFloor,
                        output:       denoisedBuffer,
                        count:        halfSize
                )
                log("denoise", &checkpoint)
                
                // 6️⃣  Harmonic Product Spectrum -----------------------------------------
                let (hpsFundamental, hpsSpectrum) = hpsProcessor.computeHPS(
                        magnitudes: denoisedBuffer,
                        count:      halfSize,
                        sampleRate: Float(config.audio.sampleRate)
                )
                log("hps", &checkpoint)
                
                
                // 8️⃣  Package results ----------------------------------------------------
                let magnitudesDB = Array(UnsafeBufferPointer(start: magnitudeBuffer,  count: halfSize))
                let noiseFloor   = Array(UnsafeBufferPointer(start: currentNoiseFloor, count: halfSize))
                let denoised     = Array(UnsafeBufferPointer(start: denoisedBuffer,   count: halfSize))
                let frequencies  = Array(UnsafeBufferPointer(start: frequencyBuffer,  count: halfSize))
                log("package result", &checkpoint)
                
                return StudyResult(
                        originalSpectrum:  magnitudesDB,
                        noiseFloor:       noiseFloor,
                        denoisedSpectrum: denoised,
                        frequencies:      frequencies,
                        hpsSpectrum:      hpsSpectrum,
                        hpsFundamental:   hpsFundamental,
                        timestamp:        Date(),
                        processingTime:   CFAbsoluteTimeGetCurrent() - overallStart
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
        
        // MARK: - Fit Noise Floor
        private func fitNoiseFloor(magnitudesDB: UnsafeMutablePointer<Float>,
                                   frequencies: UnsafeMutablePointer<Float>,
                                   count: Int,
                                   config: AnalyzerConfig.NoiseFloor) {
                
                switch config.method {
                case .quantileRegression:
                        fitNoiseFloorQuantile(
                                magnitudesDB: magnitudesDB,
                                output: currentNoiseFloor,
                                count: count,
                                quantile: config.quantile,
                                smoothingSigma: config.smoothingSigma
                        )
                }
                
                // Apply threshold offset in-place
                var offset = config.thresholdOffset
                vDSP_vsadd(currentNoiseFloor, 1, &offset, currentNoiseFloor, 1, vDSP_Length(count))
        }
        
        // MARK: - Fit Noise Floor Quantile
        private func fitNoiseFloorQuantile(magnitudesDB: UnsafeMutablePointer<Float>,
                                           output: UnsafeMutablePointer<Float>,
                                           count: Int,
                                           quantile: Float,
                                           smoothingSigma: Float) {
                let maxIterations = 10
                let convergenceThreshold: Float = 1e-4
                let bandwidthSemitones: Float = 12.0
                
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
                                lambda: smoothingSigma,
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
                let sampleRate = Float(config.audio.sampleRate)
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
                let sampleRate = Float(config.audio.sampleRate)
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
        
        // MARK: - Find Peaks
        private func findPeaks(in spectrum: UnsafeMutablePointer<Float>,
                               frequencies: UnsafeMutablePointer<Float>,
                               count: Int,
                               config: AnalyzerConfig.PeakDetection) -> [Peak] {
                var peaks: [Peak] = []
                
                // Find local maxima
                for i in 1..<(count - 1) {
                        if spectrum[i] > spectrum[i-1] &&
                                spectrum[i] > spectrum[i+1] &&
                                spectrum[i] > config.minHeight {
                                
                                // Calculate prominence
                                let (prominence, leftBase, rightBase) = calculateProminence(
                                        at: i,
                                        in: spectrum,
                                        count: count,
                                        window: config.prominenceWindow
                                )
                                
                                if prominence >= config.minProminence {
                                        peaks.append(Peak(
                                                index: i,
                                                frequency: frequencies[i],
                                                magnitude: spectrum[i],
                                                prominence: prominence,
                                                leftBase: leftBase,
                                                rightBase: rightBase
                                        ))
                                }
                        }
                }
                
                // Filter by minimum distance
                peaks = filterByDistance(peaks, minDistance: config.minDistance)
                
                return peaks
        }
        
        // MARK: (Calculate Prominence)
        private func calculateProminence(at peakIndex: Int,
                                         in spectrum: UnsafeMutablePointer<Float>,
                                         count: Int,
                                         window: Int) -> (prominence: Float, leftBase: Int, rightBase: Int) {
                let peakHeight = spectrum[peakIndex]
                let start = max(0, peakIndex - window)
                let end = min(count - 1, peakIndex + window)
                
                // Find lowest points on each side
                var leftMin = peakHeight
                var leftMinIndex = peakIndex
                for i in stride(from: peakIndex - 1, through: start, by: -1) {
                        if spectrum[i] < leftMin {
                                leftMin = spectrum[i]
                                leftMinIndex = i
                        }
                        if spectrum[i] > peakHeight { break }
                }
                
                var rightMin = peakHeight
                var rightMinIndex = peakIndex
                for i in stride(from: peakIndex + 1, through: end, by: 1) {
                        if spectrum[i] < rightMin {
                                rightMin = spectrum[i]
                                rightMinIndex = i
                        }
                        if spectrum[i] > peakHeight { break }
                }
                
                let prominence = peakHeight - max(leftMin, rightMin)
                return (prominence, leftMinIndex, rightMinIndex)
        }
        
        // MARK: (Filter By Distance)
        private func filterByDistance(_ peaks: [Peak], minDistance: Int) -> [Peak] {
                guard !peaks.isEmpty else { return [] }
                
                // Sort by magnitude (keep highest peaks when too close)
                let sorted = peaks.sorted { $0.magnitude > $1.magnitude }
                var kept: [Peak] = []
                
                for peak in sorted {
                        let tooClose = kept.contains { abs($0.index - peak.index) < minDistance }
                        if !tooClose {
                                kept.append(peak)
                        }
                }
                
                return kept.sorted { $0.index < $1.index }
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
