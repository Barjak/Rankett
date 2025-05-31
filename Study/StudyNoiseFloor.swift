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
                        
                case .huberAsymmetric:
                        noiseFloor = fitNoiseFloorHuber(
                                magnitudesDB: magnitudesDB,
                                delta: config.huberDelta,
                                asymmetry: config.huberAsymmetry,
                                smoothingSigma: config.smoothingSigma
                        )
                        
                case .parametric1OverF:
                        noiseFloor = fitNoiseFloorParametric(
                                magnitudesDB: magnitudesDB,
                                frequencies: frequencies
                        )
                        
                case .whittaker:
                        noiseFloor = fitNoiseFloorWhittaker(
                                magnitudesDB: magnitudesDB,
                                lambda: config.whittakerLambda,
                                order: config.whittakerOrder
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
        
        // MARK: Fit Noise Floor Huber
        
        static func fitNoiseFloorHuber(magnitudesDB: [Float],
                                       delta: Float,
                                       asymmetry: Float,
                                       smoothingSigma: Float) -> [Float] {
                let count = magnitudesDB.count
                var noiseFloor = movingMinimum(magnitudesDB, windowSize: 20)
                
                // Constants
                let maxIterations = 10
                
                for iteration in 0..<maxIterations {
                        var gradient = [Float](repeating: 0, count: count)
                        
                        // Compute Huber loss gradient with asymmetric weighting
                        for i in 0..<count {
                                let residual = magnitudesDB[i] - noiseFloor[i]
                                
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
                                noiseFloor[i] = min(noiseFloor[i], magnitudesDB[i])
                        }
                }
                
                return noiseFloor
        }
        
        // MARK: - Fit Noise Floor Parametric
        
        static func fitNoiseFloorParametric(magnitudesDB: [Float],
                                            frequencies: [Float]) -> [Float] {
                let count = magnitudesDB.count
                
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
                
                // Use lower percentile of magnitudesDB for fitting
                var sortedMags = [(Float, Int)]()
                for idx in validIndices {
                        sortedMags.append((magnitudesDB[idx], idx))
                }
                sortedMags.sort { $0.0 < $1.0 }
                
                // Use bottom 30% of points
                let useCount = Int(Float(sortedMags.count) * 0.3)
                
                for i in 0..<useCount {
                        let idx = sortedMags[i].1
                        let freq = max(frequencies[idx], 1.0)  // Avoid log(0)
                        let x = 1.0 / freq
                        let logX = log10(freq)
                        let y = magnitudesDB[idx]
                        
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
                        noiseFloor[i] = min(noiseFloor[i], magnitudesDB[i])
                }
                
                // Smooth the result
                noiseFloor = gaussianSmooth(noiseFloor, sigma: 2.0)
                
                return noiseFloor
        }
        
        // MARK: Fit Noise Floor Whittaker
        
        static func fitNoiseFloorWhittaker(magnitudesDB: [Float],
                                           lambda: Float,
                                           order: Int) -> [Float] {
                guard let smoothed = whittakerSmooth(
                        signal: magnitudesDB,
                        lambda: lambda,
                        order: order
                ) else {
                        return magnitudesDB
                }
                
                // Clamp to original signal
                return zip(smoothed, magnitudesDB).map { min($0, $1) }
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
        

}
