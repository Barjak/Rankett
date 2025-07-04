import Foundation
import Atomics
import AVFoundation
import Accelerate




// MARK: - Audio Statistics
struct AudioStats {
        let totalSamplesProcessed: Int
        let bufferFillPercentage: Float
        let currentLevel: Float  // RMS level
        let peakLevel: Float
        let sampleRate: Double
        let uptimeSeconds: TimeInterval
}

// MARK: - Audio Processor (with position tracking)
final class AudioProcessor: ObservableObject {
        let store: TuningParameterStore
        private let circularBuffer: CircularBuffer<Float>
        
        // Audio engine
        private let engine = AVAudioEngine()
        
        // Statistics
        private let totalSamplesProcessed = ManagedAtomic<Int>(0)
        private var peakLevel: Float = 0.0
        private var currentRMS: Float = 0.0
        private let startTime = Date()
        
        // Published state
        @Published var isRunning = false
        @Published var stats = AudioStats(
                totalSamplesProcessed: 0,
                bufferFillPercentage: 0,
                currentLevel: 0,
                peakLevel: 0,
                sampleRate: 0,
                uptimeSeconds: 0
        )
        
        // Stats update timer
        private var statsTimer: Timer?
        
        init(store: TuningParameterStore = .default) {
                self.store = store
                self.circularBuffer = CircularBuffer(capacity: store.circularBufferSize)
                configureAudioSession()
        }
        
        private func configureAudioSession() {
                do {
                        try AVAudioSession.sharedInstance().setCategory(.record, mode: .measurement)
                        try AVAudioSession.sharedInstance().setActive(true)
                        store.audioSampleRate = AVAudioSession.sharedInstance().sampleRate
                } catch {
                        print("Audio session error: \(error)")
                }
        }
        
        func start() {
                engine.inputNode.removeTap(onBus: 0)
                
                if engine.isRunning {
                        engine.stop()
                }
                
                let format = engine.inputNode.outputFormat(forBus: 0)
                
                // Install tap - using the same buffer size and handling
                let tapBufferSize = AVAudioFrameCount(store.hopSize)
                engine.inputNode.installTap(onBus: 0, bufferSize: tapBufferSize, format: format) { [weak self] buffer, _ in
                        self?.handleAudioBuffer(buffer)
                }
                
                // Start engine
                do {
                        try engine.start()
                        isRunning = true
                        
                        // Start stats timer (update 10x per second)
                        statsTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                                self?.updateStats()
                        }
                } catch {
                        print("Engine start error: \(error)")
                }
        }
        
        func stop() {
                engine.inputNode.removeTap(onBus: 0)
                engine.stop()
                isRunning = false
                
                statsTimer?.invalidate()
                statsTimer = nil
        }
        
        private func handleAudioBuffer(_ buffer: AVAudioPCMBuffer) {
                guard let channelData = buffer.floatChannelData?[0] else { return }
                let frameLength = Int(buffer.frameLength)
                
                // Write to circular buffer
                _ = circularBuffer.write(channelData, count: frameLength)
                
                // Update total samples
                totalSamplesProcessed.wrappingIncrement(by: frameLength, ordering: .relaxed)
                
                // Calculate level metrics
                var rms: Float = 0
                var peak: Float = 0
                vDSP_rmsqv(channelData, 1, &rms, vDSP_Length(frameLength))
                vDSP_maxmgv(channelData, 1, &peak, vDSP_Length(frameLength))
                
                currentRMS = rms
                if peak > peakLevel {
                        peakLevel = peak
                }
        }
        
        private func updateStats() {
                let uptime = Date().timeIntervalSince(startTime)
                
                // Update published stats on main thread
                DispatchQueue.main.async { [weak self] in
                        guard let self = self else { return }
                        
                        self.stats = AudioStats(
                                totalSamplesProcessed: self.totalSamplesProcessed.load(ordering: .relaxed),
                                bufferFillPercentage: self.circularBuffer.getFillPercentage(),
                                currentLevel: self.currentRMS,
                                peakLevel: self.peakLevel,
                                sampleRate: self.store.audioSampleRate,
                                uptimeSeconds: uptime
                        )
                }
        }
        
        // MARK: - New Data Access Methods
        
        func getSamplesSince(position: Int) -> (samples: [Float], newPosition: Int)? {
                return circularBuffer.getSamplesSince(position: position)
        }
        
        func getAllRawSamples() -> [Float] {
                let result = circularBuffer.getAllSamples()
                return result.samples
        }
        
        func getCurrentPosition() -> Int {
                return circularBuffer.getCurrentPosition()
        }
        
        // MARK: - Legacy Data Access
        
        func getWindow(size: Int) -> [Float]? {
                guard circularBuffer.hasEnoughData(size: size) else { return nil }
                
                let window = UnsafeMutablePointer<Float>.allocate(capacity: size)
                defer { window.deallocate() }
                
                let success = circularBuffer.getLatest(size: size, to: window)
                guard success else { return nil }
                
                return Array(UnsafeBufferPointer(start: window, count: size))
        }
        
        func hasWindow(size: Int) -> Bool {
                return circularBuffer.hasEnoughData(size: size)
        }
        
        // MARK: - Debug helpers
        
        func printStats() {
                let samplesPerSecond = store.audioSampleRate > 0 ?
                Double(stats.totalSamplesProcessed) / (stats.uptimeSeconds + 0.01) : 0
                
                print("📊 Audio Stats: \(Int(samplesPerSecond)) samples/sec, buffer: \(Int(stats.bufferFillPercentage))%, level: \(String(format: "%.3f", stats.currentLevel))")
        }
        
        func resetPeakLevel() {
                peakLevel = 0.0
        }
}
