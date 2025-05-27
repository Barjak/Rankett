import SwiftUI
import AVFoundation
import Accelerate

// MARK: - Configuration
struct SpectrumAnalyzerConfig {
    // FFT Parameters
    let fftSize: Int = 4096  // Gives ~10.77Hz resolution at 44.1kHz
    let sampleRate: Double = 44100
    
    // Display Parameters
    let outputBinCount: Int = 512  // Number of bins to display
    let useLogFrequencyScale: Bool = true
    let minFrequency: Double = 20.0  // Hz
    let maxFrequency: Double = 20000.0  // Hz
    
    // Processing Parameters
    let overlapRatio: Double = 0.20  // 0.0 to 1.0 (0.75 = 75% overlap)
    let smoothingFactor: Float = 0.95  // 0.0 to 1.0 (higher = more smoothing)
    
    // Performance Parameters
    let updateRateHz: Double = 60.0  // Display update rate
    let processOnBackgroundQueue: Bool = true
    
    // Computed properties
    var hopSize: Int {
        Int(Double(fftSize) * (1.0 - overlapRatio))
    }
    
    var frequencyResolution: Double {
        sampleRate / Double(fftSize)
    }
    
    var nyquistFrequency: Double {
        sampleRate / 2.0
    }
}

// MARK: - Window Functions
enum WindowType {
    case blackmanHarris
    case hann
    case hamming
    
    func createWindow(size: Int) -> [Float] {
        switch self {
        case .blackmanHarris:
            return createBlackmanHarrisWindow(size: size)
        case .hann:
            return vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: size, isHalfWindow: false)
        case .hamming:
            return vDSP.window(ofType: Float.self, usingSequence: .hamming, count: size, isHalfWindow: false)
        }
    }
}

func createBlackmanHarrisWindow(size: Int) -> [Float] {
    let coefficients: [Float] = [0.35875, 0.48829, 0.14128, 0.01168]
    var window = [Float](repeating: 0, count: size)
    
    for i in 0..<size {
        let x = 2.0 * Float.pi * Float(i) / Float(size - 1)
        window[i] = coefficients[0]
                  - coefficients[1] * cos(x)
                  + coefficients[2] * cos(2 * x)
                  - coefficients[3] * cos(3 * x)
    }
    
    return window
}

// MARK: - Spectrum View
struct SpectrumView: UIViewRepresentable {
    let spectrumData: [Float]
    let config: SpectrumAnalyzerConfig
    
    func makeUIView(context: Context) -> SpectrumGraphView {
        let view = SpectrumGraphView()
        view.config = config
        view.isOpaque = true
        view.backgroundColor = .black
        return view
    }
    
    func updateUIView(_ uiView: SpectrumGraphView, context: Context) {
        uiView.spectrumData = spectrumData
        uiView.setNeedsDisplay()
    }
}

class SpectrumGraphView: UIView {
    var spectrumData: [Float] = []
    var config = SpectrumAnalyzerConfig()
    
    override func draw(_ rect: CGRect) {
        guard spectrumData.count > 1 else { return }
        
        guard let context = UIGraphicsGetCurrentContext() else { return }
        
        // Styling
        context.setStrokeColor(UIColor.systemBlue.cgColor)
        context.setLineWidth(2)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        
        let padding: CGFloat = 20
        let drawableWidth = rect.width - (2 * padding)
        let drawableHeight = rect.height - (2 * padding)
        
        // Dynamic range for dB scale
        let minDB: Float = -160
        let maxDB: Float = 100
        let dbRange = maxDB - minDB
        
        // Draw frequency grid lines
        drawFrequencyGrid(context: context, rect: rect, padding: padding)
        
        // Draw spectrum
        context.beginPath()
        
        for i in 0..<spectrumData.count {
            let x = padding + (CGFloat(i) * drawableWidth / CGFloat(spectrumData.count - 1))
            
            // Clamp and normalize dB value
            let dbValue = max(minDB, min(maxDB, spectrumData[i]))
            let normalizedValue = (dbValue - minDB) / dbRange
            let y = padding + drawableHeight * (1 - CGFloat(normalizedValue))
            
            if i == 0 {
                context.move(to: CGPoint(x: x, y: y))
            } else {
                context.addLine(to: CGPoint(x: x, y: y))
            }
        }
        
        context.strokePath()
    }
    
    private func drawFrequencyGrid(context: CGContext, rect: CGRect, padding: CGFloat) {
        context.saveGState()
        context.setStrokeColor(UIColor.systemGray.withAlphaComponent(0.3).cgColor)
        context.setLineWidth(1)
        
        // Draw horizontal dB grid lines
        let dbLines: [Float] = [0, -20, -40, -60]
        for db in dbLines {
            let normalizedValue = (db - (-80)) / 80.0
            let y = padding + (rect.height - 2 * padding) * (1 - CGFloat(normalizedValue))
            
            context.move(to: CGPoint(x: padding, y: y))
            context.addLine(to: CGPoint(x: rect.width - padding, y: y))
        }
        
        context.strokePath()
        context.restoreGState()
    }
}

// MARK: - Audio Processor
class AudioProcessor: ObservableObject {
    private let config: SpectrumAnalyzerConfig
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
    
    init(config: SpectrumAnalyzerConfig = SpectrumAnalyzerConfig()) {
        self.config = config
        self.spectrumData = Array(repeating: Float(-80), count: config.outputBinCount)
        
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
                    windowedSamples[j] = circularBuffer[idx]// * window[j]
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
                
                // Apply frequency binning if needed
                if config.useLogFrequencyScale {
                    dbMagnitudes = applyFrequencyBinning(dbMagnitudes)
                } else {
                    // Just take the first outputBinCount bins
                    dbMagnitudes = Array(dbMagnitudes.prefix(config.outputBinCount))
                }
                
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

// MARK: - Main View
struct ContentView: View {
    @StateObject private var audioProcessor: AudioProcessor
    @State private var showSettings = false
    
    init() {
        // Create custom config if needed
        let config = SpectrumAnalyzerConfig()
        _audioProcessor = StateObject(wrappedValue: AudioProcessor(config: config))
    }
    
    var body: some View {
        VStack {
            Text("Spectrum Analyzer")
                .font(.title)
                .padding()
            
            SpectrumView(spectrumData: audioProcessor.spectrumData,
                        config: SpectrumAnalyzerConfig())
                .frame(height: 300)
                .padding()
                .background(Color.black)
                .cornerRadius(10)
            
            HStack {
                Text("Frequency Resolution: \(String(format: "%.2f Hz", SpectrumAnalyzerConfig().frequencyResolution))")
                Spacer()
                Text("FFT Size: \(SpectrumAnalyzerConfig().fftSize)")
            }
            .font(.caption)
            .padding(.horizontal)
            
            Spacer()
        }
        .onAppear {
            audioProcessor.start()
        }
        .onDisappear {
            audioProcessor.stop()
        }
    }
}

// MARK: - App
@main
struct SpectrumAnalyzerApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
