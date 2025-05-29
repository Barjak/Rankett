import Foundation
import AVFoundation
import Accelerate
import QuartzCore

final class AudioProcessor: ObservableObject {
    private let config: Config
    private let pool: MemoryPool
    private var circularBuffer: CircularBuffer
    private let analyzer: SpectrumAnalyzer
    
    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    
    private var lastProcessTime: TimeInterval = 0
    private let processLock = NSLock()
    
    private var smoothingTimer: Timer?
    
    @Published var spectrumData: [Float] = []
    
    init(config: Config = Config()) {
        self.config = config
        self.pool = MemoryPool(config: config)
        self.circularBuffer = CircularBuffer(region: pool.circularBuffer)
        self.analyzer = SpectrumAnalyzer(config: config)
        
        // Initialize published data
        self.spectrumData = Array(repeating: -80, count: config.outputBinCount)
        
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
    
    func start() {
        guard let url = Bundle.main.url(forResource: "Test", withExtension: "mp3"),
              let audioFile = try? AVAudioFile(forReading: url) else {
            print("Failed to load Test.mp3")
            return
        }
        
        engine.attach(playerNode)
        let format = audioFile.processingFormat
        engine.connect(playerNode, to: engine.mainMixerNode, format: format)
        
        // Install tap
        let tapBufferSize = AVAudioFrameCount(1024)
        engine.mainMixerNode.installTap(onBus: 0, bufferSize: tapBufferSize, format: format) { [weak self] buffer, _ in
            self?.handleAudioBuffer(buffer)
        }
        
        smoothingTimer = Timer.scheduledTimer(withTimeInterval: config.frameInterval, repeats: true) { [weak self] _ in
            self?.updateDisplay()
        }

        // Start engine and playback
        do {
            try engine.start()
            playerNode.scheduleFile(audioFile, at: nil) { [weak self] in
                // Loop playback
                DispatchQueue.main.async {
                    self?.playerNode.scheduleFile(audioFile, at: nil, completionHandler: nil)
                    self?.playerNode.play()
                }
            }
            playerNode.play()
        } catch {
            print("Engine start error: \(error)")
        }
    }
    
    func stop() {
        smoothingTimer?.invalidate()
        smoothingTimer = nil
        playerNode.stop()
        engine.mainMixerNode.removeTap(onBus: 0)
        engine.stop()
    }
    
    private func handleAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData?[0] else { return }
        let frameLength = Int(buffer.frameLength)
        
        // Write to circular buffer
        circularBuffer.write(channelData, count: frameLength, to: pool)
        
        // Process if we have enough data and enough time has passed
        let now = CACurrentMediaTime()
        if now - lastProcessTime >= config.frameInterval {
            processAudio()
            lastProcessTime = now
        }
    }
    
    private func processAudio() {
        processLock.lock()
        defer { processLock.unlock() }
        
        // Process only one window per frame
        if circularBuffer.canExtractWindow(of: config.fftSize, at: 0) {
            // Extract window to workspace
            guard circularBuffer.extractWindow(
                of: config.fftSize,
                at: 0,
                to: pool.windowWorkspace,
                in: pool
            ) else {
                return
            }
            
            // Run analysis
            analyzer.analyze(pool: pool)
            
            // Advance by hop size (smaller hop for better time resolution)
            circularBuffer.advance(by: config.hopSize)
        }
    }
    
    @objc private func updateDisplay() {
        let currentPtr = pool.displayCurrent.pointer(in: pool)
        let targetPtr = pool.displayTarget.pointer(in: pool)
        
        // Apply smoothing
        Smoothing.apply(
            current: currentPtr,
            target: targetPtr,
            count: config.outputBinCount,
            smoothingFactor: config.smoothingFactor
        )
        
        // Update published data
        DispatchQueue.main.async {
            self.spectrumData = Array(
                UnsafeBufferPointer(start: currentPtr, count: self.config.outputBinCount)
            )
        }
    }
}
