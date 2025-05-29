import Foundation
import Accelerate
import QuartzCore

// Minimal protocol - stages just need access to the pool
protocol Stage {
    func process(pool: MemoryPool, config: Config)
}

// MARK: - Window Stage
struct WindowStage: Stage {
    let window: [Float]
    
    init(type: WindowType, size: Int) {
        self.window = type.createWindow(size: size)
    }
    
    func process(pool: MemoryPool, config: Config) {
        let ptr = pool.windowWorkspace.pointer(in: pool)
        // In-place multiplication
        vDSP_vmul(ptr, 1, window, 1, ptr, 1, vDSP_Length(config.fftSize))
    }
}

// MARK: - FFT Stage
final class FFTStage: Stage {
    private let setup: vDSP.FFT<DSPSplitComplex>
    private let halfSize: Int
    
    init(size: Int) {
        self.halfSize = size / 2
        let log2n = vDSP_Length(log2(Float(size)))
        guard let setup = vDSP.FFT(log2n: log2n, radix: .radix2, ofType: DSPSplitComplex.self) else {
            fatalError("Failed to create FFT setup")
        }
        self.setup = setup
    }
    
    func process(pool: MemoryPool, config: Config) {
        let input = pool.windowWorkspace.pointer(in: pool)
        let realPtr = pool.fftReal.pointer(in: pool)
        let imagPtr = pool.fftImag.pointer(in: pool)
        
        // Pack real input for FFT (even/odd split)
        for i in 0..<halfSize {
            realPtr[i] = input[i * 2]
            imagPtr[i] = input[i * 2 + 1]
        }
        
        // Create split complex structure
        var splitComplex = DSPSplitComplex(realp: realPtr, imagp: imagPtr)
        
        // Perform FFT in-place
        setup.forward(input: splitComplex, output: &splitComplex)
    }
}

// MARK: - Magnitude Stage
struct MagnitudeStage: Stage {
    let convertToDb: Bool
    
    init(convertToDb: Bool = true) {
        self.convertToDb = convertToDb
    }
    
    func process(pool: MemoryPool, config: Config) {
        let realPtr = pool.fftReal.pointer(in: pool)
        let imagPtr = pool.fftImag.pointer(in: pool)
        let magPtr = pool.magnitude.pointer(in: pool)
        let count = pool.magnitude.count
        
        var splitComplex = DSPSplitComplex(realp: realPtr, imagp: imagPtr)
        
        // Calculate magnitudes
        vDSP_zvmags(&splitComplex, 1, magPtr, 1, vDSP_Length(count))
        
        if convertToDb {
            // First clamp to avoid log(0)
            var floor: Float = 1e-10
            var ceiling: Float = Float.greatestFiniteMagnitude
            vDSP_vclip(magPtr, 1, &floor, &ceiling, magPtr, 1, vDSP_Length(count))
            
            // Convert to dB with reference = 1.0
            var reference: Float = 1.0
            vDSP_vdbcon(magPtr, 1, &reference, magPtr, 1, vDSP_Length(count), 1)
        }
    }
}

// MARK: - Frequency Binning Stage
struct FrequencyBinningStage: Stage {
    private let binMap: [Int]
    private let linearBinning: Bool
    
    init(config: Config) {
        if config.useLogFrequencyScale {
            self.binMap = Self.createLogBinMap(config: config)
            self.linearBinning = false
        } else {
            // For linear, we'll just use the first N bins
            self.binMap = []
            self.linearBinning = true
        }
    }
    
    private static func createLogBinMap(config: Config) -> [Int] {
        let nyquist = config.nyquistFrequency
        let maxBins = config.fftSize / 2
        let logMin = log10(config.minFrequency)
        let logMax = log10(min(config.maxFrequency, nyquist))
        
        return (0..<config.outputBinCount).map { i in
            let logFreq = logMin + (logMax - logMin) * Double(i) / Double(config.outputBinCount - 1)
            let freq = pow(10, logFreq)
            let binIndex = Int(freq / config.frequencyResolution)
            return min(binIndex, maxBins - 1)
        }
    }
    
