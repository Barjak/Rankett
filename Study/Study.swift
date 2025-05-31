import Foundation
import Accelerate
import CoreML
final class HPSProcessor {
        private let maxHarmonics: Int
        private let workspace: UnsafeMutablePointer<Float>
        private let harmonicWeights: [Float]
        
        init(spectrumSize: Int, maxHarmonics: Int = 5) {
                self.maxHarmonics = maxHarmonics
                self.workspace = UnsafeMutablePointer<Float>.allocate(capacity: spectrumSize)
                
                // Generate 1/n weights for harmonics
                self.harmonicWeights = (1...maxHarmonics).map { 1.0 / Float($0) }
        }
        
        deinit {
                workspace.deallocate()
        }
        
        func computeHPS(magnitudes: UnsafePointer<Float>,
                        count: Int,
                        sampleRate: Float) -> (fundamental: Float, hpsSpectrum: [Float]) {
                // Initialize workspace with the fundamental (weighted by 1/1 = 1.0)
                memcpy(workspace, magnitudes, count * MemoryLayout<Float>.size)
                
                // Create array to store HPS result
                var hpsResult = Array(UnsafeBufferPointer(start: workspace, count: count))
                
                // Apply weighted harmonic product
                for h in 2...maxHarmonics {
                        let weight = harmonicWeights[h - 1] // 1/h weight
                        
                        for i in 0..<(count / h) {
                                let harmonicIndex = i * h
                                if harmonicIndex < count {
                                        // Apply weighted multiplication in log domain (addition)
                                        workspace[i] += weight * magnitudes[harmonicIndex]
                                }
                        }
                }
                
                // Copy the HPS result (only valid up to count/maxHarmonics)
                let validCount = count / maxHarmonics
                hpsResult = Array(UnsafeBufferPointer(start: workspace, count: validCount))
                
                // Find peak in HPS spectrum
                var maxValue: Float = -Float.infinity
                var maxIndex: vDSP_Length = 0
                vDSP_maxvi(workspace, 1, &maxValue, &maxIndex, vDSP_Length(validCount))
                
                let fundamental = Float(maxIndex) * sampleRate / Float(count * 2)
                
                return (fundamental, hpsResult)
        }
}
// MARK: - Result Types
struct StudyResult {
        let originalSpectrum: [Float]
        let noiseFloor: [Float]
        let denoisedSpectrum: [Float]
        let frequencies: [Float]
        let peaks: [Peak]
        let hpsSpectrum: [Float]      // New: HPS result
        let hpsFundamental: Float      // New: Detected fundamental frequency
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
        
        private let hpsProcessor: HPSProcessor

        
        // Pre-allocated buffers
        private let fftSize: Int
        private let halfSize: Int
        private let fftSetup: vDSP.FFT<DSPSplitComplex>
        private let realBuffer: UnsafeMutablePointer<Float>
        private let imagBuffer: UnsafeMutablePointer<Float>
        private let magnitudeBuffer: UnsafeMutablePointer<Float>
        private var splitComplex: DSPSplitComplex
        
        private var previousPeakPositions: [Int: (x: Float, y: Float)] = [:] // Track by frequency bin
        private let peakPositionAlpha: Float = 0.7 // EMA factor for peak positions
        
        // Noise floor tracking
        private var previousNoiseFloor: [Float]?
        private let noiseFloorAlpha: Float = 0.1
        
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
                self.hpsProcessor = HPSProcessor(spectrumSize: halfSize, maxHarmonics: 5)

                let log2n = vDSP_Length(log2(Float(fftSize)))
                guard let setup = vDSP.FFT(log2n: log2n, radix: .radix2, ofType: DSPSplitComplex.self) else {
                        fatalError("Failed to create FFT setup")
                }
                self.fftSetup = setup
                
