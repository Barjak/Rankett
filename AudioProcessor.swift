import Foundation
import AVFoundation
import QuartzCore

final class AudioProcessor: ObservableObject {
    private let config: Config
    private let pool: MemoryPool
    private var circularBuffer: CircularBuffer
    private let pipeline: ProcessingPipeline
    
    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    
    private var lastProcessTime: TimeInterval = 0
    private let processLock = NSLock()
    
    @Published var spectrumData: [Float] = []
    
    init(config: Config = Config()) {
        self.config = config
        self.pool = MemoryPool(config: config)
        self.circularBuffer = CircularBuffer(region: pool.circularBuffer)
        self.pipeline = ProcessingPipeline.build(config: config)
        
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
        playerNode.stop()
        engine.mainMixerNode.removeTap(onBus: 0)
        engine.stop()
    }
    
    private func handleAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData?[0] else { return }
        let frameLength = Int(buffer.frameLength)
        
        // Write to circular buffer
        circularBuffer.write(channelData, count: frameLength, to: pool)
        
        // Check if we should process (throttle to target framerate)
        let now = CACurrentMediaTime()
        if now - lastProcessTime >= config.frameInterval {
            processAudio()
            lastProcessTime = now
        }
    }
    
    private func processAudio() {
        processLock.lock()
        defer { processLock.unlock() }
        
        // Process all available windows (up to current write position)
        var windowsProcessed = 0
        let maxWindows = 4  // Process up to 4 windows per frame
        
        while windowsProcessed < maxWindows &&
              circularBuffer.canExtractWindow(of: config.fftSize, at: windowsProcessed * config.hopSize) {
            
            // Extract window to workspace
            guard circularBuffer.extractWindow(
                of: config.fftSize,
                at: windowsProcessed * config.hopSize,
                to: pool.windowWorkspace,
                in: pool
            ) else {
                break
            }
            
            // Run pipeline
            pipeline.process(pool: pool, config: config)
            windowsProcessed += 1
        }
        
        // Advance buffer by processed amount
        if windowsProcessed > 0 {
            circularBuffer.advance(by: windowsProcessed * config.hopSize)
            
            // Update published data from display buffer
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                let displayPtr = self.pool.displayCurrent.pointer(in: self.pool)
                self.spectrumData = Array(UnsafeBufferPointer(start: displayPtr, count: self.config.outputBinCount))
            }
        }
    }
}
