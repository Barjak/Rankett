import Foundation
import Accelerate

final class CircularBuffer {
        private let buffer: UnsafeMutableBufferPointer<Float>
        private let capacity: Int
        private var writeIndex = 0
        private var readIndex = 0  // Add explicit read index
        private var availableSamples = 0
        private let lock = NSLock()
        
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
                lock.lock()
                defer { lock.unlock() }
                
                // Check if we're about to overwrite unread data
                let spaceAvailable = capacity - availableSamples
                if count > spaceAvailable {
                        print("Warning: Buffer overflow! Dropping \(count - spaceAvailable) samples")
                        // Advance read index to make room
                        let toDrop = count - spaceAvailable
                        readIndex = (readIndex + toDrop) % capacity
                        availableSamples -= toDrop
                }
                
                let ptr = buffer.baseAddress!
                let toWrite = min(count, capacity)
                
                // Write in up to two chunks (before and after wrap)
                let firstChunkSize = min(toWrite, capacity - writeIndex)
                memcpy(ptr.advanced(by: writeIndex), samples, firstChunkSize * MemoryLayout<Float>.size)
                
                if toWrite > firstChunkSize {
                        let secondChunkSize = toWrite - firstChunkSize
                        memcpy(ptr, samples.advanced(by: firstChunkSize), secondChunkSize * MemoryLayout<Float>.size)
                }
                
                writeIndex = (writeIndex + toWrite) % capacity
                availableSamples = min(availableSamples + toWrite, capacity)
        }
        
        func canExtractWindow(of size: Int, at offset: Int = 0) -> Bool {
                lock.lock()
                defer { lock.unlock()  }
                return availableSamples >= size + offset
        }
        
        @discardableResult
        func extractWindow(of size: Int, at offset: Int = 0, to destination: UnsafeMutablePointer<Float>) -> Bool {
                lock.lock()
                defer { lock.unlock() }
                
                guard availableSamples >= size + offset else {
                        print("Warning: Not enough samples. Requested: \(size + offset), available: \(availableSamples)")
                        return false
                }
                
                let ptr = buffer.baseAddress!
                // Calculate actual read position with offset
                let readPos = (readIndex + offset) % capacity
                
                // Read in up to two chunks (before and after wrap)
                let firstChunkSize = min(size, capacity - readPos)
                memcpy(destination, ptr.advanced(by: readPos), firstChunkSize * MemoryLayout<Float>.size)
                
                if size > firstChunkSize {
                        let secondChunkSize = size - firstChunkSize
                        memcpy(destination.advanced(by: firstChunkSize), ptr, secondChunkSize * MemoryLayout<Float>.size)
                }
                
                return true
        }
        
        func advance(by samples: Int) {
                guard samples > 0 else { return }
                lock.lock()
                defer { lock.unlock() }
                
                let toAdvance = min(samples, availableSamples)
                readIndex = (readIndex + toAdvance) % capacity
                availableSamples -= toAdvance
                
                if toAdvance < samples {
                        print("Warning: Tried to advance by \(samples) but only \(toAdvance) samples available")
                }
        }
        
        // Debug helper
        var debugInfo: String {
                lock.lock()
                defer { lock.unlock() }
                return "CircularBuffer: writeIndex=\(writeIndex), readIndex=\(readIndex), available=\(availableSamples), capacity=\(capacity)"
        }
}
