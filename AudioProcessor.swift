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
        
        // Counters
        private var fftCount: Int = 0
        private var fftCounterTimer: Timer?
        private var renderCount: Int = 0
        private var renderCounterTimer: Timer?
        
        // Thread safety
        private let processLock = NSLock()  // This was missing - you had 'lock' but used 'processLock'
        
        // Display update timer
        private var displayTimer: Timer?  // This was missing
        
        // Raw spectrum buffer (unsmoothed FFT output)
        private let rawSpectrumBuffer: UnsafeMutableBufferPointer<Float>
        
        // Working buffer for window extraction
        private let windowBuffer: UnsafeMutableBufferPointer<Float>
        
        // Published data (smoothed for display)
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
                
                let rawPtr = UnsafeMutablePointer<Float>.allocate(capacity: config.fft.outputBinCount)
                self.rawSpectrumBuffer = UnsafeMutableBufferPointer(start: rawPtr, count: config.fft.outputBinCount)
                rawSpectrumBuffer.initialize(repeating: -80.0)
                
                // Initialize published data
                self.spectrumData = Array(repeating: -80, count: config.fft.outputBinCount)
                
                configureAudioSession()
        }
        
        deinit {
                rawSpectrumBuffer.deallocate()
                windowBuffer.deallocate()
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
                
                // Start FFT counter timer
                fftCounterTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
                        print("FFTs per second: \(self?.fftCount ?? 0)")
                        self?.fftCount = 0
                }
                
                // Start render counter timer
                renderCounterTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
                        print("Frames rendered per second: \(self?.renderCount ?? 0)")
                        self?.renderCount = 0
                }
                
                // Start display update timer (60 Hz)
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
                fftCounterTimer?.invalidate()
                renderCounterTimer?.invalidate()
                playerNode.stop()
                engine.mainMixerNode.removeTap(onBus: 0)
                engine.stop()
        }
        
        private func handleAudioBuffer(_ buffer: AVAudioPCMBuffer) {
                guard let channelData = buffer.floatChannelData?[0] else { return }
                let frameLength = Int(buffer.frameLength)
                
                // Write to circular buffer
                circularBuffer.write(channelData, count: frameLength)
                
                // Process audio immediately
                processAudio()
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
                
                // Process the window WITHOUT smoothing - output goes to rawSpectrumBuffer
                analyzer.processWithoutSmoothing(windowBuffer.baseAddress!, output: rawSpectrumBuffer.baseAddress!)
                
                // Increment FFT counter
                fftCount += 1
                
                // Advance by hop size
                circularBuffer.advance(by: config.fft.hopSize)
        }
        
        @objc private func updateDisplay() {
                // Apply EMA smoothing ONLY here at render time
                processLock.lock()
                let rawData = Array(rawSpectrumBuffer)  // Copy current raw spectrum
                processLock.unlock()
                
                // Apply smoothing between current spectrumData and new raw data
                var smoothed = spectrumData  // Start with current smoothed values
                let alpha = config.rendering.smoothingFactor
                let beta = 1.0 - alpha
                
                for i in 0..<smoothed.count {
                        smoothed[i] = smoothed[i] * alpha + rawData[i] * beta
                }
                
                // Update published data on main thread
                DispatchQueue.main.async { [weak self] in
                        self?.spectrumData = smoothed
                        self?.renderCount += 1
                }
        }
        
        func triggerStudy() {
                guard !studyInProgress else { return }
                studyInProgress = true
                
                // Capture current analysis data
                let studyData = analyzer.captureStudyData()
                
                // Process study on background queue
                DispatchQueue.global(qos: .userInitiated).async { [weak self] in
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
