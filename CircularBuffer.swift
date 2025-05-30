import Foundation
import Accelerate

struct CircularBuffer {
        let region: MemoryPool.Region
        private(set) var writeIndex: Int = 0
        private(set) var availableSamples: Int = 0
        private let lock = NSLock()
        
        mutating func write(_ samples: UnsafePointer<Float>, count: Int, to pool: MemoryPool) {
                lock.lock()
                defer { lock.unlock() }
                
                let ptr = region.pointer(in: pool)
                let capacity = region.count
                
                // Handle potential overflow
                let samplesToWrite = min(count, capacity)
                if count > samplesToWrite {
                        print("Warning: Dropping \(count - samplesToWrite) samples")
                }
                
                // Copy in up to two chunks to handle wrap-around
                let firstChunkSize = min(samplesToWrite, capacity - writeIndex)
                let secondChunkSize = samplesToWrite - firstChunkSize
                
                // First chunk
                memcpy(ptr.advanced(by: writeIndex), samples, firstChunkSize * MemoryLayout<Float>.size)
                
                // Second chunk (wrap-around)
                if secondChunkSize > 0 {
                        memcpy(ptr, samples.advanced(by: firstChunkSize), secondChunkSize * MemoryLayout<Float>.size)
                }
                
                writeIndex = (writeIndex + samplesToWrite) % capacity
                availableSamples = min(availableSamples + samplesToWrite, capacity)
        }
        
        func canExtractWindow(of size: Int, at offset: Int = 0) -> Bool {
                lock.lock()
                defer { lock.unlock() }
                return availableSamples >= size + offset
        }
        
        func extractWindow(of size: Int, at offset: Int = 0, to workspace: MemoryPool.Region, in pool: MemoryPool) -> Bool {
                lock.lock()
                defer { lock.unlock() }
                
                guard availableSamples >= size + offset else { return false }
                
                let srcPtr = region.pointer(in: pool)
                let dstPtr = workspace.pointer(in: pool)
                let capacity = region.count
                
                // Calculate read position
                let readStart = (writeIndex - availableSamples + offset + capacity) % capacity
                
                // Copy in up to two chunks
                let firstChunkSize = min(size, capacity - readStart)
                let secondChunkSize = size - firstChunkSize
                
                // First chunk
                memcpy(dstPtr, srcPtr.advanced(by: readStart), firstChunkSize * MemoryLayout<Float>.size)
                
                // Second chunk (wrap-around)
                if secondChunkSize > 0 {
                        memcpy(dstPtr.advanced(by: firstChunkSize), srcPtr, secondChunkSize * MemoryLayout<Float>.size)
                }
                
                return true
        }
        
        mutating func advance(by samples: Int) {
                lock.lock()
                defer { lock.unlock() }
                availableSamples = max(0, availableSamples - samples)
        }
}
