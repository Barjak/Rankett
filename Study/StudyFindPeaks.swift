extension Study {
        // MARK: - Find Peaks
        static func findPeaks(in spectrum: [Float],
                              frequencies: [Float],
                              config: AnalyzerConfig.PeakDetection) -> [Peak] {
                var peaks: [Peak] = []
                
                // Find local maxima
                for i in 1..<(spectrum.count - 1) {
                        if spectrum[i] > spectrum[i-1] &&
                                spectrum[i] > spectrum[i+1] &&
                                spectrum[i] > config.minHeight {
                                
                                // Calculate prominence
                                let (prominence, leftBase, rightBase) = calculateProminence(
                                        at: i,
                                        in: spectrum,
                                        window: config.prominenceWindow
                                )
                                
                                if prominence >= config.minProminence {
                                        peaks.append(Peak(
                                                index: i,
                                                frequency: frequencies[i],
                                                magnitude: spectrum[i],
                                                prominence: prominence,
                                                leftBase: leftBase,
                                                rightBase: rightBase
                                        ))
                                }
                        }
                }
                
                // Filter by minimum distance
                peaks = filterByDistance(peaks, minDistance: config.minDistance)
                
                return peaks
        }
        // MARK: (Calculate Prominence)
        static func calculateProminence(at peakIndex: Int,
                                        in spectrum: [Float],
                                        window: Int) -> (prominence: Float, leftBase: Int, rightBase: Int) {
                let peakHeight = spectrum[peakIndex]
                let start = max(0, peakIndex - window)
                let end = min(spectrum.count - 1, peakIndex + window)
                
                // Find lowest points on each side
                var leftMin = peakHeight
                var leftMinIndex = peakIndex
                for i in stride(from: peakIndex - 1, through: start, by: -1) {
                        if spectrum[i] < leftMin {
                                leftMin = spectrum[i]
                                leftMinIndex = i
                        }
                        if spectrum[i] > peakHeight { break }  // Higher peak found
                }
                
                var rightMin = peakHeight
                var rightMinIndex = peakIndex
                for i in stride(from: peakIndex + 1, through: end, by: 1) {
                        if spectrum[i] < rightMin {
                                rightMin = spectrum[i]
                                rightMinIndex = i
                        }
                        if spectrum[i] > peakHeight { break }  // Higher peak found
                }
                
                let prominence = peakHeight - max(leftMin, rightMin)
                return (prominence, leftMinIndex, rightMinIndex)
        }
        // MARK: (Filter By Distance)
        static func filterByDistance(_ peaks: [Peak], minDistance: Int) -> [Peak] {
                guard !peaks.isEmpty else { return [] }
                
                // Sort by magnitude (keep highest peaks when too close)
                let sorted = peaks.sorted { $0.magnitude > $1.magnitude }
                var kept: [Peak] = []
                
                for peak in sorted {
                        let tooClose = kept.contains { abs($0.index - peak.index) < minDistance }
                        if !tooClose {
                                kept.append(peak)
                        }
                }
                
                return kept.sorted { $0.index < $1.index }
        }
        
        
}
