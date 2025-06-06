import Foundation
import Accelerate

final class CircularBuffer {
        private let buffer: UnsafeMutableBufferPointer<Float>
        private let capacity: Int
        private var writeIndex = 0
        private var totalWritten = 0  // Track total samples written to know if we have enough
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
                
                let ptr = buffer.baseAddress!
                var samplesRemaining = count
                var sourceOffset = 0
                
                // Write in chunks, wrapping around as needed
                while samplesRemaining > 0 {
                        let chunkSize = min(samplesRemaining, capacity - writeIndex)
                        memcpy(ptr.advanced(by: writeIndex),
                               samples.advanced(by: sourceOffset),
                               chunkSize * MemoryLayout<Float>.size)
                        
                        writeIndex = (writeIndex + chunkSize) % capacity
                        sourceOffset += chunkSize
                        samplesRemaining -= chunkSize
                }
                
                totalWritten += count
        }
        
        /// Get the latest `size` samples
        func getLatest(size: Int, to destination: UnsafeMutablePointer<Float>) -> Bool {
                lock.lock()
                defer { lock.unlock() }
                
                // Make sure we've written at least `size` samples total
                guard totalWritten >= size else {
                        // Not enough data yet - fill with zeros
                        for i in 0..<size {
                                destination[i] = 0
                        }
                        return false
                }
                
                let ptr = buffer.baseAddress!
                
                // Calculate where to start reading to get the latest `size` samples
                let readStart = (writeIndex - size + capacity) % capacity
                
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
                lock.lock()
                defer { lock.unlock() }
                return totalWritten >= size
        }
}
