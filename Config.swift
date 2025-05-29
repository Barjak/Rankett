import Foundation
struct Config {
    let sampleRate: Double = 44100
    let fftSize: Int = 8192 * 1 // Keep large for accuracy
    let outputBinCount: Int = 512
    
    // Reduced hop size for better time resolution
    // At 60 FPS, we want to advance ~735 samples per frame
    // But round to a nice number for efficiency
    var hopSize: Int {
        return 1024  // ~86 windows per second, plenty for 60 FPS
    }
    
    let frameInterval: TimeInterval = 1.0 / 60.0  // 60 FPS target
    let smoothingFactor: Float = 0.1
    let useLogFrequencyScale: Bool = true
    let minFrequency: Double = 20.0
    let maxFrequency: Double = 20000.0
    let enableStatsSuppression: Bool = false
    
    let frameRate: Double = 60
    
    // Computed properties
    var nyquistFrequency: Double {
        return sampleRate / 2.0
    }
    
    var frequencyResolution: Double {
        return sampleRate / Double(fftSize)
    }
    
    var circularBufferSize: Int {
        // Need at least fftSize + maxExpectedAudioBuffer
        // Add extra for timing margin
        return fftSize * 3
    }
    
    var totalMemorySize: Int {
        circularBufferSize +    // Circular buffer
        fftSize +              // Window workspace
        fftSize / 2 +          // FFT real part
        fftSize / 2 +          // FFT imaginary part
        fftSize / 2 +          // Magnitude output
        outputBinCount * 2 +    // Display buffer (current + previous for smoothing)
        fftSize / 2 +
        fftSize / 2
    }
}
