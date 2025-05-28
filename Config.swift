import Foundation

struct Config {
    // Audio parameters
    let sampleRate: Double = 44100
    let fftSize: Int = 8192
    let hopSize: Int = 2048  // For 75% overlap
    
    // Display parameters
    let outputBinCount: Int = 512
    let useLogFrequencyScale: Bool = true
    let minFrequency: Double = 20.0
    let maxFrequency: Double = 20000.0
    let smoothingFactor: Float = 0.95
    
    // Performance parameters
    let frameRate: Double = 60.0
    let circularBufferSize: Int = 32768  // 4x fftSize for safety
    
    // Computed properties
    var frameInterval: TimeInterval {
        1.0 / frameRate
    }
    
    var frequencyResolution: Double {
        sampleRate / Double(fftSize)
    }
    
    var nyquistFrequency: Double {
        sampleRate / 2.0
    }
    
    // Memory layout calculations
    var totalMemorySize: Int {
        circularBufferSize +    // Circular buffer
        fftSize +              // Window workspace
        fftSize / 2 +          // FFT real part
        fftSize / 2 +          // FFT imaginary part
        fftSize / 2 +          // Magnitude output
        outputBinCount * 2     // Display buffer (current + previous for smoothing)
    }
}
