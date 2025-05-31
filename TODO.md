#  TODO

# Fix rendering scales and bounds


# Find peaks
# Do time domain tracking
# Use Newton's method in the frequency domain to find peaks

# Tuning stuff: Temperament, partials, note names, buttons, state storage, 
# Watch integration



# Analysis:

Step 1: Dispatch the analyzer in its own thread.
Step 2: The analyzer removes the noise floor using quantile regression


final class HPSProcessor {
    private let maxHarmonics: Int
    private let workspace: UnsafeMutablePointer<Float>
    
    init(spectrumSize: Int, maxHarmonics: Int = 5) {
        self.maxHarmonics = maxHarmonics
        self.workspace = UnsafeMutablePointer<Float>.allocate(capacity: spectrumSize)
    }
    
    deinit {
        workspace.deallocate()
    }
    
    func findFundamental(magnitudes: UnsafePointer<Float>,
                        count: Int,
                        sampleRate: Float) -> Float {
        // Copy input to workspace
        memcpy(workspace, magnitudes, count * MemoryLayout<Float>.size)
        
        // Multiply downsampled harmonics
        for h in 2...maxHarmonics {
            for i in 0..<(count / h) {
                workspace[i] *= magnitudes[i * h]
            }
        }
        
        // Find peak
        var maxValue: Float = 0
        var maxIndex: vDSP_Length = 0
        vDSP_maxvi(workspace, 1, &maxValue, &maxIndex, vDSP_Length(count / maxHarmonics))
        
        return Float(maxIndex) * sampleRate / Float(count * 2)
    }
}

final class WeightedHPSProcessor {
    private let harmonicWeights: [Float]
    private let workspace: UnsafeMutablePointer<Float>
    
    init(spectrumSize: Int, timbre: TimbreType) {
        self.harmonicWeights = timbre.harmonicProfile
        self.workspace = UnsafeMutablePointer<Float>.allocate(capacity: spectrumSize)
    }
    
    func findFundamental(magnitudes: UnsafePointer<Float>, count: Int, sampleRate: Float) -> Float {
        memcpy(workspace, magnitudes, count * MemoryLayout<Float>.size)
        
        for (h, weight) in harmonicWeights.enumerated().dropFirst() {
            let harmonic = h + 1
            for i in 0..<(count / harmonic) {
                workspace[i] *= pow(magnitudes[i * harmonic], weight)
            }
        }
        
        var maxValue: Float = 0
        var maxIndex: vDSP_Length = 0
        vDSP_maxvi(workspace, 1, &maxValue, &maxIndex, vDSP_Length(count / harmonicWeights.count))
        return Float(maxIndex) * sampleRate / Float(count * 2)
    }
}
