import Foundation
import Accelerate

final class CircularBuffer {
        private let buffer: UnsafeMutableBufferPointer<Float>
        private let capacity: Int
        private var writeIndex = 0
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
                
                let toWrite = min(count, capacity)
                if count > toWrite {
                        print("Warning: Dropping \(count - toWrite) samples")
                }
                
                let ptr = buffer.baseAddress!
                let first = min(toWrite, capacity - writeIndex)
                let second = toWrite - first
                
                memcpy(ptr.advanced(by: writeIndex), samples, first * MemoryLayout<Float>.size)
                if second > 0 {
                        memcpy(ptr, samples.advanced(by: first), second * MemoryLayout<Float>.size)
                }
                
                writeIndex = (writeIndex + toWrite) % capacity
                availableSamples = min(availableSamples + toWrite, capacity)
        }
        
        func canExtractWindow(of size: Int, at offset: Int = 0) -> Bool {
                lock.lock()
                defer { lock.unlock() }
                return availableSamples >= size + offset
        }
        
        @discardableResult
        func extractWindow(of size: Int, at offset: Int = 0, to destination: UnsafeMutablePointer<Float>) -> Bool {
                lock.lock()
                defer { lock.unlock() }
                
                guard availableSamples >= size + offset else { return false }
                
                let ptr = buffer.baseAddress!
                let start = (writeIndex - availableSamples + offset + capacity) % capacity
                let first = min(size, capacity - start)
                let second = size - first
                
                memcpy(destination, ptr.advanced(by: start), first * MemoryLayout<Float>.size)
                if second > 0 {
                        memcpy(destination.advanced(by: first), ptr, second * MemoryLayout<Float>.size)
                }
                
                return true
        }
        
        func advance(by samples: Int) {
                guard samples > 0 else { return }
                lock.lock()
                defer { lock.unlock() }
                availableSamples = max(0, availableSamples - samples)
        }
}
