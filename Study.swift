import Foundation
import Accelerate
import CoreML

// Add to Study.swift

struct PeakDetectionConfig {
    var minProminence: Float = 6.0      // dB above surrounding
    var minDistance: Int = 5            // bins between peaks
    var minHeight: Float = -60.0        // absolute dB threshold
    var prominenceWindow: Int = 50      // bins to search for bases
}

// Update StudyResult to include peaks
struct StudyResult {
    let originalSpectrum: [Float]
    let noiseFloor: [Float]
    let denoisedSpectrum: [Float]
    let frequencies: [Float]
    let peaks: [Peak]  // Add this
    let timestamp: Date
}

struct Peak {
    let index: Int
    let frequency: Float
    let magnitude: Float
    let prominence: Float
    let leftBase: Int
    let rightBase: Int
}

// MARK: - Study Object
struct NoiseFloorConfig {
    var method: Study.NoiseFloorMethod = .whittaker
    var thresholdOffset: Float = 10.0  // dB above fitted floor

    // Quantile Regression
    var quantile: Float = 0.1

    // Huber Loss
    var huberDelta: Float = 1.0
    var huberAsymmetry: Float = 2.0

    // Common smoothing
    var smoothingSigma: Float = 1.0

    // Whittaker Smoother
    var whittakerLambda: Float = 1000.0   // Controls smoothing strength
    var whittakerOrder: Int = 2           // Usually 2 (second derivative penalty)
}

final class Study {
    private let config: Config
    private let noiseConfig: NoiseFloorConfig
    
    init(config: Config, noiseConfig: NoiseFloorConfig = NoiseFloorConfig()) {
        self.config = config
        self.noiseConfig = noiseConfig
    }
    
    private let queue = DispatchQueue(label: "com.app.study", qos: .userInitiated)
    
    // Quantile regression parameters
    private let maxIterations = 10
    private let convergenceThreshold: Float = 1e-4
    
    // Threshold adjustment - how many dB above the fitted noise floor
    
    // Method selection
    enum NoiseFloorMethod {
        case quantileRegression
        case huberAsymmetric
        case parametric1OverF
        case whittaker
    }
    
    private let method: NoiseFloorMethod = .quantileRegression  // Change this to try different methods
    
    
    private let peakConfig = PeakDetectionConfig()

    // Update performStudy to include peak detection
    func performStudy(fftReal: [Float],
                      fftImag: [Float],
                      timeDomain: [Float],
                      sampleRate: Float,
                      completion: @escaping (StudyResult) -> Void) {
        queue.async { [weak self] in
            guard let self = self else { return }
            
            // Compute magnitudes
            let magnitudes = zip(fftReal, fftImag).map { sqrt($0*$0 + $1*$1) }
            let magnitudesDB = magnitudes.map { 20 * log10(max($0, 1e-10)) }
            
            // Generate frequencies
            let frequencies = self.generateFrequencyArray(count: magnitudes.count)
            
            
            // Fit noise floor using selected method
            var noiseFloor: [Float]
            switch self.method {
            case .quantileRegression:
                noiseFloor = self.fitNoiseFloorQuantile(magnitudes: magnitudes)
            case .huberAsymmetric:
                noiseFloor = self.fitNoiseFloorHuber(magnitudes: magnitudes)
            case .parametric1OverF:
                noiseFloor = self.fitNoiseFloorParametric(magnitudes: magnitudes, frequencies: frequencies)
            case .whittaker:
                noiseFloor = self.fitNoiseFloorWhittaker(magnitudes: magnitudes)
            }
            
            // Apply threshold offset - raise the floor by N dB
            noiseFloor = noiseFloor.map { $0 + self.noiseConfig.thresholdOffset }
            
            let denoised = self.denoiseSpectrum(magnitudes: magnitudes, noiseFloor: noiseFloor)
            // Find peaks in the denoised spectrum
            let peaks = self.findPeaks(in: magnitudes, frequencies: frequencies)
            
            let result = StudyResult(
                originalSpectrum: magnitudesDB,
                noiseFloor: noiseFloor,
                denoisedSpectrum: denoised,
                frequencies: frequencies,
                peaks: peaks,
                timestamp: Date()
            )
            
            DispatchQueue.main.async {
                completion(result)
            }
        }
    }
    
