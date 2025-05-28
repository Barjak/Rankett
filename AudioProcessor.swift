// TODO: some of this logic has been moved to the ./stages/ directory
// TODO: we need to write a pipeline builder
import SwiftUI
import AVFoundation
import Accelerate
import Foundation
// MARK: - Audio Processor
class AudioProcessor: ObservableObject {
    public let config: SpectrumAnalyzerConfig
    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    
    // FFT Setup
    private var fftSetup: vDSP.FFT<DSPSplitComplex>!
    private var window: [Float]
    private let windowType: WindowType = .blackmanHarris
    
    // Buffers
    private var circularBuffer: [Float]
    private var writeIndex = 0
    private var processedSamples = 0
    private let bufferLock = NSLock()
    
    // Processing
    private let processingQueue = DispatchQueue(label: "spectrum.processing", qos: .userInteractive)
    private var updateTimer: Timer?
    private var latestMagnitudes: [Float] = []
    
    // Frequency bin mapping (for log scale)
    private var frequencyBinMap: [Int] = []
    
    @Published var spectrumData: [Float]
    @Published var frequencyData: [Float] = []  // NEW: Store frequency values for each bin
    
    init(config: SpectrumAnalyzerConfig = SpectrumAnalyzerConfig()) {
        self.config = config
        
        // Initialize spectrum data based on whether we're using binning
        if config.useFrequencyBinning {
            self.spectrumData = Array(repeating: Float(-80), count: config.outputBinCount)
        } else {
            // When not binning, we'll use half the FFT size (Nyquist)
            self.spectrumData = Array(repeating: Float(-80), count: config.fftSize / 2)
        }
        
        // Initialize FFT
        let log2n = vDSP_Length(log2(Float(config.fftSize)))
        guard let fftSetup = vDSP.FFT(log2n: log2n, radix: .radix2, ofType: DSPSplitComplex.self) else {
            fatalError("Failed to create FFT setup")
        }
        self.fftSetup = fftSetup
        
        // Create window
        self.window = windowType.createWindow(size: config.fftSize)
        
        // Initialize circular buffer (2x size for safety)
        self.circularBuffer = Array(repeating: 0, count: config.fftSize * 2)
        
        // Create frequency bin mapping if using log scale
        if config.useLogFrequencyScale {
            self.frequencyBinMap = createLogFrequencyBinMap()
        }
        
        // Configure audio session
        configureAudioSession()
        if !config.useFrequencyBinning {
                createFrequencyArray()
            }
    }
    
    private func createFrequencyArray() {
            let halfSize = config.fftSize / 2
            frequencyData = []
            
            for i in 0..<halfSize {
                let frequency = Double(i) * config.frequencyResolution
                frequencyData.append(Float(frequency))
            }
        }
    
