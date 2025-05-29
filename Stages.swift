import Foundation
import Accelerate
import QuartzCore

// MARK: - Window Processor
final class WindowProcessor {
    private let window: [Float]
    
    init(type: WindowType, size: Int) {
        self.window = type.createWindow(size: size)
    }
    
    func applyWindow(input: UnsafeMutablePointer<Float>, output: UnsafeMutablePointer<Float>, count: Int) {
        // Can do in-place if input == output
        vDSP_vmul(input, 1, window, 1, output, 1, vDSP_Length(count))
    }
}

// MARK: - FFT Processor
final class FFTProcessor {
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
    
    func forward(input: UnsafePointer<Float>,
                 realOutput: UnsafeMutablePointer<Float>,
                 imagOutput: UnsafeMutablePointer<Float>) {
        // Pack real input for FFT (even/odd split)
        for i in 0..<halfSize {
            realOutput[i] = input[i * 2]
            imagOutput[i] = input[i * 2 + 1]
        }
        
        // Create split complex structure
        var splitComplex = DSPSplitComplex(realp: realOutput, imagp: imagOutput)
        
        // Perform FFT in-place
        setup.forward(input: splitComplex, output: &splitComplex)
    }
}

// MARK: - Magnitude Processor
final class MagnitudeProcessor {
    private let convertToDb: Bool
    
    init(convertToDb: Bool = true) {
        self.convertToDb = convertToDb
    }
    
    func computeMagnitudes(real: UnsafePointer<Float>,
                          imag: UnsafePointer<Float>,
                          output: UnsafeMutablePointer<Float>,
                          count: Int) {
        var splitComplex = DSPSplitComplex(
            realp: UnsafeMutablePointer(mutating: real),
            imagp: UnsafeMutablePointer(mutating: imag)
        )
        
        // Calculate magnitudes
        vDSP_zvmags(&splitComplex, 1, output, 1, vDSP_Length(count))
        
        if convertToDb {
            // First clamp to avoid log(0)
            var floor: Float = 1e-10
            var ceiling: Float = Float.greatestFiniteMagnitude
            vDSP_vclip(output, 1, &floor, &ceiling, output, 1, vDSP_Length(count))
            
            // Convert to dB with reference = 1.0
            var reference: Float = 1.0
            vDSP_vdbcon(output, 1, &reference, output, 1, vDSP_Length(count), 1)
        }
    }
}

// MARK: - Frequency Mapper
final class FrequencyMapper {
    private let binMap: [Int]
    private let linearBinning: Bool
    
