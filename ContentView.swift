//
//  ContentView.swift
//  ShitPipes
//
//  Created by Ralph Richards on 5/27/25.
//
import SwiftUI
import AVFoundation
import Accelerate
import Foundation
// MARK: - Main View
struct ContentView: View {
    @StateObject private var audioProcessor: AudioProcessor
    @State private var showSettings = false
    
    init() {
        // Create custom config - you can toggle useFrequencyBinning here
        var config = SpectrumAnalyzerConfig()
        // Example: disable binning for full resolution
        // config = SpectrumAnalyzerConfig(useFrequencyBinning: false)
        
        _audioProcessor = StateObject(wrappedValue: AudioProcessor(config: config))
    }
    
    var body: some View {
        VStack {
            Text("Spectrum Analyzer")
                .font(.title)
                .padding()
            
            SpectrumView(spectrumData: audioProcessor.spectrumData,
                        frequencyData: audioProcessor.frequencyData,  // NEW
                        config: audioProcessor.config)  // Pass the actual config
                .frame(height: 300)
                .padding()
                .background(Color.black)
                .cornerRadius(10)
            
            HStack {
                Text("Frequency Resolution: \(String(format: "%.2f Hz", SpectrumAnalyzerConfig().frequencyResolution))")
                Spacer()
                Text("FFT Size: \(SpectrumAnalyzerConfig().fftSize)")
            }
            .font(.caption)
            .padding(.horizontal)
            
            Spacer()
        }
        .onAppear {
            audioProcessor.start()
        }
        .onDisappear {
            audioProcessor.stop()
        }
    }
}