    private func configureAudioSession() {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            print("Audio session error: \(error)")
        }
    }
    
    private func createLogFrequencyBinMap() -> [Int] {
        var binMap: [Int] = []
        
        let logMin = log10(config.minFrequency)
        let logMax = log10(min(config.maxFrequency, config.nyquistFrequency))
        
        for i in 0..<config.outputBinCount {
            let logFreq = logMin + (logMax - logMin) * Double(i) / Double(config.outputBinCount - 1)
            let freq = pow(10, logFreq)
            let binIndex = Int(freq / config.frequencyResolution)
            binMap.append(min(binIndex, config.fftSize / 2 - 1))
        }
        
        return binMap
    }
    
    func start() {
        guard let url = Bundle.main.url(forResource: "Test", withExtension: "mp3"),
              
              let audioFile = try? AVAudioFile(forReading: url) else {
            print("Failed to load Test.mp3")
            
            return
        }
        
        engine.attach(playerNode)
        let format = audioFile.processingFormat
        engine.connect(playerNode, to: engine.mainMixerNode, format: format)
        
        // Install tap with appropriate buffer size
        let tapBufferSize = AVAudioFrameCount(config.hopSize)
        engine.mainMixerNode.installTap(onBus: 0, bufferSize: tapBufferSize, format: format) { buffer, _ in
            self.processAudioBuffer(buffer)
        }
        
        // Start update timer
        updateTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / config.updateRateHz, repeats: true) { _ in
            self.updateSpectrum()
        }
        
        // Start engine and playback
        do {
            try engine.start()
            playerNode.scheduleFile(audioFile, at: nil) {
                // Loop the file
                DispatchQueue.main.async {
                    self.playerNode.scheduleFile(audioFile, at: nil, completionHandler: nil)
                    self.playerNode.play()
                }
            }
            playerNode.play()
        } catch {
            print("Engine start error: \(error)")
        }
    }
    
    private func processAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData?[0] else { return }
        let frameLength = Int(buffer.frameLength)
        
        bufferLock.lock()
        defer { bufferLock.unlock() }
        
        // Write to circular buffer
        for i in 0..<frameLength {
            circularBuffer[writeIndex] = channelData[i]
            writeIndex = (writeIndex + 1) % circularBuffer.count
            processedSamples += 1
            
            // Check if we have enough samples for FFT
            if processedSamples >= config.fftSize && processedSamples % config.hopSize == 0 {
                // Extract window of samples
                var windowedSamples = [Float](repeating: 0, count: config.fftSize)
                let startIndex = (writeIndex - config.fftSize + circularBuffer.count) % circularBuffer.count
                
                for j in 0..<config.fftSize {
                    let idx = (startIndex + j) % circularBuffer.count
                    windowedSamples[j] = circularBuffer[idx] * window[j]
                }
                
                // Process FFT on appropriate queue
                if config.processOnBackgroundQueue {
                    let samples = windowedSamples
                    processingQueue.async {
                        self.computeFFT(from: samples)
                    }
                } else {
                    computeFFT(from: windowedSamples)
                }
            }
        }
    }
    
    private func computeFFT(from samples: [Float]) {
        let halfSize = config.fftSize / 2
        
        // Prepare split complex format for real FFT
        var realPart = [Float](repeating: 0, count: halfSize)
        var imagPart = [Float](repeating: 0, count: halfSize)
        
        // Pack real input for FFT (even/odd split)
        for i in 0..<halfSize {
            realPart[i] = samples[i * 2]
            imagPart[i] = samples[i * 2 + 1]
        }
        
        realPart.withUnsafeMutableBufferPointer { realPtr in
            imagPart.withUnsafeMutableBufferPointer { imagPtr in
                var splitComplex = DSPSplitComplex(realp: realPtr.baseAddress!, imagp: imagPtr.baseAddress!)
                
                // Perform FFT
                fftSetup.forward(input: splitComplex, output: &splitComplex)
                
                // Calculate magnitudes
                var magnitudes = [Float](repeating: 0, count: halfSize)
                vDSP_zvmags(&splitComplex, 1, &magnitudes, 1, vDSP_Length(halfSize))
                
                // Convert to dB
                var dbMagnitudes = magnitudes.map { magnitude in
                    20 * log10(max(magnitude, 1e-10))
                }
                
                // Apply frequency binning if enabled
                if config.useFrequencyBinning && config.useLogFrequencyScale {
                    dbMagnitudes = applyFrequencyBinning(dbMagnitudes)
                } else if config.useFrequencyBinning {
                    // Linear binning - just take the first outputBinCount bins
                    dbMagnitudes = Array(dbMagnitudes.prefix(config.outputBinCount))
                }
                // If not using binning, keep all the data
                
                // Store latest magnitudes
                bufferLock.lock()
                self.latestMagnitudes = dbMagnitudes
                bufferLock.unlock()
            }
        }
    }

    
    private func applyFrequencyBinning(_ linearMagnitudes: [Float]) -> [Float] {
        var binnedMagnitudes = [Float](repeating: -80, count: config.outputBinCount)
        
        for i in 0..<config.outputBinCount {
            let binIndex = frequencyBinMap[i]
            if binIndex < linearMagnitudes.count {
                binnedMagnitudes[i] = linearMagnitudes[binIndex]
            }
        }
        
        return binnedMagnitudes
    }
    
    private func updateSpectrum() {
        bufferLock.lock()
        let magnitudes = latestMagnitudes
        bufferLock.unlock()
        
        guard !magnitudes.isEmpty else { return }
        
        // Apply smoothing
        DispatchQueue.main.async {
            for i in 0..<min(magnitudes.count, self.spectrumData.count) {
                self.spectrumData[i] = self.config.smoothingFactor * self.spectrumData[i] +
                                      (1 - self.config.smoothingFactor) * magnitudes[i]
            }
        }
    }
    
    func stop() {
        updateTimer?.invalidate()
        updateTimer = nil
        playerNode.stop()
        engine.mainMixerNode.removeTap(onBus: 0)
        engine.stop()
    }
}