    init(config: Config) {
        if config.useLogFrequencyScale {
            self.binMap = Self.createLogBinMap(config: config)
            self.linearBinning = false
        } else {
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
    
    func mapBins(input: UnsafePointer<Float>,
                 output: UnsafeMutablePointer<Float>,
                 inputCount: Int,
                 outputCount: Int) {
        if linearBinning {
            // Just copy the first N bins
            let copyCount = min(outputCount, inputCount)
            memcpy(output, input, copyCount * MemoryLayout<Float>.size)
            
            // Fill remaining with minimum if needed
            if copyCount < outputCount {
                let minDB: Float = -80.0
                for i in copyCount..<outputCount {
                    output[i] = minDB
                }
            }
        } else {
            // Apply log frequency mapping
            for i in 0..<outputCount {
                output[i] = input[binMap[i]]
            }
        }
    }
}

// MARK: - Stats-based Suppressor
final class StatsSuppressor {
    private let fftSize: Int
    private let binCount: Int
    
    // Pre-allocated workspace
    private let dbMagnitudes: UnsafeMutablePointer<Float>
    
    init(fftSize: Int) {
        self.fftSize = fftSize
        self.binCount = fftSize / 2
        self.dbMagnitudes = UnsafeMutablePointer<Float>.allocate(capacity: binCount)
    }
    
    deinit {
        dbMagnitudes.deallocate()
    }
    
    func updateStatsAndSuppress(magnitudes: UnsafeMutablePointer<Float>,
                               mean: UnsafeMutablePointer<Float>,
                               variance: UnsafeMutablePointer<Float>,
                               count: Int) {
        let alpha: Float = 0.8
        let oneMinusAlpha = 1 - alpha
        
        var meanVar: Float = 0
        var maxVar: Float = 0
        
        // Step 1: Convert magnitude to dB and update running mean/variance
        for i in 0..<count {
            let mag = max(magnitudes[i], 1e-10)
            let db = 20 * log10(mag)
            dbMagnitudes[i] = db
            
            let currentMean = mean[i]
            let delta = db - currentMean
            mean[i] = alpha * currentMean + oneMinusAlpha * db
            variance[i] = alpha * variance[i] + oneMinusAlpha * delta * delta
        }
        
        // Step 2: Compute mean and max of variance
        for i in 0..<count {
            meanVar += variance[i]
            if variance[i] > maxVar {
                maxVar = variance[i]
            }
        }
        meanVar /= Float(count)
        
        // Step 3: Compute standard deviation of variance
        var sumSqDiff: Float = 0
        for i in 0..<count {
            let diff = variance[i] - meanVar
            sumSqDiff += diff * diff
        }
        let stdVar = sqrt(sumSqDiff / Float(count))
        let threshold = meanVar + 0.10 * stdVar
        
        // Step 4: Apply suppression
        for i in 0..<count {
            let currentVariance = variance[i]
            var suppress: Float = 1.0
            
            if currentVariance > threshold {
                let denom = maxVar - threshold + 1e-5
                let ratio = (currentVariance - threshold) / denom
                suppress = max(0.0, 1.0 - ratio)
            }
            
            magnitudes[i] *= suppress
        }
    }
}

// MARK: - HPS Processor
// MARK: - HPS Processor
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

enum TimbreType {
    case principal
    
    var harmonicProfile: [Float] {
        switch self {
        case .principal: return [1.0, 0.8, 0.6, 0.4, 0.2]

        }
    }
}

// MARK: - Spectrum Analyzer (replaces pipeline)
final class SpectrumAnalyzer {
    private let config: Config
    private let windowProcessor: WindowProcessor
    private let fftProcessor: FFTProcessor
    private let magnitudeProcessor: MagnitudeProcessor
    private let frequencyMapper: FrequencyMapper
    private let statsSuppressor: StatsSuppressor?
    
    private let study: Study
    private var studyCompletion: ((StudyResult) -> Void)?
    
    private var frameTimes: [TimeInterval] = []
    private let maxSamples = 30
    private var lastProcessTime: TimeInterval = CACurrentMediaTime()
    
    init(config: Config) {
        self.config = config
        self.study = Study(config: config)
        self.windowProcessor = WindowProcessor(type: .blackmanHarris, size: config.fftSize)
        self.fftProcessor = FFTProcessor(size: config.fftSize)
        self.magnitudeProcessor = MagnitudeProcessor(convertToDb: true)
        self.frequencyMapper = FrequencyMapper(config: config)
        
        // Optional stats suppressor
        if config.enableStatsSuppression {
            self.statsSuppressor = StatsSuppressor(fftSize: config.fftSize)
        } else {
            self.statsSuppressor = nil
        }
    }
    // In SpectrumAnalyzer
    func dispatchStudy(pool: MemoryPool, completion: @escaping (StudyResult) -> Void) {
        // Get FFT complex output
        let realPtr = pool.fftReal.pointer(in: pool)
        let imagPtr = pool.fftImag.pointer(in: pool)
        let fftCount = config.fftSize / 2
        
        // Get unwindowed time-domain data from circular buffer
        let timePtr = pool.windowWorkspace.pointer(in: pool)
        
        // Copy to arrays
        let fftReal = Array(UnsafeBufferPointer(start: realPtr, count: fftCount))
        let fftImag = Array(UnsafeBufferPointer(start: imagPtr, count: fftCount))
        let timeDomain = Array(UnsafeBufferPointer(start: timePtr, count: config.fftSize))
        
        // Dispatch study with raw data
        study.performStudy(
            fftReal: fftReal,
            fftImag: fftImag,
            timeDomain: timeDomain,
            sampleRate: Float(config.sampleRate),
            completion: completion
        )
    }
    
    
    func analyze(pool: MemoryPool) {
        let currentTime = CACurrentMediaTime()
        let deltaTime = currentTime - lastProcessTime
        lastProcessTime = currentTime
        
        // Track frame rate
        if deltaTime > 0.001 && deltaTime < 1.0 {
            frameTimes.append(deltaTime)
            if frameTimes.count > maxSamples {
                frameTimes.removeFirst()
            }
            
            let averageDelta = frameTimes.reduce(0, +) / Double(frameTimes.count)
            let averageFPS = 1.0 / averageDelta
            print(String(format: "Average frame rate: %.2f FPS", averageFPS))
        }
        
        // Get pointers to all buffers we'll use
        let windowInput = pool.windowWorkspace.pointer(in: pool)
        let fftReal = pool.fftReal.pointer(in: pool)
        let fftImag = pool.fftImag.pointer(in: pool)
        let magnitude = pool.magnitude.pointer(in: pool)
        let displayTarget = pool.displayTarget.pointer(in: pool)
        
        // Step 1: Apply window (in-place)
        windowProcessor.applyWindow(
            input: windowInput,
            output: windowInput,
            count: config.fftSize
        )
        
        // Step 2: Perform FFT
        fftProcessor.forward(
            input: windowInput,
            realOutput: fftReal,
            imagOutput: fftImag
        )
        
        // Step 3: Compute magnitudes
        magnitudeProcessor.computeMagnitudes(
            real: fftReal,
            imag: fftImag,
            output: magnitude,
            count: config.fftSize / 2
        )
        
        // Step 4: Optional stats-based suppression
        if let suppressor = statsSuppressor {
            let statsMean = pool.fftStatsMean.pointer(in: pool)
            let statsVar = pool.fftStatsVar.pointer(in: pool)
            
            suppressor.updateStatsAndSuppress(
                magnitudes: magnitude,
                mean: statsMean,
                variance: statsVar,
                count: config.fftSize / 2
            )
        }
        
        // Step 5: Map to output bins
        frequencyMapper.mapBins(
            input: magnitude,
            output: displayTarget,
            inputCount: config.fftSize / 2,
            outputCount: config.outputBinCount
        )
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
