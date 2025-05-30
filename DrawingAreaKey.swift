// DrawingAreaKey.swift
import SwiftUI

private struct DrawingAreaKey: EnvironmentKey {
        static let defaultValue: CGSize = .zero        // sensible default for previews
}

extension EnvironmentValues {
        /// Full size of the vertical stack’s drawable region after safe-area insets.
        var drawingArea: CGSize {
                get { self[DrawingAreaKey.self] }
                set { self[DrawingAreaKey.self] = newValue }
        }
}
