import Foundation
import Accelerate

// MARK: - Study Result
struct StudyResult {
    let originalSpectrum: [Float]
    let noiseFloor: [Float]
    let denoisedSpectrum: [Float]
    let frequencies: [Float]
    let timestamp: Date
}

// MARK: - Study Object
final class Study {
    private let config: Config
    private let queue = DispatchQueue(label: "com.app.study", qos: .userInitiated)
    
    // Quantile regression parameters
    private let quantile: Float = 0.1  // 10th percentile for noise floor
    private let smoothingLambda: Float = 0.2  // Total variation regularization
    private let maxIterations = 10
    private let convergenceThreshold: Float = 1e-4
    
    init(config: Config) {
        self.config = config
    }
    
    func performStudy(magnitudes: [Float], completion: @escaping (StudyResult) -> Void) {
        // Dispatch to background queue
        queue.async { [weak self] in
            guard let self = self else { return }
            
            // Generate frequency array for the bins
            let frequencies = self.generateFrequencyArray(count: magnitudes.count)
            
            // Fit noise floor using quantile regression
            let noiseFloor = self.fitNoiseFloor(magnitudes: magnitudes)
            
            // Denoise the spectrum
            let denoised = self.denoiseSpectrum(magnitudes: magnitudes, noiseFloor: noiseFloor)
            
            let result = StudyResult(
                originalSpectrum: magnitudes,
                noiseFloor: noiseFloor,
                denoisedSpectrum: denoised,
                frequencies: frequencies,
                timestamp: Date()
            )
            
            // Return result on main thread
            DispatchQueue.main.async {
                completion(result)
            }
        }
    }
    
    // MARK: - Noise Floor Fitting
    private func fitNoiseFloor(magnitudes: [Float]) -> [Float] {
        let count = magnitudes.count
        var noiseFloor = [Float](repeating: 0, count: count)
        
        // Initialize with moving minimum
        noiseFloor = movingMinimum(magnitudes, windowSize: 20)
        
        // Apply quantile regression with total variation regularization
        for _ in 0..<maxIterations {
            let previousFloor = noiseFloor
            noiseFloor = quantileRegressionStep(
                data: magnitudes,
                current: noiseFloor,
                quantile: quantile,
                lambda: smoothingLambda
            )
            
            // Check convergence
            let change = zip(noiseFloor, previousFloor).map { abs($0 - $1) }.max() ?? 0
            if change < convergenceThreshold {
                break
            }
        }
        
        // Apply final smoothing
        noiseFloor = gaussianSmooth(noiseFloor, sigma: 2.0)
        
        return noiseFloor
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
        var denoised = [Float](repeating: 0, count: count)
        
        for i in 0..<count {
            // Max everything below the floor to the floor value
            let floored = max(magnitudes[i], noiseFloor[i])
            // Then subtract the floor
            denoised[i] = floored - noiseFloor[i]
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
