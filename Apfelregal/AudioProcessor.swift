import AVFoundation
import Foundation
import Accelerate

final class CircularBuffer {
        private let buffer: UnsafeMutableBufferPointer<Float>
        private let capacity: Int
        
        // Use atomic properties instead of locks
        private var writeIndex = AtomicInt(0)
        private var totalWritten = AtomicInt(0)
        
        init(capacity: Int) {
                self.capacity = capacity
                let ptr = UnsafeMutablePointer<Float>.allocate(capacity: capacity)
                self.buffer = UnsafeMutableBufferPointer(start: ptr, count: capacity)
                buffer.initialize(repeating: 0)
        }
        
        deinit {
                buffer.deallocate()
        }
        
        func write(_ samples: UnsafePointer<Float>, count: Int) {
                let currentWriteIndex = writeIndex.load()
                let ptr = buffer.baseAddress!
                var samplesRemaining = count
                var sourceOffset = 0
                var localWriteIndex = currentWriteIndex
                
                // Write in chunks, wrapping around as needed
                while samplesRemaining > 0 {
                        let chunkSize = min(samplesRemaining, capacity - localWriteIndex)
                        memcpy(ptr.advanced(by: localWriteIndex),
                               samples.advanced(by: sourceOffset),
                               chunkSize * MemoryLayout<Float>.size)
                        
                        localWriteIndex = (localWriteIndex + chunkSize) % capacity
                        sourceOffset += chunkSize
                        samplesRemaining -= chunkSize
                }
                
                // Update indices atomically
                writeIndex.store(localWriteIndex)
                totalWritten.add(count)
        }
        
        /// Get the latest `size` samples
        func getLatest(size: Int, to destination: UnsafeMutablePointer<Float>) -> Bool {
                // Make sure we've written at least `size` samples total
                guard totalWritten.load() >= size else {
                        // Not enough data yet - fill with zeros
                        for i in 0..<size {
                                destination[i] = 0
                        }
                        return false
                }
                
                let currentWriteIndex = writeIndex.load()
                let ptr = buffer.baseAddress!
                
                // Calculate where to start reading to get the latest `size` samples
                let readStart = (currentWriteIndex - size + capacity) % capacity
                
                // Read in up to two chunks
                let firstChunkSize = min(size, capacity - readStart)
                memcpy(destination, ptr.advanced(by: readStart), firstChunkSize * MemoryLayout<Float>.size)
                
                if size > firstChunkSize {
                        let secondChunkSize = size - firstChunkSize
                        memcpy(destination.advanced(by: firstChunkSize), ptr, secondChunkSize * MemoryLayout<Float>.size)
                }
                
                return true
        }
        
        /// Check if we have at least `size` samples
        func hasEnoughData(size: Int) -> Bool {
                return totalWritten.load() >= size
        }
}

// Simple atomic integer wrapper
final class AtomicInt {
        private let value: UnsafeMutablePointer<Int32>
        
        init(_ initialValue: Int) {
                value = UnsafeMutablePointer<Int32>.allocate(capacity: 1)
                value.initialize(to: Int32(initialValue))
        }
        
        deinit {
                value.deallocate()
        }
        
        func load() -> Int {
                return Int(OSAtomicAdd32(0, value))
        }
        
        func store(_ newValue: Int) {
                while true {
                        let current = load()
                        if OSAtomicCompareAndSwap32(Int32(current), Int32(newValue), value) {
                                break
                        }
                }
        }
        
        func add(_ delta: Int) -> Int {
                return Int(OSAtomicAdd32(Int32(delta), value))
        }
}

// MARK: - Audio Processor (minimal changes)
final class AudioProcessor: ObservableObject {
        let store: TuningParameterStore
        private let circularBuffer: CircularBuffer
        
        // Audio engine
        private let engine = AVAudioEngine()
        
        // Remove the lock - no longer needed
        // private let bufferLock = NSLock()
        
        // Published state
        @Published var isRunning = false
        
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
                } catch {
                        print("Engine start error: \(error)")
                }
        }
        
        func stop() {
                engine.inputNode.removeTap(onBus: 0)
                engine.stop()
                isRunning = false
        }
        
        private func handleAudioBuffer(_ buffer: AVAudioPCMBuffer) {
                guard let channelData = buffer.floatChannelData?[0] else { return }
                let frameLength = Int(buffer.frameLength)
                
                // No lock needed - write is atomic
                circularBuffer.write(channelData, count: frameLength)
        }
        
        // MARK: - Public Data Access
        
        func getWindow(size: Int) -> [Float]? {
                // No lock needed
                guard circularBuffer.hasEnoughData(size: size) else { return nil }
                
                let window = UnsafeMutablePointer<Float>.allocate(capacity: size)
                defer { window.deallocate() }
                
                let success = circularBuffer.getLatest(size: size, to: window)
                guard success else { return nil }
                
                return Array(UnsafeBufferPointer(start: window, count: size))
        }
        
        func hasWindow(size: Int) -> Bool {
                // No lock needed
                return circularBuffer.hasEnoughData(size: size)
        }
}
