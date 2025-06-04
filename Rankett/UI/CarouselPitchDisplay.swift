import Foundation
import SwiftUI

struct CarouselPitchDisplay: View {
        let centsError: Double
        @State private var offset: CGFloat = 0
        
        private var rotationSpeed: Double {
                // Speed increases with error, capped at reasonable values
                min(abs(centsError) / 10, 5.0)
        }
        
        private var isInTune: Bool {
                abs(centsError) < 2.0
        }
        
        var body: some View {
                GeometryReader { geometry in
                        ZStack {
                                RoundedRectangle(cornerRadius: 8)
                                        .stroke(Color.gray.opacity(0.3), lineWidth: 2)
                                        .background(
                                                RoundedRectangle(cornerRadius: 8)
                                                        .fill(Color.black.opacity(0.3))
                                        )
                                
                                HStack(spacing: 20) {
                                        ForEach(0..<10) { _ in
                                                RoundedRectangle(cornerRadius: 4)
                                                        .fill(isInTune ? Color.green : Color.orange)
                                                        .frame(width: 30, height: 40)
                                        }
                                }
                                .offset(x: offset)
                                .animation(
                                        isInTune ? .default :
                                                Animation.linear(duration: 1.0 / rotationSpeed)
                                                .repeatForever(autoreverses: false),
                                        value: offset
                                )
                                .onAppear {
                                        if !isInTune {
                                                startAnimation()
                                        }
                                }
                                .onChange(of: centsError) { _ in
                                        if isInTune {
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
                let direction: CGFloat = centsError > 0 ? -1 : 1
                offset = 0
                withAnimation {
                        offset = direction * 50
                }
        }
}
