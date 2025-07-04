import Foundation
import Atomics
import Accelerate

final class CircularBuffer<T> {
        private let buffer: UnsafeMutableBufferPointer<T>
        private let capacity: Int
        
        // Use modern atomics
        private let writeIndex = ManagedAtomic<Int>(0)
        private let totalWritten = ManagedAtomic<Int>(0)
        
        init(capacity: Int) {
                self.capacity = capacity
                let ptr = UnsafeMutablePointer<T>.allocate(capacity: capacity)
                self.buffer = UnsafeMutableBufferPointer(start: ptr, count: capacity)
                
                // Initialize based on type
                if T.self == Float.self {
                        buffer.withMemoryRebound(to: Float.self) { floatBuffer in
                                floatBuffer.initialize(repeating: 0)
                        }
                } else if T.self == Double.self {
                        buffer.withMemoryRebound(to: Double.self) { doubleBuffer in
                                doubleBuffer.initialize(repeating: 0)
                        }
                } else if T.self == DSPDoubleComplex.self {
                        buffer.withMemoryRebound(to: DSPDoubleComplex.self) { complexBuffer in
                                complexBuffer.initialize(repeating: DSPDoubleComplex(real: 0, imag: 0))
                        }
                } else if T.self == DSPComplex.self {
                        buffer.withMemoryRebound(to: DSPComplex.self) { complexBuffer in
                                complexBuffer.initialize(repeating: DSPComplex(real: 0, imag: 0))
                        }
                } else {
                        // For other types, use default initializer if available
                        for i in 0..<capacity {
                                ptr.advanced(by: i).initialize(to: unsafeBitCast(0, to: T.self))
                        }
                }
        }
        
        deinit {
                buffer.deallocate()
        }
        
        func write(_ samples: UnsafePointer<T>, count: Int) -> Int {
                let currentWriteIndex = writeIndex.load(ordering: .relaxed)
                let currentTotal = totalWritten.load(ordering: .relaxed)
                let ptr = buffer.baseAddress!
                var samplesRemaining = count
                var sourceOffset = 0
                var localWriteIndex = currentWriteIndex
                
                // Write in chunks, wrapping around as needed
                while samplesRemaining > 0 {
                        let chunkSize = min(samplesRemaining, capacity - localWriteIndex)
                        memcpy(ptr.advanced(by: localWriteIndex),
                               samples.advanced(by: sourceOffset),
                               chunkSize * MemoryLayout<T>.size)
                        
                        localWriteIndex = (localWriteIndex + chunkSize) % capacity
                        sourceOffset += chunkSize
                        samplesRemaining -= chunkSize
                }
                
                // Update indices atomically
                writeIndex.store(localWriteIndex, ordering: .relaxed)
                let newTotal = totalWritten.wrappingIncrementThenLoad(by: count, ordering: .relaxed)
                
                // Return the position after writing
                return newTotal
        }
        
        /// Get samples since a given position
        func getSamplesSince(position: Int) -> (samples: [T], newPosition: Int)? {
                let currentTotal = totalWritten.load(ordering: .relaxed)
                
                // No new samples
                if position >= currentTotal {
                        return nil
                }
                
                // Calculate how many samples to return
                let samplesAvailable = currentTotal - position
                let samplesToReturn = min(samplesAvailable, capacity)
                
                // If we're asking for more samples than we have in the buffer
                if samplesAvailable > capacity {
                        // We've lost some samples - return what we have
                        return getAllSamples(newPosition: currentTotal)
                }
                
                // Calculate read position
                let currentWriteIdx = writeIndex.load(ordering: .relaxed)
                let readStart = (currentWriteIdx - samplesToReturn + capacity) % capacity
                
                // Read samples
                var samples = [T](repeating: getZeroValue(), count: samplesToReturn)
                let ptr = buffer.baseAddress!
                
                samples.withUnsafeMutableBufferPointer { destBuffer in
                        let destPtr = destBuffer.baseAddress!
                        
                        let firstChunkSize = min(samplesToReturn, capacity - readStart)
                        memcpy(destPtr,
                               ptr.advanced(by: readStart),
                               firstChunkSize * MemoryLayout<T>.size)
                        
                        if samplesToReturn > firstChunkSize {
                                let secondChunkSize = samplesToReturn - firstChunkSize
                                memcpy(destPtr.advanced(by: firstChunkSize),
                                       ptr,
                                       secondChunkSize * MemoryLayout<T>.size)
                        }
                }
                
                return (samples, currentTotal)
        }
        
