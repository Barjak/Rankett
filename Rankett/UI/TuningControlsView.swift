import Foundation
import SwiftUI


struct TuningControlsView: View {
        @StateObject private var parameters = TuningParameterStore()
        @State private var showingTemperamentModal = false
        @State private var showingInstrumentModal = false
        @State private var carouselSelection = 0
        
        var body: some View {
                VStack(spacing: 12) {
                        // Carousel Pitch Display
                        CarouselPitchDisplay(centsError: parameters.centsError)
                                .frame(height: 60)
                        
                        // Numerical Pitch Display
                        NumericalPitchDisplayRow(
                                leftMode: $parameters.leftDisplayMode,
                                rightMode: $parameters.rightDisplayMode,
                                parameters: parameters
                        )
                        .frame(height: 50)
                        
                        // Target pitch controls
                        TargetPitchRow(
                                targetPitch: $parameters.targetPitch,
                                incrementSemitones: $parameters.pitchIncrementSemitones
                        )
                        .frame(height: 70) // Slightly taller as specified
                        
                        // Concert pitch controls
                        ConcertPitchRow(concertPitch: $parameters.concertPitch)
                                .frame(height: 50)
                        
                        // Target overtone controls
                        TargetOvertoneRow(targetPartial: $parameters.targetPartial)
                                .frame(height: 50)
                        
                        // Temperament and Instrument buttons
                        HStack(spacing: 12) {
                                Button(action: { showingTemperamentModal = true }) {
                                        Label(parameters.temperament.rawValue, systemImage: "music.note.list")
                                                .frame(maxWidth: .infinity)
                                }
                                .buttonStyle(TuningButtonStyle())
                                
                                Button(action: { showingInstrumentModal = true }) {
                                        Label(parameters.selectedInstrument.name, systemImage: "pianokeys")
                                                .frame(maxWidth: .infinity)
                                }
                                .buttonStyle(TuningButtonStyle())
                        }
                        .frame(height: 50)
                        
                        // Carousel selector for additional options
                        CarouselSelectorRow(
                                selection: $carouselSelection,
                                audibleToneEnabled: $parameters.audibleToneEnabled,
                                mutationTranspose: $parameters.mutationStopTranspose,
                                gateTime: $parameters.gateTime
                        )
                        .frame(height: 50)
                }
                .padding(.horizontal)
                .sheet(isPresented: $showingTemperamentModal) {
                        TemperamentModal(
                                temperament: $parameters.temperament,
                                isPresented: $showingTemperamentModal
                        )
                }
                .sheet(isPresented: $showingInstrumentModal) {
                        InstrumentModal(
                                instrument: $parameters.selectedInstrument,
                                isPresented: $showingInstrumentModal
                        )
                }
        }
}
