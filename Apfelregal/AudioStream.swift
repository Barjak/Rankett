import Foundation
import Atomics
import AVFoundation
import Accelerate

struct AudioStats {
        let totalSamplesStreamed: Int
        let currentLevel: Double
        let peakLevel: Double
        let sampleRate: Double
        let uptimeSeconds: TimeInterval
}

final class AudioStream: ObservableObject {
        let store: TuningParameterStore
        private let circularBuffer: CircularBuffer<Float>
        
        private let engine = AVAudioEngine()
        
        private let totalSamplesStreamed = ManagedAtomic<Int>(0)
        private var peakLevel: Float = 0.0
        private var currentRMS: Float = 0.0
        private let startTime = Date()
        
        @Published var isRunning = false
        @Published var stats = AudioStats(
                totalSamplesStreamed: 0,
                currentLevel: 0,
                peakLevel: 0,
                sampleRate: 0,
                uptimeSeconds: 0
        )
        
        private var statsTimer: Timer?
        private var conversionBuffer: [Double]

        
        init(store: TuningParameterStore = .default) {
                self.store = store
                self.circularBuffer = CircularBuffer(capacity: store.circularBufferSize)
                self.conversionBuffer = [Double](repeating: 0, count: store.circularBufferSize)

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
                let tapBufferSize = AVAudioFrameCount(store.hopSize)
                
                engine.inputNode.installTap(onBus: 0, bufferSize: tapBufferSize, format: format) { [weak self] buffer, _ in
                        self?.handleAudioBuffer(buffer)
                }
                
                do {
                        try engine.start()
                        isRunning = true
                        
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
                guard let floatData = buffer.floatChannelData?[0] else { return }
                let frameLength = Int(buffer.frameLength)
                
                _ = circularBuffer.write(floatData, count: frameLength)
                totalSamplesStreamed.wrappingIncrement(by: frameLength, ordering: .relaxed)
                
                var rms: Float = 0
                var peak: Float = 0
                vDSP_rmsqv(floatData, 1, &rms, vDSP_Length(frameLength))
                vDSP_maxmgv(floatData, 1, &peak, vDSP_Length(frameLength))
                
                currentRMS = rms
                if peak > peakLevel {
                        peakLevel = peak
                }
        }
        
        private func updateStats() {
                let uptime = Date().timeIntervalSince(startTime)
                
                DispatchQueue.main.async { [weak self] in
                        guard let self = self else { return }
                        
                        self.stats = AudioStats(
                                totalSamplesStreamed: self.totalSamplesStreamed.load(ordering: .relaxed),
                                currentLevel: Double(self.currentRMS),
                                peakLevel: Double(self.peakLevel),
                                sampleRate: self.store.audioSampleRate,
                                uptimeSeconds: uptime
                        )
                }
        }
        
        func read(count: Int? = nil,
                  from position: ReadPosition = .mostRecent,
                  after: Int? = nil) -> (samples: [Float], bookmark: Int) {
                return circularBuffer.read(count: count, from: position, after: after)
        }
        
        func readAsDouble(count: Int? = nil,
                          from position: ReadPosition = .mostRecent,
                          after: Int? = nil) -> (samples: ArraySlice<Double>, bookmark: Int) {
                let (floatSamples, bookmark) = circularBuffer.read(count: count, from: position, after: after)
                
                if floatSamples.count > conversionBuffer.count {
                        conversionBuffer = [Double](repeating: 0, count: floatSamples.count)
                }
                
                floatSamples.withUnsafeBufferPointer { src in
                        conversionBuffer.withUnsafeMutableBufferPointer { dst in
                                vDSP_vspdp(src.baseAddress!, 1, dst.baseAddress!, 1, vDSP_Length(floatSamples.count))
                        }
                }
                
                return (conversionBuffer[0..<floatSamples.count], bookmark)
        }
        
        func resetPeakLevel() {
                peakLevel = 0.0
        }
}