                self.realBuffer = UnsafeMutablePointer<Float>.allocate(capacity: halfSize)
                self.imagBuffer = UnsafeMutablePointer<Float>.allocate(capacity: halfSize)
                self.magnitudeBuffer = UnsafeMutablePointer<Float>.allocate(capacity: halfSize)
                self.splitComplex = DSPSplitComplex(realp: realBuffer, imagp: imagBuffer)
        }
        
        deinit {
                isRunning = false
                realBuffer.deallocate()
                imagBuffer.deallocate()
                magnitudeBuffer.deallocate()
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
                                guard let audioWindow = audioProcessor.getWindow(size: config.fft.size) else {
                                        Thread.sleep(forTimeInterval: 0.01)
                                        return
                                }
                                
                                let result = perform(audioWindow: audioWindow)
                                
                                DispatchQueue.main.async { [weak self] in
                                        self?.targetOriginalSpectrum = result.originalSpectrum
                                        self?.targetNoiseFloor = result.noiseFloor
                                        self?.targetDenoisedSpectrum = result.denoisedSpectrum
                                        self?.targetFrequencies = result.frequencies
                                        self?.targetPeaks = result.peaks
                                        self?.targetHPSSpectrum = result.hpsSpectrum
                                        self?.targetHPSFundamental = result.hpsFundamental
                                }
                        }
                }
        }
        
        // MARK: - Main Analysis
        private func perform(audioWindow: [Float]) -> StudyResult {
                let startTime = CFAbsoluteTimeGetCurrent()
                
                // Pack real input
                for i in 0..<halfSize {
                        realBuffer[i] = audioWindow[i * 2]
                        imagBuffer[i] = audioWindow[i * 2 + 1]
                }
                
                // Perform FFT
                fftSetup.forward(input: splitComplex, output: &splitComplex)
                
                // Compute magnitude spectrum
                vDSP_zvmags(&splitComplex, 1, magnitudeBuffer, 1, vDSP_Length(halfSize))
                
                // Convert to dB
                var floor: Float = 1e-10
                var ceiling: Float = Float.greatestFiniteMagnitude
                vDSP_vclip(magnitudeBuffer, 1, &floor, &ceiling, magnitudeBuffer, 1, vDSP_Length(halfSize))
                
                var reference: Float = 1.0
                vDSP_vdbcon(magnitudeBuffer, 1, &reference, magnitudeBuffer, 1, vDSP_Length(halfSize), 1)
                
                // Create magnitude array
                let magnitudesDB = Array(UnsafeBufferPointer(start: magnitudeBuffer, count: halfSize))
                
                // Generate frequency array
                let frequencies = generateFrequencyArray(count: halfSize, sampleRate: Float(config.audio.sampleRate))
                
                // Fit noise floor
                var noiseFloor = fitNoiseFloor(
                        magnitudesDB: magnitudesDB,
                        frequencies: frequencies,
                        config: config.noiseFloor
                )
                
                // Apply EMA smoothing to noise floor
                if let previous = previousNoiseFloor, previous.count == noiseFloor.count {
                        for i in 0..<noiseFloor.count {
                                noiseFloor[i] = noiseFloorAlpha * noiseFloor[i] + (1 - noiseFloorAlpha) * previous[i]
                        }
                }
                previousNoiseFloor = noiseFloor
                
                // Denoise spectrum
                let denoised = denoiseSpectrum(
                        magnitudesDB: magnitudesDB,
                        noiseFloorDB: noiseFloor
                )
                
                let (hpsFundamental, hpsSpectrum) = hpsProcessor.computeHPS(
                        magnitudes: magnitudeBuffer,  // Use raw magnitudes in dB
                        count: halfSize,
                        sampleRate: Float(config.audio.sampleRate)
                )
                
                // Find peaks in full resolution
                var peaks = findPeaks(
                        in: denoised,
                        frequencies: frequencies,
                        config: config.peakDetection
                )
                
                
                // TODO: Get this shit out of here and into its own function
                // Take only the top 8 peaks by magnitude
                peaks = Array(peaks.sorted { $0.magnitude > $1.magnitude }.prefix(8))
                
                // Sort by frequency for display
                peaks.sort { $0.frequency < $1.frequency }
                
                // Apply EMA to peak positions for smooth animation
                var smoothedPeaks: [Peak] = []
                for peak in peaks {
                        let currentX = Float(peak.index)
                        let currentY = peak.magnitude
                        
                        if let previous = previousPeakPositions[peak.index] {
                                // EMA smooth the position
                                let smoothedX = peakPositionAlpha * currentX + (1 - peakPositionAlpha) * previous.x
                                let smoothedY = peakPositionAlpha * currentY + (1 - peakPositionAlpha) * previous.y
                                
                                // Create peak with smoothed display position but original frequency for label
                                var smoothedPeak = peak
                                // We'll handle the smooth rendering in the view
                                smoothedPeaks.append(smoothedPeak)
                                
                                previousPeakPositions[peak.index] = (smoothedX, smoothedY)
                        } else {
                                smoothedPeaks.append(peak)
                                previousPeakPositions[peak.index] = (currentX, currentY)
                        }
                }
                
                // Clean up old peak positions
                previousPeakPositions = previousPeakPositions.filter { key, _ in
                        peaks.contains { $0.index == key }
                }
                
                let totalTime = CFAbsoluteTimeGetCurrent() - startTime
                
                return StudyResult(
                        originalSpectrum: magnitudesDB,
                        noiseFloor: noiseFloor,
                        denoisedSpectrum: denoised,
                        frequencies: frequencies,
                        peaks: smoothedPeaks,
                        hpsSpectrum: hpsSpectrum,
                        hpsFundamental: hpsFundamental,
                        timestamp: Date(),
                        processingTime: totalTime
                )
        }
        
        // MARK: - Generate Frequency Array
        private func generateFrequencyArray(count: Int, sampleRate: Float) -> [Float] {
                let binWidth = sampleRate / Float(count * 2)
                return (0..<count).map { Float($0) * binWidth }
        }
        // MARK: - Sign
        private func sign(_ x: Float) -> Float {
                if x > 0 { return 1 }
                else if x < 0 { return -1 }
                else { return 0 }
        }
        // MARK: - Fit Noise Floor
        private func fitNoiseFloor(magnitudesDB: [Float],
                                  frequencies: [Float],
                                  config: AnalyzerConfig.NoiseFloor) -> [Float] {
                
                var noiseFloor: [Float]
                
                switch config.method {
                case .quantileRegression:
                        noiseFloor = fitNoiseFloorQuantile(
                                magnitudesDB: magnitudesDB,
                                quantile: config.quantile,
                                smoothingSigma: config.smoothingSigma
                        )
                }
                
                // Apply threshold offset
                return noiseFloor.map { $0 + config.thresholdOffset }
        }
        
        // MARK: - Fit Noise Floor Quantile
        private func fitNoiseFloorQuantile(magnitudesDB: [Float],
                                          quantile: Float,
                                          smoothingSigma: Float) -> [Float] {
                let count = magnitudesDB.count
                var noiseFloor = [Float](repeating: 0, count: count)
                
                // Constants for convergence
                let maxIterations = 10
                let convergenceThreshold: Float = 1e-4
                
                // Initialize with moving minimum
                noiseFloor = movingMinimum(magnitudesDB, windowSize: 20)
                
                // Iterative quantile regression
                for _ in 0..<maxIterations {
                        let previousFloor = noiseFloor
                        noiseFloor = quantileRegressionStep(
                                data: magnitudesDB,
                                current: noiseFloor,
                                quantile: quantile,
                                lambda: smoothingSigma
                        )
                        
                        // Check convergence
                        let change = zip(noiseFloor, previousFloor).map { abs($0 - $1) }.max() ?? 0
                        if change < convergenceThreshold {
                                break
                        }
                }
                
                // Final smoothing
                noiseFloor = gaussianSmooth(noiseFloor, sigma: 2.0)
                return noiseFloor
        }
        
        // MARK: - Quantile Regression Step
        private func quantileRegressionStep(data: [Float],
                                                   current: [Float],
                                                   quantile: Float,
                                                   lambda: Float) -> [Float] {
                let count = data.count
                var result = [Float](repeating: 0, count: count)
                
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
                        result[i] = current[i] + 0.1 * subgradient
                }
                
                // Apply total variation regularization
                for _ in 0..<3 {  // Inner iterations for TV
                        var tvResult = result
                        for i in 1..<(count-1) {
                                let diff1 = result[i] - result[i-1]
                                let diff2 = result[i+1] - result[i]
                                let tvGrad = sign(diff1) - sign(diff2)
                                tvResult[i] = result[i] - lambda * tvGrad
                        }
                        result = tvResult
                }
                
                // Ensure noise floor doesn't exceed data
                for i in 0..<count {
                        result[i] = min(result[i], data[i])
                }
                
                return result
        }
        
        // MARK: - Denoising
        private func denoiseSpectrum(magnitudesDB: [Float], noiseFloorDB: [Float]) -> [Float] {
                let count = magnitudesDB.count
                var denoised = [Float](repeating: -Float.infinity, count: count)
                
                for i in 0..<count {
                        if magnitudesDB[i] > noiseFloorDB[i] {
                                // Return the signal-to-noise ratio in dB
                                denoised[i] = magnitudesDB[i] - noiseFloorDB[i]
                        } else {
                                denoised[i] = 0 // Signal is at or below noise floor
                        }
                }
                
                return denoised
        }
        
        // MARK: Moving Minimum
        
        private func movingMinimum(_ data: [Float], windowSize: Int) -> [Float] {
                let count = data.count
                var result = [Float](repeating: 0, count: count)
                
                for i in 0..<count {
                        let start = max(0, i - windowSize/2)
                        let end = min(count, i + windowSize/2 + 1)
                        result[i] = data[start..<end].min() ?? data[i]
                }
                
                return result
        }
        // MARK: Gaussian Smooth
        private func gaussianSmooth(_ data: [Float], sigma: Float) -> [Float] {
                let kernelSize = Int(ceil(sigma * 3)) * 2 + 1
                let kernel = gaussianKernel(size: kernelSize, sigma: sigma)
                
                var result = [Float](repeating: 0, count: data.count)
                let halfKernel = kernelSize / 2
                
                for i in 0..<data.count {
                        var sum: Float = 0
                        var weightSum: Float = 0
                        
                        for j in 0..<kernelSize {
                                let dataIndex = i + j - halfKernel
                                if dataIndex >= 0 && dataIndex < data.count {
                                        sum += data[dataIndex] * kernel[j]
                                        weightSum += kernel[j]
                                }
                        }
                        result[i] = sum / weightSum
                }
                return result
        }
        // MARK: (Gaussian Kernel)
        private func gaussianKernel(size: Int, sigma: Float) -> [Float] {
                let center = Float(size / 2)
                let twoSigmaSquared = 2 * sigma * sigma
                
                var kernel = [Float](repeating: 0, count: size)
                var sum: Float = 0
                
                for i in 0..<size {
                        let x = Float(i) - center
                        kernel[i] = exp(-(x * x) / twoSigmaSquared)
                        sum += kernel[i]
                }
                
                // Normalize
                for i in 0..<size {
                        kernel[i] /= sum
                }
                
                return kernel
        }
        
        
        
        // MARK: - Find Peaks
        private func findPeaks(in spectrum: [Float],
                              frequencies: [Float],
                              config: AnalyzerConfig.PeakDetection) -> [Peak] {
                var peaks: [Peak] = []
                
                // Find local maxima
                for i in 1..<(spectrum.count - 1) {
                        if spectrum[i] > spectrum[i-1] &&
                                spectrum[i] > spectrum[i+1] &&
                                spectrum[i] > config.minHeight {
                                
                                // Calculate prominence
                                let (prominence, leftBase, rightBase) = calculateProminence(
                                        at: i,
                                        in: spectrum,
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
                                        in spectrum: [Float],
                                        window: Int) -> (prominence: Float, leftBase: Int, rightBase: Int) {
                let peakHeight = spectrum[peakIndex]
                let start = max(0, peakIndex - window)
                let end = min(spectrum.count - 1, peakIndex + window)
                
                // Find lowest points on each side
                var leftMin = peakHeight
                var leftMinIndex = peakIndex
                for i in stride(from: peakIndex - 1, through: start, by: -1) {
                        if spectrum[i] < leftMin {
                                leftMin = spectrum[i]
                                leftMinIndex = i
                        }
                        if spectrum[i] > peakHeight { break }  // Higher peak found
                }
                
                var rightMin = peakHeight
                var rightMinIndex = peakIndex
                for i in stride(from: peakIndex + 1, through: end, by: 1) {
                        if spectrum[i] < rightMin {
                                rightMin = spectrum[i]
                                rightMinIndex = i
                        }
                        if spectrum[i] > peakHeight { break }  // Higher peak found
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
}
