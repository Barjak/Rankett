import Foundation
import Atomics
import Accelerate

enum ReadPosition {
        case mostRecent
        case oldest
        case bookmark(Int)
}

final class CircularBuffer<T> {
        private let buffer: UnsafeMutableBufferPointer<T>
        let capacity: Int
        
        private let writeIndex = ManagedAtomic<Int>(0)
        private let totalWritten = ManagedAtomic<Int>(0)
        
        var size: Int {
                min(totalWritten.load(ordering: .relaxed), capacity)
        }
        
        init(capacity: Int) {
                self.capacity = capacity
                let ptr = UnsafeMutablePointer<T>.allocate(capacity: capacity)
                self.buffer = UnsafeMutableBufferPointer(start: ptr, count: capacity)
                
                let zero = Self.makeZero()
                for i in 0..<capacity {
                        ptr.advanced(by: i).initialize(to: zero)
                }
        }
        
        deinit {
                buffer.deallocate()
        }
        
        func write(_ samples: UnsafePointer<T>, count: Int) -> Int {
                let ptr = buffer.baseAddress!
                var samplesRemaining = count
                var sourceOffset = 0
                
                let currentWriteIndex = writeIndex.load(ordering: .relaxed)
                var localWriteIndex = currentWriteIndex
                
                while samplesRemaining > 0 {
                        let chunkSize = min(samplesRemaining, capacity - localWriteIndex)
                        memcpy(ptr.advanced(by: localWriteIndex),
                               samples.advanced(by: sourceOffset),
                               chunkSize * MemoryLayout<T>.size)
                        
                        localWriteIndex = (localWriteIndex + chunkSize) % capacity
                        sourceOffset += chunkSize
                        samplesRemaining -= chunkSize
                }
                
                writeIndex.store(localWriteIndex, ordering: .relaxed)
                let newTotal = totalWritten.wrappingIncrementThenLoad(by: count, ordering: .relaxed)
                
                return newTotal
        }
        
        func read(count: Int? = nil,
                  from position: ReadPosition = .mostRecent,
                  after: Int? = nil) -> (samples: [T], bookmark: Int) {
                
                let currentTotal = totalWritten.load(ordering: .relaxed)
                let currentWriteIdx = writeIndex.load(ordering: .relaxed)
                
                guard currentTotal > 0 else {
                        return ([], currentTotal)
                }
                
                if let afterBookmark = after, afterBookmark >= currentTotal {
                        return ([], currentTotal)
                }
                
                let availableInBuffer = min(currentTotal, capacity)
                let oldestAvailable = max(0, currentTotal - capacity)
                
                let startOffset: Int
                switch position {
                case .mostRecent:
                        startOffset = currentTotal
                        
                case .oldest:
                        startOffset = oldestAvailable + availableInBuffer
                        
                case .bookmark(let bookmark):
                        if bookmark >= currentTotal {
                                return ([], currentTotal)
                        }
                        startOffset = max(bookmark + availableInBuffer, oldestAvailable + availableInBuffer)
                }
                
                let effectiveStart = max(after.map { $0 + 1 } ?? oldestAvailable, oldestAvailable)
                let readEnd = min(startOffset, currentTotal)
                
                guard readEnd > effectiveStart else {
                        return ([], currentTotal)
                }
                
                let maxAvailable = readEnd - effectiveStart
                let samplesToRead = min(count ?? maxAvailable, maxAvailable)
                
                guard samplesToRead > 0 else {
                        return ([], currentTotal)
                }
                
                let readStart = readEnd - samplesToRead
                let bufferStartIdx = (currentWriteIdx - (currentTotal - readStart) + capacity) % capacity
                
                var samples = [T](repeating: Self.makeZero(), count: samplesToRead)
                let ptr = buffer.baseAddress!
                
                samples.withUnsafeMutableBufferPointer { destBuffer in
                        let destPtr = destBuffer.baseAddress!
                        
                        if bufferStartIdx + samplesToRead <= capacity {
                                memcpy(destPtr,
                                       ptr.advanced(by: bufferStartIdx),
                                       samplesToRead * MemoryLayout<T>.size)
                        } else {
                                let firstChunkSize = capacity - bufferStartIdx
                                memcpy(destPtr,
                                       ptr.advanced(by: bufferStartIdx),
                                       firstChunkSize * MemoryLayout<T>.size)
                                
                                let secondChunkSize = samplesToRead - firstChunkSize
                                memcpy(destPtr.advanced(by: firstChunkSize),
                                       ptr,
                                       secondChunkSize * MemoryLayout<T>.size)
                        }
                }
                
                return (samples, currentTotal)
        }
        
        func getTotalWritten() -> Int {
                totalWritten.load(ordering: .relaxed)
        }
        
        private static func makeZero() -> T {
                switch T.self {
                case is Float.Type:
                        return unsafeBitCast(Float(0), to: T.self)
                case is Double.Type:
                        return unsafeBitCast(Double(0), to: T.self)
                case is DSPDoubleComplex.Type:
                        return unsafeBitCast(DSPDoubleComplex(real: 0, imag: 0), to: T.self)
                case is DSPComplex.Type:
                        return unsafeBitCast(DSPComplex(real: 0, imag: 0), to: T.self)
                default:
                        fatalError("CircularBuffer only supports Float, Double, DSPComplex, and DSPDoubleComplex")
                }
        }
}

extension CircularBuffer {
        func write(_ samples: [T]) -> Int {
                samples.withUnsafeBufferPointer { buffer in
                        write(buffer.baseAddress!, count: buffer.count)
                }
        }
}