    func process(pool: MemoryPool, config: Config) {
        let srcPtr = pool.magnitude.pointer(in: pool)
        let dstPtr = pool.displayTarget.pointer(in: pool)
        
        if linearBinning {
            // Just copy the first N bins
            let copyCount = min(config.outputBinCount, pool.magnitude.count)
            memcpy(dstPtr, srcPtr, copyCount * MemoryLayout<Float>.size)
            
            // Fill remaining with minimum if needed
            if copyCount < config.outputBinCount {
                let minDB: Float = -80.0
                for i in copyCount..<config.outputBinCount {
                    dstPtr[i] = minDB
                }
            }
        } else {
            // Apply log frequency mapping
            for i in 0..<config.outputBinCount {
                dstPtr[i] = srcPtr[binMap[i]]
            }
        }
    }
}
struct FFTStatsStage: Stage {
    func process(pool: MemoryPool, config: Config) {
        let newPtr = pool.magnitude.pointer(in: pool)
        let meanPtr = pool.fftStatsMean.pointer(in: pool)
        let varPtr = pool.fftStatsVar.pointer(in: pool)

        let count = config.fftSize / 2
        let alpha: Float = 0.8
        let oneMinusAlpha = 1 - alpha

        var dbMag = [Float](repeating: 0, count: count)
        var meanVar: Float = 0
        var maxVar: Float = 0

        // Step 1: Convert magnitude to dB and update running mean/variance in dB space
        for i in 0..<count {
            let mag = max(newPtr[i], 1e-10)
            let db = 20 * log10(mag)
            dbMag[i] = db

            let mean = meanPtr[i]
            let delta = db - mean
            meanPtr[i] = alpha * mean + oneMinusAlpha * db
            varPtr[i] = alpha * varPtr[i] + oneMinusAlpha * delta * delta
        }

        // Step 2: Compute mean and max of variance (in dB space)
        for i in 0..<count {
            meanVar += varPtr[i]
            if varPtr[i] > maxVar {
                maxVar = varPtr[i]
            }
        }
        meanVar /= Float(count)

        // Step 3: Compute standard deviation of variance
        var sumSqDiff: Float = 0
        for i in 0..<count {
            let diff = varPtr[i] - meanVar
            sumSqDiff += diff * diff
        }
        let stdVar = sqrt(sumSqDiff / Float(count))
        let threshold = meanVar + 0.10 * stdVar  // k = 1.0

        // Step 4: Apply suppression based on soft-knee function
        for i in 0..<count {
            let variance = varPtr[i]
            var suppress: Float = 1.0

            if variance > threshold {
                let denom = maxVar - threshold + 1e-5
                let ratio = (variance - threshold) / denom
                suppress = max(0.0, 1.0 - ratio)
            }

            newPtr[i] *= suppress
        }
    }
}





enum Smoothing {
    static func apply(current: UnsafeMutablePointer<Float>,
                      target: UnsafePointer<Float>,
                      count: Int,
                      smoothingFactor alpha: Float) {
        for i in 0..<count {
            current[i] = (current[i] * (alpha)) + (target[i] * (1-alpha))
        }
    }
}
import Foundation
import Accelerate

// MARK: - Loudness Contour Stage
struct LoudnessContourStage: Stage {
    private let weights: [Float]
    private let frequencyBins: [Float]
    
    init(config: Config, phonLevel: Float = 40.0) {
        // Create frequency bins for the FFT output
        let binCount = config.fftSize / 2
        self.frequencyBins = (0..<binCount).map { bin in
            Float(Double(bin) * config.frequencyResolution)
        }
        
        // Generate ISO 226 loudness contour weights
        self.weights = Self.generateLoudnessWeights(
            frequencies: frequencyBins,
            phonLevel: phonLevel
        )
    }
    
