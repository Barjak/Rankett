
import Foundation

class ExponentialSmoothingStage: ProcessingStage {
    typealias Input = [SpectralData]
    typealias Output = [SpectralData]
    
    private let smoothingFactor: Float
    private var previousData: [String: [Float]] = [:]  // Keyed by some identifier
    private let stateLock = NSLock()
    
    init(smoothingFactor: Float) {
        self.smoothingFactor = smoothingFactor
    }
    
    func process(_ input: [SpectralData]) -> [SpectralData] {
        stateLock.lock()
        defer { stateLock.unlock() }
        
        return input.enumerated().map { index, spectralData in
            let key = "\(index)"  // Simple key based on position in batch
            
            // Initialize state if needed
            if previousData[key] == nil || previousData[key]!.count != spectralData.magnitudes.count {
                previousData[key] = spectralData.magnitudes
                return spectralData  // Return unsmoothed for first frame
            }
            
            // Apply exponential moving average
            let smoothedMagnitudes = zip(previousData[key]!, spectralData.magnitudes).map { previous, current in
                smoothingFactor * previous + (1 - smoothingFactor) * current
            }
            
            // Update state
            previousData[key] = smoothedMagnitudes
            
            return SpectralData(
                magnitudes: smoothedMagnitudes,
                frequencies: spectralData.frequencies,
                sampleRate: spectralData.sampleRate
            )
        }
    }
    
    func reset() {
        stateLock.lock()
        defer { stateLock.unlock() }
        previousData.removeAll()
    }
}

class VarianceTrackingStage: ProcessingStage {
    typealias Input = [SpectralData]
    typealias Output = [SpectralData]
    
    private let alpha: Float
    private let epsilon: Float  // Small value to prevent division by zero
    private var runningMeans: [String: [Float]] = [:]
    private var runningVariances: [String: [Float]] = [:]
    private let stateLock = NSLock()
    
    init(alpha: Float = 0.9, epsilon: Float = 1e-10) {
        self.alpha = alpha
        self.epsilon = epsilon
    }
    
    func process(_ input: [SpectralData]) -> [SpectralData] {
        stateLock.lock()
        defer { stateLock.unlock() }
        
        return input.enumerated().map { index, spectralData in
            let key = "\(index)"
            let magnitudes = spectralData.magnitudes
            
            // Initialize state if needed
            if runningMeans[key] == nil || runningMeans[key]!.count != magnitudes.count {
                runningMeans[key] = magnitudes
                runningVariances[key] = [Float](repeating: epsilon, count: magnitudes.count)
                
                // Return inverse variance squared for first frame
                let inverseVarSquared = runningVariances[key]!.map { 1.0 / ($0 * $0) }
                return SpectralData(
                    magnitudes: inverseVarSquared,
                    frequencies: spectralData.frequencies,
                    sampleRate: spectralData.sampleRate
                )
            }
            
            // Update running statistics
            var newMeans = [Float](repeating: 0, count: magnitudes.count)
            var newVariances = [Float](repeating: 0, count: magnitudes.count)
            
            for i in 0..<magnitudes.count {
                let currentValue = magnitudes[i]
                let oldMean = runningMeans[key]![i]
                
                // Update mean: mean_f = α * mean_f + (1 - α) * new_f
                newMeans[i] = alpha * oldMean + (1 - alpha) * currentValue
                
                // Update variance: var_f = α * var_f + (1 - α) * (new_f - mean_f)^2
                let deviation = currentValue - newMeans[i]
                newVariances[i] = alpha * runningVariances[key]![i] + (1 - alpha) * deviation * deviation
                
                // Ensure variance doesn't go below epsilon
                newVariances[i] = max(newVariances[i], epsilon)
            }
            
            // Store updated state
            runningMeans[key] = newMeans
            runningVariances[key] = newVariances
            
            // Calculate inverse variance squared for output
            let inverseVarSquared = newVariances.map { 1.0 / ($0 * $0) }
            
            return SpectralData(
                magnitudes: inverseVarSquared,  // Using inverse variance squared as "magnitude"
                frequencies: spectralData.frequencies,
                sampleRate: spectralData.sampleRate
            )
        }
    }
    
    func reset() {
        stateLock.lock()
        defer { stateLock.unlock() }
        runningMeans.removeAll()
        runningVariances.removeAll()
    }
    
    // Optional: Get the current statistics
    func getStatistics(for key: String = "0") -> (means: [Float], variances: [Float])? {
        stateLock.lock()
        defer { stateLock.unlock() }
        
        guard let means = runningMeans[key], let variances = runningVariances[key] else {
            return nil
        }
        return (means, variances)
    }
}
