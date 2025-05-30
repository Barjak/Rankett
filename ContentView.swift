//  ContentView.swift
//  SpectrumAnalyzer
//
//  Created by ChatGPT on 30‑May‑2025.
//
//  This view publishes the available drawing area via an EnvironmentKey so that
//  SpectrumView and StudyView can size themselves as a fraction of the screen.
//
//  NOTE: The `drawingArea` EnvironmentKey is defined in DrawingAreaKey.swift.

import SwiftUI

struct ContentView: View {
        // MARK: - State
        @StateObject private var audioProcessor = AudioProcessor(config: Config())
        @State private var isProcessing = false
        
        // MARK: - Body
        var body: some View {
                GeometryReader { proxy in
                        let available = proxy.size    // includes safe‑area adjustments
                        
                        VStack(spacing: 20) {
                                // ──────────────── Title ────────────────
                                Text("Spectrum Analyzer")
                                        .font(.largeTitle)
                                        .fontWeight(.bold)
                                        .padding(.top, 10)
                                
                                // ────────────── Spectrum ──────────────
                                SpectrumView(spectrumData: audioProcessor.spectrumData,
                                             config: Config())
                                .frame(height: available.height * 0.40)
                                .background(Color.black)
                                .cornerRadius(12)
                                .shadow(radius: 5)
                                .padding(.horizontal)
                                
                                // ───────────── Info Panel ─────────────
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
                                
                                // ─────────────── Study ────────────────
                                if let study = audioProcessor.studyResult {
                                        StudyView(studyResult: study)
                                                .frame(height: available.height * 0.40)
                                                .background(Color.black)
                                                .cornerRadius(12)
                                                .shadow(radius: 5)
                                                .padding(.horizontal)
                                } else {
                                        Rectangle()
                                                .fill(Color.black.opacity(0.3))
                                                .frame(height: available.height * 0.40)
                                                .cornerRadius(12)
                                                .padding(.horizontal)
                                                .overlay(
                                                        Text("Press 'Analyze Spectrum' to see denoised signal")
                                                                .foregroundColor(.gray)
                                                                .font(.caption)
                                                )
                                }
                                
                                // ─────────── Analyze Button ───────────
                                Button("Analyze Spectrum") {
                                        audioProcessor.triggerStudy()
                                }
                                .font(.caption)
                                .padding(.horizontal, 20)
                                .padding(.vertical, 8)
                                .background(Color.green)
                                .foregroundColor(.white)
                                .cornerRadius(8)
                                
                                // ───────────── Transport ──────────────
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
                        .frame(maxWidth: .infinity,
                               maxHeight: .infinity,
                               alignment: .top)
                        .environment(\.drawingArea, available) // <-- broadcast size to children
                        .onAppear { startProcessing() }
                        .onDisappear { audioProcessor.stop() }
                }
        }
        
        // MARK: - Actions
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

// MARK: - Previews
#if DEBUG
struct ContentView_Previews: PreviewProvider {
        static var previews: some View {
                ContentView()
        }
}
#endif
