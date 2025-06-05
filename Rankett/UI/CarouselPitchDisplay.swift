import Foundation
import SwiftUI
struct CarouselPitchDisplay: View {
        let centsError: Double
        @State private var offset: Double = 0
        
        private var rotationSpeed: Double {
                min(abs(centsError) / 10, 5.0)
        }
        
        private var isInTune: Bool {
                abs(centsError) < 2.0
        }
        
        var body: some View {
                GeometryReader { geometry in
                        ZStack {
                                // Background Frame
                                RoundedRectangle(cornerRadius: 8)
                                        .stroke(Color.gray.opacity(0.3), lineWidth: 2)
                                        .background(
                                                RoundedRectangle(cornerRadius: 8)
                                                        .fill(Color.black.opacity(0.3))
                                        )
                                
                                // Carousel content
                                HStack(spacing: 20) {
                                        // Create enough rectangles to fill the screen when looping
                                        ForEach(0..<20, id: \.self) { _ in
                                                RoundedRectangle(cornerRadius: 4)
                                                        .fill(isInTune ? Color.green : Color.orange)
                                                        .frame(width: 30, height: 40)
                                        }
                                }
                                .offset(x: offset, y: 0)
                                .animation(.linear(duration: 0.1), value: offset)
                                .onAppear {
                                        startAnimation()
                                }
                                .onChange(of: isInTune) { newValue in
                                        if newValue {
                                                offset = 0
                                        } else {
                                                startAnimation()
                                        }
                                }
                                .mask(
                                        RoundedRectangle(cornerRadius: 8)
                                )
                        }
                }
        }
        
        private func startAnimation() {
                guard !isInTune else { return }
                
                Timer.scheduledTimer(withTimeInterval: 0.016, repeats: true) { timer in
                        if isInTune {
                                timer.invalidate()
                                offset = 0
                        } else {
                                // Move based on error direction and speed
                                let direction = centsError > 0 ? 1.0 : -1.0
                                offset += direction * rotationSpeed
                                
                                // Reset offset when it goes too far to create loop effect
                                if abs(offset) > 200 {
                                        offset = 0
                                }
                        }
                }
        }
}
