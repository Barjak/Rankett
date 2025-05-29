import SwiftUI

struct ContentView: View {
    @StateObject private var audioProcessor: AudioProcessor
    @State private var isProcessing = false
    
    init() {
        let config = Config()
        _audioProcessor = StateObject(wrappedValue: AudioProcessor(config: config))
    }
    
    var body: some View {
        VStack(spacing: 20) {
            // Title
            Text("Spectrum Analyzer")
                .font(.largeTitle)
                .fontWeight(.bold)
            
            // Spectrum display
            SpectrumView(spectrumData: audioProcessor.spectrumData,
                        config: Config())
                .frame(height: 300)
                .background(Color.black)
                .cornerRadius(12)
                .shadow(radius: 5)
                .padding(.horizontal)
            
            // Info panel
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Label("FFT Size: \(Config().fftSize)", systemImage: "waveform")
                    Label("Sample Rate: \(Int(Config().sampleRate)) Hz", systemImage: "metronome")
                }
                
                Spacer()
                
                VStack(alignment: .trailing, spacing: 4) {
                    Label("Resolution: \(String(format: "%.1f Hz", Config().frequencyResolution))",
                          systemImage: "ruler")
                    Label("Frame Rate: \(Int(Config().frameRate)) fps", systemImage: "speedometer")
                }
            }
            .font(.caption)
            .foregroundColor(.secondary)
            .padding(.horizontal, 30)
            
            // In ContentView body, replace the Spacer() with:
            // Study result display
            if audioProcessor.studyResult != nil {
                StudyView(studyResult: audioProcessor.studyResult)
                    .frame(height: 200)
                    .background(Color.black)
                    .cornerRadius(12)
                    .shadow(radius: 5)
                    .padding(.horizontal)
            } else {
                Rectangle()
                    .fill(Color.black.opacity(0.3))
                    .frame(height: 200)
                    .cornerRadius(12)
                    .padding(.horizontal)
                    .overlay(
                        Text("Press 'Analyze Spectrum' to see denoised signal")
                            .foregroundColor(.gray)
                            .font(.caption)
                    )
            }

            // Update the button action:
            Button("Analyze Spectrum") {
                audioProcessor.triggerStudy()
            }
            .font(.caption)
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
            .background(Color.green)
            .foregroundColor(.white)
            .cornerRadius(8)
            
            // Control button
            Button(action: toggleProcessing) {
                HStack {
                    Image(systemName: isProcessing ? "stop.circle.fill" : "play.circle.fill")
                        .font(.title2)
                    Text(isProcessing ? "Stop" : "Start")
                        .fontWeight(.semibold)
                }
                .frame(width: 120, height: 44)
                .background(isProcessing ? Color.red : Color.blue)
                .foregroundColor(.white)
                .cornerRadius(22)
            }
            .padding(.bottom, 30)
        }
        .onAppear {
            startProcessing()
        }
        .onDisappear {
            audioProcessor.stop()
        }
    }
    
    private func toggleProcessing() {
        if isProcessing {
            audioProcessor.stop()
            isProcessing = false
        } else {
            startProcessing()
        }
    }
    
    private func startProcessing() {
        audioProcessor.start()
        isProcessing = true
    }
}