        /// Get all samples currently in buffer
        func getAllSamples(newPosition: Int? = nil) -> (samples: [T], newPosition: Int) {
                let currentTotal = totalWritten.load(ordering: .relaxed)
                let size = min(currentTotal, capacity)
                
                guard size > 0 else {
                        return ([], currentTotal)
                }
                
                let currentWriteIdx = writeIndex.load(ordering: .relaxed)
                let readStart = (currentWriteIdx - size + capacity) % capacity
                
                var samples = [T](repeating: getZeroValue(), count: size)
                let ptr = buffer.baseAddress!
                
                samples.withUnsafeMutableBufferPointer { destBuffer in
                        let destPtr = destBuffer.baseAddress!
                        
                        let firstChunkSize = min(size, capacity - readStart)
                        memcpy(destPtr,
                               ptr.advanced(by: readStart),
                               firstChunkSize * MemoryLayout<T>.size)
                        
                        if size > firstChunkSize {
                                let secondChunkSize = size - firstChunkSize
                                memcpy(destPtr.advanced(by: firstChunkSize),
                                       ptr,
                                       secondChunkSize * MemoryLayout<T>.size)
                        }
                }
                
                return (samples, newPosition ?? currentTotal)
        }
        
        /// Get the latest `size` samples
        func getLatest(size: Int, to destination: UnsafeMutablePointer<T>) -> Bool {
                let currentTotal = totalWritten.load(ordering: .relaxed)
                
                guard currentTotal >= size else {
                        // Not enough data yet - fill with zeros
                        for i in 0..<size {
                                destination[i] = getZeroValue()
                        }
                        return false
                }
                
                let currentWriteIdx = writeIndex.load(ordering: .relaxed)
                let ptr = buffer.baseAddress!
                
                // Calculate where to start reading to get the latest `size` samples
                let readStart = (currentWriteIdx - size + capacity) % capacity
                
                // Read in up to two chunks
                let firstChunkSize = min(size, capacity - readStart)
                memcpy(destination, ptr.advanced(by: readStart), firstChunkSize * MemoryLayout<T>.size)
                
                if size > firstChunkSize {
                        let secondChunkSize = size - firstChunkSize
                        memcpy(destination.advanced(by: firstChunkSize), ptr, secondChunkSize * MemoryLayout<T>.size)
                }
                
                return true
        }
        
        /// Get a contiguous copy of the most recent samples
        func getRecent(_ n: Int) throws -> [T] {
                let currentTotal = totalWritten.load(ordering: .relaxed)
                let available = min(currentTotal, capacity)
                
                guard n <= available else {
                        throw CircularBufferError.insufficientSamples(requested: n, available: available)
                }
                
                var result = [T](repeating: getZeroValue(), count: n)
                result.withUnsafeMutableBufferPointer { buffer in
                        _ = getLatest(size: n, to: buffer.baseAddress!)
                }
                return result
        }
        
        /// Check if we have at least `size` samples
        func hasEnoughData(size: Int) -> Bool {
                return totalWritten.load(ordering: .relaxed) >= size
        }
        
        /// Get total samples written
        func getTotalWritten() -> Int {
                return totalWritten.load(ordering: .relaxed)
        }
        
        /// Get current position (for bookmarking)
        func getCurrentPosition() -> Int {
                return totalWritten.load(ordering: .relaxed)
        }
        
        /// Get current fill percentage
        func getFillPercentage() -> Float {
                let written = totalWritten.load(ordering: .relaxed)
                if written >= capacity {
                        return 100.0
                }
                return Float(written) / Float(capacity) * 100.0
        }
        
        /// Get the number of available samples (capped at capacity)
        var size: Int {
                return min(totalWritten.load(ordering: .relaxed), capacity)
        }
        
        // Helper to get zero value for different types
        private func getZeroValue() -> T {
                if T.self == Float.self {
                        return unsafeBitCast(Float(0), to: T.self)
                } else if T.self == Double.self {
                        return unsafeBitCast(Double(0), to: T.self)
                } else if T.self == DSPDoubleComplex.self {
                        return unsafeBitCast(DSPDoubleComplex(real: 0, imag: 0), to: T.self)
                } else if T.self == DSPComplex.self {
                        return unsafeBitCast(DSPComplex(real: 0, imag: 0), to: T.self)
                } else {
                        // For other types, try to create a zero-initialized value
                        return unsafeBitCast(0, to: T.self)
                }
        }
}

enum CircularBufferError: Error {
        case insufficientSamples(requested: Int, available: Int)
}

// Extension for convenient array writing
extension CircularBuffer {
        func write(_ samples: [T]) -> Int {
                return samples.withUnsafeBufferPointer { buffer in
                        return write(buffer.baseAddress!, count: buffer.count)
                }
        }
}