    private func fitNoiseFloorWhittaker(magnitudes: [Float]) -> [Float] {
        let lambda = noiseConfig.whittakerLambda
        guard let smoothed = whittakerSmooth(signal: magnitudes, lambda: lambda) else {
            return magnitudes
        }
        
        let offset = noiseConfig.thresholdOffset
        let adjusted = smoothed.map { $0 + offset }
        
        return adjusted.enumerated().map { min($0.element, magnitudes[$0.offset]) } // clamp to original
    }
    private func calculateProminence(at peakIndex: Int, in spectrum: [Float], window: Int) -> (prominence: Float, leftBase: Int, rightBase: Int) {
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
    private func findPeaks(in spectrum: [Float], frequencies: [Float]) -> [Peak] {
        var peaks: [Peak] = []
        
        // Find local maxima
        for i in 1..<(spectrum.count - 1) {
            if spectrum[i] > spectrum[i-1] && spectrum[i] > spectrum[i+1] && spectrum[i] > peakConfig.minHeight {
                // Calculate prominence
                let (prominence, leftBase, rightBase) = calculateProminence(
                    at: i,
                    in: spectrum,
                    window: peakConfig.prominenceWindow
                )
                
                if prominence >= peakConfig.minProminence {
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
        peaks = filterByDistance(peaks, minDistance: peakConfig.minDistance)
        
        return peaks
    }
    // MARK: - Method 1: Quantile Regression (original)
    private func fitNoiseFloorQuantile(magnitudes: [Float]) -> [Float] {
        let count = magnitudes.count
        var noiseFloor = [Float](repeating: 0, count: count)
        
        noiseFloor = movingMinimum(magnitudes, windowSize: 20)
        
        for _ in 0..<maxIterations {
            let previousFloor = noiseFloor
            noiseFloor = quantileRegressionStep(
                data: magnitudes,
                current: noiseFloor,
                quantile: noiseConfig.quantile,
                lambda: noiseConfig.smoothingSigma
            )
            
            let change = zip(noiseFloor, previousFloor).map { abs($0 - $1) }.max() ?? 0
            if change < convergenceThreshold {
                break
            }
        }
        
        noiseFloor = gaussianSmooth(noiseFloor, sigma: 2.0)
        return noiseFloor
    }
    
    // MARK: - Method 2: Huber Loss with Asymmetric Weighting
    private func fitNoiseFloorHuber(magnitudes: [Float]) -> [Float] {
        let count = magnitudes.count
        var noiseFloor = movingMinimum(magnitudes, windowSize: 20)
        
        let huberDelta: Float = 1.0  // Threshold for Huber loss
        let alpha: Float = 2.0  // Asymmetry parameter
        
        for iteration in 0..<maxIterations {
            var gradient = [Float](repeating: 0, count: count)
            
            // Compute Huber loss gradient with asymmetric weighting
            for i in 0..<count {
                let residual = magnitudes[i] - noiseFloor[i]
                
                // Asymmetric weight - penalize positive errors more
                let weight = residual > 0 ? exp(-alpha * residual) : 1.0
                
                // Huber loss gradient
                let grad: Float
                if abs(residual) <= huberDelta {
                    grad = residual * weight
                } else {
                    grad = huberDelta * sign(residual) * weight
                }
                
                gradient[i] = grad
            }
            
            // Apply gradient update with momentum
            let learningRate: Float = 0.1 / Float(iteration + 1)
            for i in 0..<count {
                noiseFloor[i] += learningRate * gradient[i]
            }
            
            // Apply smoothness constraint
            noiseFloor = gaussianSmooth(noiseFloor, sigma: 1.0)
            
            // Ensure floor doesn't exceed data
            for i in 0..<count {
                noiseFloor[i] = min(noiseFloor[i], magnitudes[i])
            }
        }
        
        return noiseFloor
    }
    
    // MARK: - Method 3: Parametric 1/f Model
    private func fitNoiseFloorParametric(magnitudes: [Float], frequencies: [Float]) -> [Float] {
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
    
    // MARK: - Whittaker Smoother
    private func whittakerSmooth(signal: [Float], lambda: Float) -> [Float]? {
        let n = signal.count
        guard n >= 3 else { return signal }

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

        // Add lambda * Dᵀ * D to identity matrix
        for i in 0..<n {
            DT_D[i * n + i] += lambda
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
    
    
    // MARK: - Quantile Regression Step
    private func quantileRegressionStep(data: [Float], current: [Float], quantile: Float, lambda: Float) -> [Float] {
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
    private func denoiseSpectrum(magnitudes: [Float], noiseFloor: [Float]) -> [Float] {
        let count = magnitudes.count
        var denoised = [Float](repeating: -80, count: count) // Start with minimum dB
        
        for i in 0..<count {
            // Calculate the relative height above the noise floor
            let relativeHeight = magnitudes[i] - noiseFloor[i]
            
            // Only keep positive differences (peaks above noise floor)
            if relativeHeight > 0 {
                denoised[i] = relativeHeight
            } else {
                // Keep at -80 dB for values at or below the noise floor
                denoised[i] = -80
            }
        }
        
        return denoised
    }
    
    // MARK: - Helper Functions
    private func generateFrequencyArray(count: Int) -> [Float] {
        let binWidth = Float(config.sampleRate) / Float(config.fftSize)
        return (0..<count).map { Float($0) * binWidth }
    }
    
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
    
    private func sign(_ x: Float) -> Float {
        if x > 0 { return 1 }
        if x < 0 { return -1 }
        return 0
    }
}
