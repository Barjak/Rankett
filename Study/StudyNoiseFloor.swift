import Foundation
import Accelerate
import CoreML

extension Study {
        private static func sign(_ x: Float) -> Float {
                if x > 0 { return 1 }
                else if x < 0 { return -1 }
                else { return 0 }
        }
        // MARK: - Fit Noise Floor
        static func fitNoiseFloor(magnitudesDB: [Float],
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
        static func fitNoiseFloorQuantile(magnitudesDB: [Float],
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
        
        // MARK: - Denoising
        
        static func denoiseSpectrum(magnitudesDB: [Float], noiseFloorDB: [Float]) -> [Float] {
                let count = magnitudesDB.count
                var denoised = [Float](repeating: -80, count: count)
                
                for i in 0..<count {
                        if magnitudesDB[i] > noiseFloorDB[i] {
                                denoised[i] = magnitudesDB[i] - noiseFloorDB[i] - 80
                        } else {
                                denoised[i] = -80
                        }
                }
                
                return denoised
        }
        
        // MARK: Moving Minimum
        
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
        // MARK: Gaussian Smooth
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
        // MARK: (Gaussian Kernel)
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
}
