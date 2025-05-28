import Foundation
import Accelerate

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


// MARK: - Pipeline Builder
struct ProcessingPipeline {
    let stages: [Stage]
    
    static func build(config: Config) -> ProcessingPipeline {
        let stages: [Stage] = [
            WindowStage(type: .blackmanHarris, size: config.fftSize),
            FFTStage(size: config.fftSize),
            MagnitudeStage(convertToDb: true),
            FrequencyBinningStage(config: config),
            //SmoothingStage()
        ]
        return ProcessingPipeline(stages: stages)
    }
    
    func process(pool: MemoryPool, config: Config) {
        for stage in stages {
            stage.process(pool: pool, config: config)
        }
    }
}
