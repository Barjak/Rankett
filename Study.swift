import Foundation
import Accelerate
import CoreML

import Foundation
import Accelerate
import CoreML

// MARK: - Result Types

struct StudyResult {
        let originalSpectrum: [Float]
        let noiseFloor: [Float]
        let denoisedSpectrum: [Float]
        let frequencies: [Float]
        let peaks: [Peak]
        let timestamp: Date
        
        // Additional analysis results
        let fundamental: Float?
        let harmonics: [Float]
        let spectralCentroid: Float
        let spectralFlux: Float
}

struct Peak {
        let index: Int
        let frequency: Float
        let magnitude: Float
        let prominence: Float
        let leftBase: Int
        let rightBase: Int
}

// MARK: - Study Analysis Functions

enum Study {
        
        // MARK: - Main Entry Point
        
        /// Perform comprehensive spectral analysis
        /// This is now a pure function - no async, no dispatch queues
        static func perform(data: SpectrumAnalyzer.StudyData, config: AnalyzerConfig) -> StudyResult {
                
                // Compute magnitudes from FFT data
                let magnitudes = computeMagnitudes(real: data.fftReal, imag: data.fftImag)
                
                // Generate frequency array
                let frequencies = generateFrequencyArray(
                        count: magnitudes.count,
                        sampleRate: data.sampleRate
                )
                
                // Fit noise floor using configured method
                let noiseFloor = fitNoiseFloor(
                        magnitudes: magnitudes,
                        frequencies: frequencies,
                        config: config.noiseFloor
                )
                
                // Denoise spectrum
                let denoised = denoiseSpectrum(
                        magnitudes: magnitudes,
                        noiseFloor: noiseFloor
                )
                
                // Find peaks
                let peaks = findPeaks(
                        in: denoised,
                        frequencies: frequencies,
                        config: config.peakDetection
                )
                
                // Find fundamental frequency
                let fundamental = findFundamental(
                        magnitudes: magnitudes,
                        sampleRate: data.sampleRate
                )
                
                // Find harmonics
                let harmonics = findHarmonics(
                        magnitudes: magnitudes,
                        fundamental: fundamental,
                        sampleRate: data.sampleRate
                )
                
                // Compute spectral features
                let centroid = computeSpectralCentroid(
                        magnitudes: magnitudes,
                        frequencies: frequencies
                )
                
                let flux = computeSpectralFlux(
                        current: magnitudes,
                        previous: nil  // Would need previous frame in real implementation
                )
                
                return StudyResult(
                        originalSpectrum: magnitudes,
                        noiseFloor: noiseFloor,
                        denoisedSpectrum: denoised,
                        frequencies: frequencies,
                        peaks: peaks,
                        timestamp: Date(timeIntervalSince1970: data.timestamp),
                        fundamental: fundamental,
                        harmonics: harmonics,
                        spectralCentroid: centroid,
                        spectralFlux: flux
                )
        }
        
        
        // MARK: - Fit Noise Floor
        
        static func fitNoiseFloor(magnitudes: [Float],
                                  frequencies: [Float],
                                  config: AnalyzerConfig.NoiseFloor) -> [Float] {
                
                var noiseFloor: [Float]
                
                switch config.method {
                case .quantileRegression:
                        noiseFloor = fitNoiseFloorQuantile(
                                magnitudes: magnitudes,
                                quantile: config.quantile,
                                smoothingSigma: config.smoothingSigma
                        )
                        
                case .huberAsymmetric:
                        noiseFloor = fitNoiseFloorHuber(
                                magnitudes: magnitudes,
                                delta: config.huberDelta,
                                asymmetry: config.huberAsymmetry,
                                smoothingSigma: config.smoothingSigma
                        )
                        
                case .parametric1OverF:
                        noiseFloor = fitNoiseFloorParametric(
                                magnitudes: magnitudes,
                                frequencies: frequencies
                        )
                        
                case .whittaker:
                        noiseFloor = fitNoiseFloorWhittaker(
                                magnitudes: magnitudes,
                                lambda: config.whittakerLambda,
                                order: config.whittakerOrder
                        )
                }
                
                // Apply threshold offset
                return noiseFloor.map { $0 + config.thresholdOffset }
        }
        
