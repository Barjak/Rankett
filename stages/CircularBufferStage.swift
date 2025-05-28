import Foundation

class CircularBufferStage: ProcessingStage {
    typealias Input = [Float]
    typealias Output = [[Float]]  // One-to-many: samples in, windows out
    
    private var circularBuffer: [Float]
    private var writeIndex = 0
    private var samplesInBuffer = 0
    private let bufferLock = NSLock()
    
    private let fftSize: Int
    private let hopSize: Int
    private let maxWindows: Int
    private let bufferSize: Int
    
    init(fftSize: Int, hopSize: Int, maxWindows: Int = 1) {
        self.fftSize = fftSize
        self.hopSize = hopSize
        self.maxWindows = maxWindows
        self.bufferSize = fftSize * 2
        self.circularBuffer = Array(repeating: 0, count: bufferSize)
    }
    func write(_ input: [Float]) {
        bufferLock.lock()
        defer { bufferLock.unlock() }

        if input.count > bufferSize - samplesInBuffer {
            print("Warning: CircularBuffer overflow, dropping \(input.count - (bufferSize - samplesInBuffer)) samples")
        }

        for sample in input {
            circularBuffer[writeIndex] = sample
            writeIndex = (writeIndex + 1) % bufferSize
            samplesInBuffer = min(samplesInBuffer + 1, bufferSize)
        }
    }
    func extractWindows(maxWindows: Int) -> [[Float]] {
        bufferLock.lock()
        defer { bufferLock.unlock() }

        let availableWindows = (samplesInBuffer >= fftSize)
            ? ((samplesInBuffer - fftSize) / hopSize + 1)
            : 0

        let windowsToExtract = min(availableWindows, maxWindows)

        var extractedWindows: [[Float]] = []

        for i in 0..<windowsToExtract {
            var window = [Float](repeating: 0, count: fftSize)
            let windowOffset = i * hopSize
            let readIndex = (writeIndex - samplesInBuffer + windowOffset + bufferSize) % bufferSize

            for j in 0..<fftSize {
                window[j] = circularBuffer[(readIndex + j) % bufferSize]
            }

            extractedWindows.append(window)
        }

        samplesInBuffer -= (windowsToExtract * hopSize)
        return extractedWindows.reversed()  // Most recent first
    }

    func process(_ input: [Float]) -> [[Float]] {
        bufferLock.lock()
        defer { bufferLock.unlock() }
        
        var extractedWindows: [[Float]] = []
        
        // Check for potential overflow
        if input.count > bufferSize - samplesInBuffer {
            print("Warning: CircularBuffer overflow, dropping \(input.count - (bufferSize - samplesInBuffer)) samples")
        }
        
        // Write to circular buffer
        for sample in input {
            circularBuffer[writeIndex] = sample
            writeIndex = (writeIndex + 1) % bufferSize
            samplesInBuffer = min(samplesInBuffer + 1, bufferSize)
        }
        
        // Calculate how many windows we can extract
        let availableWindows = (samplesInBuffer >= fftSize) ? ((samplesInBuffer - fftSize) / hopSize + 1) : 0
        let windowsToExtract = min(availableWindows, maxWindows)
        
        // Extract windows from most recent to oldest
        for i in 0..<windowsToExtract {
            var window = [Float](repeating: 0, count: fftSize)
            // Calculate read position for this window (working backwards from most recent)
            let windowOffset = i * hopSize
            let readIndex = (writeIndex - samplesInBuffer + windowOffset + bufferSize) % bufferSize
            
            // Copy window
            for j in 0..<fftSize {
                window[j] = circularBuffer[(readIndex + j) % bufferSize]
            }
            
            extractedWindows.append(window)
        }
        
        // Advance buffer by total hop amount
        if windowsToExtract > 0 {
            samplesInBuffer -= (windowsToExtract * hopSize)
        }
        
        // Reverse to get most recent first
        return extractedWindows.reversed()
    }
    
    func reset() {
        bufferLock.lock()
        defer { bufferLock.unlock() }
        
        circularBuffer = Array(repeating: 0, count: bufferSize)
        writeIndex = 0
        samplesInBuffer = 0
    }
}
