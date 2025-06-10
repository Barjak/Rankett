import Foundation
import AVFoundation

// MARK: - Audio Processor
final class AudioProcessor: ObservableObject {
        let store: TuningParameterStore
        private let circularBuffer: CircularBuffer
        
        // Audio engine
        private let engine = AVAudioEngine()
        
        // Thread safety
        private let bufferLock = NSLock()
        
        // Published state
        @Published var isRunning = false
        
        init(store: TuningParameterStore = .default) {
                self.store = store
                self.circularBuffer = CircularBuffer(capacity: store.circularBufferSize)
                configureAudioSession()
        }
        
        private func configureAudioSession() {
                do {
                        // Changed to .record for microphone input
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
                } catch {
                        print("Engine start error: \(error)")
                }
        }
        
        func stop() {
                // playerNode.stop() // Commented out
                engine.inputNode.removeTap(onBus: 0) // Changed from mainMixerNode to inputNode
                engine.stop()
                isRunning = false
        }
        
        private func handleAudioBuffer(_ buffer: AVAudioPCMBuffer) {
                guard let channelData = buffer.floatChannelData?[0] else { return }
                let frameLength = Int(buffer.frameLength)
                
                bufferLock.lock()
                circularBuffer.write(channelData, count: frameLength)
                bufferLock.unlock()
        }
        
        // MARK: - Public Data Access
        
        func getWindow(size: Int) -> [Float]? {
                bufferLock.lock()
                defer { bufferLock.unlock() }
                
                guard circularBuffer.hasEnoughData(size: size) else { return nil }
                
                let window = UnsafeMutablePointer<Float>.allocate(capacity: size)
                defer { window.deallocate() }
                
                let success = circularBuffer.getLatest(size: size, to: window)
                guard success else { return nil }  // Check success!
                
                return Array(UnsafeBufferPointer(start: window, count: size))
        }
        
        func hasWindow(size: Int) -> Bool {
                bufferLock.lock()
                defer { bufferLock.unlock() }
                return circularBuffer.hasEnoughData(size: size)
        }
}