    func process(pool: MemoryPool, config: Config) {
        let magPtr = pool.magnitude.pointer(in: pool)
        let count = pool.magnitude.count
        
        // Apply loudness contour weighting
        vDSP_vmul(magPtr, 1, weights, 1, magPtr, 1, vDSP_Length(count))
    }
    
    // MARK: - ISO 226 Implementation
    
    private static func generateLoudnessWeights(frequencies: [Float], phonLevel: Float) -> [Float] {
        return frequencies.map { freq in
            // Convert frequency-dependent SPL to linear weight
            let spl = iso226SPL(frequency: Double(freq), phonLevel: Double(phonLevel))
            
            // Convert dB SPL to linear scale weight
            // We invert the curve so that frequencies with higher sensitivity get more weight
            let referenceLevel: Double = 0.0 // 1 kHz reference
            let weightDB = referenceLevel - spl
            
            // Convert to linear scale (but keep reasonable bounds)
            let linearWeight = pow(10.0, weightDB / 20.0)
            return Float(max(0.1, min(10.0, linearWeight))) // Clamp to reasonable range
        }
    }
    
    private static func iso226SPL(frequency: Double, phonLevel: Double) -> Double {
        // ISO 226 tabled frequencies (Hz)
        let tabled_f: [Double] = [
            20, 25, 31.5, 40, 50, 63, 80, 100, 125, 160, 200, 250, 315, 400,
            500, 630, 800, 1000, 1250, 1600, 2000, 2500, 3150, 4000, 5000, 6300,
            8000, 10000, 12500
        ]
        
        // ISO 226 alpha_f values
        let tabled_alpha_f: [Double] = [
            0.532, 0.506, 0.480, 0.455, 0.432, 0.409, 0.387, 0.367, 0.349, 0.330,
            0.315, 0.301, 0.288, 0.276, 0.267, 0.259, 0.253, 0.250, 0.246, 0.244,
            0.243, 0.243, 0.243, 0.242, 0.242, 0.245, 0.254, 0.271, 0.301
        ]
        
        // ISO 226 L_U values
        let tabled_L_U: [Double] = [
            -31.6, -27.2, -23.0, -19.1, -15.9, -13.0, -10.3, -8.1, -6.2, -4.5,
            -3.1, -2.0, -1.1, -0.4, 0.0, 0.3, 0.5, 0.0, -2.7, -4.1, -1.0, 1.7,
            2.5, 1.2, -2.1, -7.1, -11.2, -10.7, -3.1
        ]
        
        // ISO 226 T_f values
        let tabled_T_f: [Double] = [
            78.5, 68.7, 59.5, 51.1, 44.0, 37.5, 31.5, 26.5, 22.1, 17.9, 14.4,
            11.4, 8.6, 6.2, 4.4, 3.0, 2.2, 2.4, 3.5, 1.7, -1.3, -4.2, -6.0, -5.4,
            -1.5, 6.0, 12.6, 13.9, 12.3
        ]
        
        // Clamp phon level to valid range
        let clampedPhon = max(0.0, min(90.0, phonLevel))
        
        // Find interpolation indices
        guard let lowerIndex = tabled_f.lastIndex(where: { $0 <= frequency }) else {
            // Below minimum frequency, use first value
            return calculateSPL(index: 0, phon: clampedPhon,
                              alpha_f: tabled_alpha_f, L_U: tabled_L_U, T_f: tabled_T_f)
        }
        
        guard lowerIndex < tabled_f.count - 1 else {
            // Above maximum frequency, use last value
            return calculateSPL(index: tabled_f.count - 1, phon: clampedPhon,
                              alpha_f: tabled_alpha_f, L_U: tabled_L_U, T_f: tabled_T_f)
        }
        
        // Linear interpolation
        let upperIndex = lowerIndex + 1
        let lowerFreq = tabled_f[lowerIndex]
        let upperFreq = tabled_f[upperIndex]
        let ratio = (frequency - lowerFreq) / (upperFreq - lowerFreq)
        
        let lowerSPL = calculateSPL(index: lowerIndex, phon: clampedPhon,
                                   alpha_f: tabled_alpha_f, L_U: tabled_L_U, T_f: tabled_T_f)
        let upperSPL = calculateSPL(index: upperIndex, phon: clampedPhon,
                                   alpha_f: tabled_alpha_f, L_U: tabled_L_U, T_f: tabled_T_f)
        
        return lowerSPL + ratio * (upperSPL - lowerSPL)
    }
    
