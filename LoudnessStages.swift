//// MARK: - Loudness Contour Stage
//struct LoudnessContourStage: Stage {
//    private let weights: [Float]
//    private let frequencyBins: [Float]
//    
//    init(config: Config, phonLevel: Float = 40.0) {
//        // Create frequency bins for the FFT output
//        let binCount = config.fftSize / 2
//        self.frequencyBins = (0..<binCount).map { bin in
//            Float(Double(bin) * config.frequencyResolution)
//        }
//        
//        // Generate ISO 226 loudness contour weights
//        self.weights = Self.generateLoudnessWeights(
//            frequencies: frequencyBins,
//            phonLevel: phonLevel
//        )
//    }
//    
//    func process(pool: MemoryPool, config: Config) {
//        let magPtr = pool.magnitude.pointer(in: pool)
//        let count = pool.magnitude.count
//        
//        // Apply loudness contour weighting
//        vDSP_vmul(magPtr, 1, weights, 1, magPtr, 1, vDSP_Length(count))
//    }
//    
//    // MARK: - ISO 226 Implementation
//    
//    private static func generateLoudnessWeights(frequencies: [Float], phonLevel: Float) -> [Float] {
//        return frequencies.map { freq in
//            // Convert frequency-dependent SPL to linear weight
//            let spl = iso226SPL(frequency: Double(freq), phonLevel: Double(phonLevel))
//            
//            // Convert dB SPL to linear scale weight
//            // We invert the curve so that frequencies with higher sensitivity get more weight
//            let referenceLevel: Double = 0.0 // 1 kHz reference
//            let weightDB = referenceLevel - spl
//            
//            // Convert to linear scale (but keep reasonable bounds)
//            let linearWeight = pow(10.0, weightDB / 20.0)
//            return Float(max(0.1, min(10.0, linearWeight))) // Clamp to reasonable range
//        }
//    }
//    
//    private static func iso226SPL(frequency: Double, phonLevel: Double) -> Double {
//        // ISO 226 tabled frequencies (Hz)
//        let tabled_f: [Double] = [
//            20, 25, 31.5, 40, 50, 63, 80, 100, 125, 160, 200, 250, 315, 400,
//            500, 630, 800, 1000, 1250, 1600, 2000, 2500, 3150, 4000, 5000, 6300,
//            8000, 10000, 12500
//        ]
//        
//        // ISO 226 alpha_f values
//        let tabled_alpha_f: [Double] = [
//            0.532, 0.506, 0.480, 0.455, 0.432, 0.409, 0.387, 0.367, 0.349, 0.330,
//            0.315, 0.301, 0.288, 0.276, 0.267, 0.259, 0.253, 0.250, 0.246, 0.244,
//            0.243, 0.243, 0.243, 0.242, 0.242, 0.245, 0.254, 0.271, 0.301
//        ]
//        
//        // ISO 226 L_U values
//        let tabled_L_U: [Double] = [
//            -31.6, -27.2, -23.0, -19.1, -15.9, -13.0, -10.3, -8.1, -6.2, -4.5,
//            -3.1, -2.0, -1.1, -0.4, 0.0, 0.3, 0.5, 0.0, -2.7, -4.1, -1.0, 1.7,
//            2.5, 1.2, -2.1, -7.1, -11.2, -10.7, -3.1
//        ]
//        
//        // ISO 226 T_f values
//        let tabled_T_f: [Double] = [
//            78.5, 68.7, 59.5, 51.1, 44.0, 37.5, 31.5, 26.5, 22.1, 17.9, 14.4,
//            11.4, 8.6, 6.2, 4.4, 3.0, 2.2, 2.4, 3.5, 1.7, -1.3, -4.2, -6.0, -5.4,
//            -1.5, 6.0, 12.6, 13.9, 12.3
//        ]
//        
//        // Clamp phon level to valid range
//        let clampedPhon = max(0.0, min(90.0, phonLevel))
//        
//        // Find interpolation indices
//        guard let lowerIndex = tabled_f.lastIndex(where: { $0 <= frequency }) else {
//            // Below minimum frequency, use first value
//            return calculateSPL(index: 0, phon: clampedPhon,
//                              alpha_f: tabled_alpha_f, L_U: tabled_L_U, T_f: tabled_T_f)
//        }
//        
//        guard lowerIndex < tabled_f.count - 1 else {
//            // Above maximum frequency, use last value
//            return calculateSPL(index: tabled_f.count - 1, phon: clampedPhon,
//                              alpha_f: tabled_alpha_f, L_U: tabled_L_U, T_f: tabled_T_f)
//        }
//        
//        // Linear interpolation
//        let upperIndex = lowerIndex + 1
//        let lowerFreq = tabled_f[lowerIndex]
//        let upperFreq = tabled_f[upperIndex]
//        let ratio = (frequency - lowerFreq) / (upperFreq - lowerFreq)
//        
//        let lowerSPL = calculateSPL(index: lowerIndex, phon: clampedPhon,
//                                   alpha_f: tabled_alpha_f, L_U: tabled_L_U, T_f: tabled_T_f)
//        let upperSPL = calculateSPL(index: upperIndex, phon: clampedPhon,
//                                   alpha_f: tabled_alpha_f, L_U: tabled_L_U, T_f: tabled_T_f)
//        
//        return lowerSPL + ratio * (upperSPL - lowerSPL)
//    }
//    
//    private static func calculateSPL(index: Int, phon: Double,
//                                   alpha_f: [Double], L_U: [Double], T_f: [Double]) -> Double {
//        let alpha = alpha_f[index]
//        let Lu = L_U[index]
//        let Tf = T_f[index]
//        
//        // ISO 226 formula for A_f
//        let A_f = 4.47e-3 * (pow(10.0, 0.025 * phon) - 1.15) +
//                  pow(0.4 * pow(10.0, (Tf + Lu) / 10.0 - 9.0), alpha)
//        
//        // Convert to SPL
//        let spl = (10.0 / alpha) * log10(A_f) - Lu + 94.0
//        return spl
//    }
//}
//
//// MARK: - Alternative: A-Weighting Stage (Simpler Implementation)
//struct AWeightingStage: Stage {
//    private let weights: [Float]
//    
//    init(config: Config) {
//        let binCount = config.fftSize / 2
//        let frequencies = (0..<binCount).map { bin in
//            Double(bin) * config.frequencyResolution
//        }
//        
//        self.weights = frequencies.map { freq in
//            Float(Self.aWeighting(frequency: freq))
//        }
//    }
//    
//    func process(pool: MemoryPool, config: Config) {
//        let magPtr = pool.magnitude.pointer(in: pool)
//        let count = pool.magnitude.count
//        
//        // Apply A-weighting
//        vDSP_vmul(magPtr, 1, weights, 1, magPtr, 1, vDSP_Length(count))
//    }
//    
//    private static func aWeighting(frequency: Double) -> Double {
//        let f = max(frequency, 1.0) // Avoid division by zero
//        let f2 = f * f
//        let f4 = f2 * f2
//        
//        let numerator = 7.39705e9 * f4
//        let denominator = (f2 + 20.598997 * 20.598997) *
//                         sqrt((f2 + 107.65265 * 107.65265) * (f2 + 737.86223 * 737.86223)) *
//                         (f2 + 12194.217 * 12194.217)
//        
//        let aWeight = numerator / denominator
//        return aWeight
//    }
//}
