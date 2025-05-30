import Foundation

final class MemoryPool {
        let buffer: UnsafeMutablePointer<Float>
        let size: Int
        
        struct Region {
                let offset: Int
                let count: Int
                
                @inline(__always)
                func pointer(in pool: MemoryPool) -> UnsafeMutablePointer<Float> {
                        return pool.buffer.advanced(by: offset)
                }
                
                @inline(__always)
                func bufferPointer(in pool: MemoryPool) -> UnsafeMutableBufferPointer<Float> {
                        return UnsafeMutableBufferPointer(start: pointer(in: pool), count: count)
                }
        }
        
        let circularBuffer: Region
        let windowWorkspace: Region
        let fftReal: Region
        let fftImag: Region
        let magnitude: Region
        let displayCurrent: Region
        let displayTarget: Region
        let fftStatsMean: Region
        let fftStatsVar: Region
        
        init(config: Config) {
                size = config.totalMemorySize
                buffer = UnsafeMutablePointer<Float>.allocate(capacity: size)
                buffer.initialize(repeating: 0, count: size)
                
                // Calculate offsets for each region
                var offset = 0
                
                circularBuffer = Region(offset: offset, count: config.circularBufferSize)
                offset += config.circularBufferSize
                
                windowWorkspace = Region(offset: offset, count: config.fftSize)
                offset += config.fftSize
                
                fftReal = Region(offset: offset, count: config.fftSize / 2)
                offset += config.fftSize / 2
                
                fftImag = Region(offset: offset, count: config.fftSize / 2)
                offset += config.fftSize / 2
                
                magnitude = Region(offset: offset, count: config.fftSize / 2)
                offset += config.fftSize / 2
                
                displayCurrent = Region(offset: offset, count: config.outputBinCount)
                offset += config.outputBinCount
                
                displayTarget = Region(offset: offset, count: config.outputBinCount)
                offset += config.outputBinCount
                
                fftStatsMean = Region(offset: offset, count: config.fftSize / 2)
                offset += config.fftSize / 2
                
                fftStatsVar = Region(offset: offset, count: config.fftSize / 2)
                offset += config.fftSize / 2
                
                assert(offset == size, "Memory calculation mismatch")
        }
        
        deinit {
                buffer.deallocate()
        }
        
        // Helper to swap display buffers
        func swapDisplayBuffers() -> (current: Region, previous: Region) {
                return (displayTarget, displayCurrent)
        }
}