    private static func calculateSPL(index: Int, phon: Double,
                                   alpha_f: [Double], L_U: [Double], T_f: [Double]) -> Double {
        let alpha = alpha_f[index]
        let Lu = L_U[index]
        let Tf = T_f[index]
        
        // ISO 226 formula for A_f
        let A_f = 4.47e-3 * (pow(10.0, 0.025 * phon) - 1.15) +
                  pow(0.4 * pow(10.0, (Tf + Lu) / 10.0 - 9.0), alpha)
        
        // Convert to SPL
        let spl = (10.0 / alpha) * log10(A_f) - Lu + 94.0
        return spl
    }
}

// MARK: - Alternative: A-Weighting Stage (Simpler Implementation)
struct AWeightingStage: Stage {
    private let weights: [Float]
    
    init(config: Config) {
        let binCount = config.fftSize / 2
        let frequencies = (0..<binCount).map { bin in
            Double(bin) * config.frequencyResolution
        }
        
        self.weights = frequencies.map { freq in
            Float(Self.aWeighting(frequency: freq))
        }
    }
    
    func process(pool: MemoryPool, config: Config) {
        let magPtr = pool.magnitude.pointer(in: pool)
        let count = pool.magnitude.count
        
        // Apply A-weighting
        vDSP_vmul(magPtr, 1, weights, 1, magPtr, 1, vDSP_Length(count))
    }
    
    private static func aWeighting(frequency: Double) -> Double {
        let f = max(frequency, 1.0) // Avoid division by zero
        let f2 = f * f
        let f4 = f2 * f2
        
        let numerator = 7.39705e9 * f4
        let denominator = (f2 + 20.598997 * 20.598997) *
                         sqrt((f2 + 107.65265 * 107.65265) * (f2 + 737.86223 * 737.86223)) *
                         (f2 + 12194.217 * 12194.217)
        
        let aWeight = numerator / denominator
        return aWeight
    }
}

// MARK: - Pipeline Builder
import Foundation
import QuartzCore

struct ProcessingPipeline {
    let stages: [Stage]
    private var lastProcessTime: TimeInterval = CACurrentMediaTime()
    private var frameTimes: [TimeInterval] = []
    private let maxSamples = 30

    static func build(config: Config) -> ProcessingPipeline {
        let stages: [Stage] = [
            WindowStage(type: .blackmanHarris, size: config.fftSize),
            FFTStage(size: config.fftSize),
            MagnitudeStage(convertToDb: false),
            MagnitudeStage(convertToDb: true),
            FrequencyBinningStage(config: config)
        ]
        return ProcessingPipeline(stages: stages)
    }

    mutating func process(pool: MemoryPool, config: Config) {
        let currentTime = CACurrentMediaTime()
        let deltaTime = currentTime - lastProcessTime
        lastProcessTime = currentTime

        // Ignore unreasonable delta (e.g., less than 0.001s or greater than 1s)
        if deltaTime > 0.001 && deltaTime < 1.0 {
            frameTimes.append(deltaTime)
            if frameTimes.count > maxSamples {
                frameTimes.removeFirst()
            }

            let averageDelta = frameTimes.reduce(0, +) / Double(frameTimes.count)
            let averageFPS = 1.0 / averageDelta
            print(String(format: "Average frame rate: %.2f FPS", averageFPS))
        }

        for stage in stages {
            stage.process(pool: pool, config: config)
        }
    }
}