        // MARK: - Fit Noise Floor Quantile
        static func fitNoiseFloorQuantile(magnitudes: [Float],
                                          quantile: Float,
                                          smoothingSigma: Float) -> [Float] {
                let count = magnitudes.count
                var noiseFloor = [Float](repeating: 0, count: count)
                
                // Constants for convergence
                let maxIterations = 10
                let convergenceThreshold: Float = 1e-4
                
                // Initialize with moving minimum
                noiseFloor = movingMinimum(magnitudes, windowSize: 20)
                
                // Iterative quantile regression
                for _ in 0..<maxIterations {
                        let previousFloor = noiseFloor
                        noiseFloor = quantileRegressionStep(
                                data: magnitudes,
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
        
        private static func quantileRegressionStep(data: [Float],
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
        
        // MARK: Fit Noise Floor Huber
        
        static func fitNoiseFloorHuber(magnitudes: [Float],
                                       delta: Float,
                                       asymmetry: Float,
                                       smoothingSigma: Float) -> [Float] {
                let count = magnitudes.count
                var noiseFloor = movingMinimum(magnitudes, windowSize: 20)
                
                // Constants
                let maxIterations = 10
                
                for iteration in 0..<maxIterations {
                        var gradient = [Float](repeating: 0, count: count)
                        
                        // Compute Huber loss gradient with asymmetric weighting
                        for i in 0..<count {
                                let residual = magnitudes[i] - noiseFloor[i]
                                
                                // Asymmetric weight - penalize positive errors more
                                let weight = residual > 0 ? exp(-asymmetry * residual) : 1.0
                                
                                // Huber loss gradient
                                let grad: Float
                                if abs(residual) <= delta {
                                        grad = residual * weight
                                } else {
                                        grad = delta * sign(residual) * weight
                                }
                                
                                gradient[i] = grad
                        }
                        
                        // Apply gradient update with momentum
                        let learningRate: Float = 0.1 / Float(iteration + 1)
                        for i in 0..<count {
                                noiseFloor[i] += learningRate * gradient[i]
                        }
                        
                        // Apply smoothness constraint
                        noiseFloor = gaussianSmooth(noiseFloor, sigma: smoothingSigma)
                        
                        // Ensure floor doesn't exceed data
                        for i in 0..<count {
                                noiseFloor[i] = min(noiseFloor[i], magnitudes[i])
                        }
                }
                
                return noiseFloor
        }
        
        // MARK: - Fit Noise Floor Parametric
        
        static func fitNoiseFloorParametric(magnitudes: [Float],
                                            frequencies: [Float]) -> [Float] {
                let count = magnitudes.count
                
                // Model: f(x) = a/x + b + c*log(x)
                // Convert to linear form for least squares
                
                // Filter out DC and very low frequencies
                let startIdx = 5  // Skip first few bins
                let validIndices = Array(startIdx..<count)
                
                // Prepare matrices for least squares
                var sumX = Float(0)      // 1/f term
                var sumLogX = Float(0)   // log(f) term
                var sumY = Float(0)      // magnitude
                var sumXX = Float(0)
                var sumLogXX = Float(0)
                var sumXLogX = Float(0)
                var sumXY = Float(0)
                var sumLogXY = Float(0)
                var n = Float(0)
                
                // Use lower percentile of magnitudes for fitting
                var sortedMags = [(Float, Int)]()
                for idx in validIndices {
                        sortedMags.append((magnitudes[idx], idx))
                }
                sortedMags.sort { $0.0 < $1.0 }
                
                // Use bottom 30% of points
                let useCount = Int(Float(sortedMags.count) * 0.3)
                
                for i in 0..<useCount {
                        let idx = sortedMags[i].1
                        let freq = max(frequencies[idx], 1.0)  // Avoid log(0)
                        let x = 1.0 / freq
                        let logX = log10(freq)
                        let y = magnitudes[idx]
                        
                        sumX += x
                        sumLogX += logX
                        sumY += y
                        sumXX += x * x
                        sumLogXX += logX * logX
                        sumXLogX += x * logX
                        sumXY += x * y
                        sumLogXY += logX * y
                        n += 1
                }
                
                // Solve 3x3 system for parameters a, b, c
                // Simplified: just fit a/f + b for now
                let denominator = n * sumXX - sumX * sumX
                let a = (n * sumXY - sumX * sumY) / denominator
                let b = (sumXX * sumY - sumX * sumXY) / denominator
                
                // Generate fitted curve
                var noiseFloor = [Float](repeating: b, count: count)
                for i in 0..<count {
                        let freq = max(frequencies[i], 1.0)
                        noiseFloor[i] = a / freq + b
                        
                        // Ensure floor doesn't exceed data
                        noiseFloor[i] = min(noiseFloor[i], magnitudes[i])
                }
                
                // Smooth the result
                noiseFloor = gaussianSmooth(noiseFloor, sigma: 2.0)
                
                return noiseFloor
        }
        
        // MARK: Fit Noise Floor Whittaker
        
        static func fitNoiseFloorWhittaker(magnitudes: [Float],
                                           lambda: Float,
                                           order: Int) -> [Float] {
                guard let smoothed = whittakerSmooth(
                        signal: magnitudes,
                        lambda: lambda,
                        order: order
                ) else {
                        return magnitudes
                }
                
                // Clamp to original signal
                return zip(smoothed, magnitudes).map { min($0, $1) }
        }
        
        // MARK: (Whittaker Helper)
        
        private static func whittakerSmooth(signal: [Float],
                                            lambda: Float,
                                            order: Int) -> [Float]? {
                let n = signal.count
                guard n >= order + 1 else { return signal }
                
                // For now, implement second-order difference (order = 2)
                // Can be extended to support arbitrary order
                guard order == 2 else {
                        print("Only second-order Whittaker smoothing implemented")
                        return nil
                }
                
                // Construct second difference matrix D (size: (n-2) x n)
                var D = [Float](repeating: 0.0, count: (n - 2) * n)
                for i in 0..<n - 2 {
                        D[i * n + i] = 1.0
                        D[i * n + i + 1] = -2.0
                        D[i * n + i + 2] = 1.0
                }
                
                // Compute Dᵀ * D
                var DT_D = [Float](repeating: 0.0, count: n * n)
                vDSP_mmul(D, 1, D, 1, &DT_D, 1, vDSP_Length(n), vDSP_Length(n), vDSP_Length(n - 2))
                
                // Add identity matrix: (I + lambda * Dᵀ * D)
                for i in 0..<n {
                        DT_D[i * n + i] += 1.0
                        DT_D[i * n + i] *= (1.0 + lambda)
                }
                
                // Solve linear system (I + lambda DᵀD) * y = x
                var A = DT_D
                var b = signal
                var N = __CLPK_integer(n)
                var NRHS = __CLPK_integer(1)
                var LDA = N
                var IPIV = [__CLPK_integer](repeating: 0, count: n)
                var LDB = N
                var INFO: __CLPK_integer = 0
                
                sgesv_(&N, &NRHS, &A, &LDA, &IPIV, &b, &LDB, &INFO)
                
                return INFO == 0 ? b : nil
        }
        
        
        
        
        
        // MARK: - Find Peaks
        static func findPeaks(in spectrum: [Float],
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
        static func calculateProminence(at peakIndex: Int,
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
        static func filterByDistance(_ peaks: [Peak], minDistance: Int) -> [Peak] {
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
        
        
        
        // MARK: - Find Fundamental
        
        static func findFundamental(magnitudes: [Float], sampleRate: Float) -> Float? {
                // TODO: Implement HPS or other fundamental detection
                return nil
        }
        // MARK: - Find Harmonics
        static func findHarmonics(magnitudes: [Float],
                                  fundamental: Float?,
                                  sampleRate: Float) -> [Float] {
                // TODO: Implement harmonic analysis
                return []
        }
        
        // MARK: - Compute Spectral Centroid
        
        static func computeSpectralCentroid(magnitudes: [Float],
                                            frequencies: [Float]) -> Float {
                var weightedSum: Float = 0
                var magnitudeSum: Float = 0
                
                for (mag, freq) in zip(magnitudes, frequencies) {
                        weightedSum += freq * mag
                        magnitudeSum += mag
                }
                
                return magnitudeSum > 0 ? weightedSum / magnitudeSum : 0
        }
        // MARK: - Compute Spectral Flux
        static func computeSpectralFlux(current: [Float], previous: [Float]?) -> Float {
                guard let previous = previous else { return 0 }
                
                var flux: Float = 0
                for (curr, prev) in zip(current, previous) {
                        let diff = curr - prev
                        if diff > 0 {
                                flux += diff
                        }
                }
                
                return flux
        }
        
        
        // MARK: - Denoising
        
        static func denoiseSpectrum(magnitudes: [Float], noiseFloor: [Float]) -> [Float] {
                let count = magnitudes.count
                var denoised = [Float](repeating: -80, count: count)
                
                for i in 0..<count {
                        // If signal is above noise floor, keep original value
                        // Otherwise, set to minimum
                        if magnitudes[i] > noiseFloor[i] {
                                denoised[i] = magnitudes[i]
                        } else {
                                denoised[i] = -80
                        }
                }
                
                return denoised
        }
        
        // MARK: - Helper Functions
        
        static func movingMinimum(_ data: [Float], windowSize: Int) -> [Float] {
                let count = data.count
                var result = [Float](repeating: 0, count: count)
                
                for i in 0..<count {
                        let start = max(0, i - windowSize/2)
                        let end = min(count, i + windowSize/2 + 1)
                        result[i] = data[start..<end].min() ?? data[i]
                }
                
                return result
        }
        
        static func gaussianSmooth(_ data: [Float], sigma: Float) -> [Float] {
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
        
        private static func gaussianKernel(size: Int, sigma: Float) -> [Float] {
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
        
        // MARK: - Compute Magnitudes
        
        static func computeMagnitudes(real: [Float], imag: [Float]) -> [Float] {
                return zip(real, imag).map { sqrt($0 * $0 + $1 * $1) }
        }
        // MARK: - Generate Frequency Array
        static func generateFrequencyArray(count: Int, sampleRate: Float) -> [Float] {
                let binWidth = sampleRate / Float(count * 2)  // count is half FFT size
                return (0..<count).map { Float($0) * binWidth }
        }
        
        // MARK: - (Sign)
        
        private static func sign(_ x: Float) -> Float {
                if x > 0 { return 1 }
                else if x < 0 { return -1 }
                else { return 0 }
        }
        
}
