import Foundation
import AVFoundation
import Accelerate
import QuartzCore

// MARK: - Audio Processor
final class AudioProcessor: ObservableObject {
        let config: AnalyzerConfig
        private let analyzer: SpectrumAnalyzer
        private let circularBuffer: CircularBuffer
        
        // Audio engine
        private let engine = AVAudioEngine()
        private let playerNode = AVAudioPlayerNode()
        
        // Processing state
        private var lastProcessTime: TimeInterval = 0
        private let processLock = NSLock()
        
        // Display update timer
        private var displayTimer: Timer?
        
        // Working buffer for window extraction
        private let windowBuffer: UnsafeMutableBufferPointer<Float>
        
        // Output buffer for spectrum data
        private let outputBuffer: UnsafeMutableBufferPointer<Float>
        
        // Published data
        @Published var spectrumData: [Float] = []
        @Published var studyResult: StudyResult?
        
        @Published var studyInProgress = false
        
        
        init(config: AnalyzerConfig = .default) {
                self.config = config
                self.analyzer = SpectrumAnalyzer(config: config)
                self.circularBuffer = CircularBuffer(capacity: config.fft.circularBufferSize)
                
                // Allocate working buffers
                let windowPtr = UnsafeMutablePointer<Float>.allocate(capacity: config.fft.size)
                self.windowBuffer = UnsafeMutableBufferPointer(start: windowPtr, count: config.fft.size)
                
                let outputPtr = UnsafeMutablePointer<Float>.allocate(capacity: config.fft.outputBinCount)
                self.outputBuffer = UnsafeMutableBufferPointer(start: outputPtr, count: config.fft.outputBinCount)
                
                // Initialize published data
                self.spectrumData = Array(repeating: -80, count: config.fft.outputBinCount)
                
                configureAudioSession()
        }
        
        deinit {
                windowBuffer.deallocate()
                outputBuffer.deallocate()
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
                let tapBufferSize = AVAudioFrameCount(config.fft.hopSize)
                engine.mainMixerNode.installTap(onBus: 0, bufferSize: tapBufferSize, format: format) { [weak self] buffer, _ in
                        self?.handleAudioBuffer(buffer)
                }
                
                // Start display update timer
                displayTimer = Timer.scheduledTimer(withTimeInterval: config.rendering.frameInterval, repeats: true) { [weak self] _ in
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
                displayTimer?.invalidate()
                displayTimer = nil
                playerNode.stop()
                engine.mainMixerNode.removeTap(onBus: 0)
                engine.stop()
        }
        
        private func handleAudioBuffer(_ buffer: AVAudioPCMBuffer) {
                guard let channelData = buffer.floatChannelData?[0] else { return }
                let frameLength = Int(buffer.frameLength)
                
                // Write to circular buffer
                circularBuffer.write(channelData, count: frameLength)
                
                // Process if we have enough data and enough time has passed
                let now = CACurrentMediaTime()
                //if now - lastProcessTime >= config.rendering.frameInterval {
                        processAudio()
                        lastProcessTime = now
                //}
        }
        
        private func processAudio() {
                processLock.lock()
                defer { processLock.unlock() }
                
                // Check if we can extract a window
                guard circularBuffer.canExtractWindow(of: config.fft.size, at: 0) else { return }
                
                // Extract window to our buffer
                circularBuffer.extractWindow(
                        of: config.fft.size,
                        at: 0,
                        to: windowBuffer.baseAddress!
                )
                
                // Process the window
                analyzer.process(windowBuffer.baseAddress!, output: outputBuffer.baseAddress!)
                
                // Advance by hop size
                circularBuffer.advance(by: config.fft.hopSize)
        }
        
        @objc private func updateDisplay() {
                // The analyzer already applies smoothing internally, so we just need to copy the output
                DispatchQueue.main.async { [weak self] in
                        guard let self = self else { return }
                        self.spectrumData = Array(self.outputBuffer)
                }
        }
        
        func triggerStudy() {
                guard !studyInProgress else { return }
                studyInProgress = true
                
                // Capture current analysis data
                let studyData = analyzer.captureStudyData()
                
                // Process study on background queue
                DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                        // Assuming Study is defined elsewhere and has a method like this:
                        let result = Study.perform(
                                data: studyData,
                                config: self?.config ?? .default
                        )
                        
                        DispatchQueue.main.async {
                                self?.studyResult = result
                                self?.studyInProgress = false
                        }
                }
        }
}
