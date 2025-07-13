import Foundation
import SwiftUI


struct TuningControlsView: View {
        @ObservedObject var store: TuningParameterStore
        @ObservedObject var study: Study
        @State private var showingTemperamentModal = false
        @State private var showingInstrumentModal = false
        @State private var carouselSelection = 0
        
        init(study: Study, store: TuningParameterStore) {
                self._store = ObservedObject(wrappedValue: store)
                self._study = ObservedObject(wrappedValue: study)

        }
        
        var body: some View {
                VStack(spacing: 12) {
                        // Carousel Pitch Display
//                        CarouselPitchDisplay(centsError: Double(self.study.targetHPSFundamental - self.store.targetFrequency()))
//                                .frame(height: 60)
                        
                        // Numerical Pitch Display
                        NumericalPitchDisplayRow(
                                leftMode: $store.leftDisplayMode,
                                rightMode: $store.rightDisplayMode,
                                store: store
                        )
                        .frame(height: 50)
                        
                        // Target pitch controls
                        TargetNoteRow(
                                targetNote: $store.targetNote,
                                incrementSemitones: $store.pitchIncrementSemitones,
                                study: self.study,
                                store: store
                        )
                        .frame(height: 70) // Slightly taller as specified
                        
                        // Concert pitch controls
                        ConcertPitchRow(concertPitch: $store.concertPitch)
                                .frame(height: 50)
                        
                        // Target overtone controls
                        TargetOvertoneRow(targetPartial: $store.targetPartial)
                                .frame(height: 50)
                        
                        // Temperament and Instrument buttons
                        HStack(spacing: 12) {
                                Button(action: { showingTemperamentModal = true }) {
                                        Label(store.temperament.rawValue, systemImage: "music.note.list")
                                                .frame(maxWidth: .infinity)
                                }
                                .buttonStyle(TuningButtonStyle())
                                
                                Button(action: { showingInstrumentModal = true }) {
                                        Label(store.selectedInstrument.name, systemImage: "pianokeys")
                                                .frame(maxWidth: .infinity)
                                }
                                .buttonStyle(TuningButtonStyle())
                        }
                        .frame(height: 50)
                        
                        // Carousel selector for additional options
                        CarouselSelectorRow(
                                selection: $carouselSelection,
                                audibleToneEnabled: $store.audibleToneEnabled,
                                mutationTranspose: $store.mutationStopTranspose,
                                gateTime: $store.gateTime
                        )
                        .frame(height: 50)
                }
                .padding(.horizontal)
                .sheet(isPresented: $showingTemperamentModal) {
                        TemperamentModal(
                                temperament: $store.temperament,
                                isPresented: $showingTemperamentModal
                        )
                }
                .sheet(isPresented: $showingInstrumentModal) {
                        InstrumentModal(
                                instrument: $store.selectedInstrument,
                                isPresented: $showingInstrumentModal
                        )
                }
        }
}
