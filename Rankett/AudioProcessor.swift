import Foundation
import AVFoundation

// MARK: - Audio Processor
final class AudioProcessor: ObservableObject {
        let store: TuningParameterStore
        private let circularBuffer: CircularBuffer
        
        // Audio engine
        private let engine = AVAudioEngine()
        private let playerNode = AVAudioPlayerNode()
        
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
                        try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
                        try AVAudioSession.sharedInstance().setActive(true)
                } catch {
                        print("Audio session error: \(error)")
                }
        }
        
        func start() {
                guard let url = Bundle.main.url(forResource: "Test1", withExtension: "mp3"),
                      let audioFile = try? AVAudioFile(forReading: url) else {
                        print("Failed to load Test.mp3")
                        return
                }
                
                engine.mainMixerNode.removeTap(onBus: 0)
                
                // Stop engine if it's running
                if engine.isRunning {
                        engine.stop()
                }
                
                // Detach and reattach player node to ensure clean state
                if engine.attachedNodes.contains(playerNode) {
                        engine.detach(playerNode)
                }
                engine.attach(playerNode)
                let format = audioFile.processingFormat
                engine.connect(playerNode, to: engine.mainMixerNode, format: format)
                
                // Install tap
                let tapBufferSize = AVAudioFrameCount(store.hopSize)
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
                        isRunning = true
                } catch {
                        print("Engine start error: \(error)")
                }
        }
        
        func stop() {
                playerNode.stop()
                engine.mainMixerNode.removeTap(onBus: 0)
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
