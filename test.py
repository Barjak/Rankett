import numpy as np
import matplotlib.pyplot as plt
from scipy import signal
import matplotlib.gridspec as gridspec
from matplotlib.patches import Circle
import matplotlib.cm as cm

class DualPLLAnalyzer:
    def __init__(self, fs_baseband=960.0):
        self.fs = fs_baseband
        
    def dual_pll_with_tracking(self, signal_data, f1_init, f2_init, 
                              track_amplitude=False, amplitude_regularization=0.1,
                              min_separation=0.003, freq_regularization=0.1):
        """
        Dual PLL with detailed tracking of all parameters
        """
        n_samples = len(signal_data)
        
        # Initialize
        phase1, phase2 = 0.0, 0.0
        freq1, freq2 = f1_init, f2_init
        
        # Amplitude tracking
        if track_amplitude:
            A1, A2 = 1.0, 0.7  # Initial guess
        else:
            A1, A2 = 1.0, 0.7  # Fixed
        
        # PLL parameters
        loop_bw = 0.5  # Hz
        damping = 1.0
        theta = 2 * np.pi * loop_bw / self.fs
        d = 1 + 2 * damping * theta + theta**2
        g1 = 4 * damping * theta / d
        g2 = 4 * theta**2 / d
        
        # Storage for analysis
        history = {
            'freq1': [freq1],
            'freq2': [freq2],
            'A1': [A1],
            'A2': [A2],
            'phase1': [phase1],
            'phase2': [phase2],
            'separation': [abs(freq2 - freq1)],
            'error': [],
            'reg_force': [],
            'phase_error1': [],
            'phase_error2': []
        }
        
        # Loop filter integrals
        phase_error1_integral = 0
        phase_error2_integral = 0
        
        for i, sample in enumerate(signal_data):
            # Generate NCOs
            nco1 = np.exp(1j * phase1)
            nco2 = np.exp(1j * phase2)
            
            # Current signal estimate
            if track_amplitude:
                signal_est = A1 * nco1 + A2 * nco2
            else:
                # Simple correlation for fixed amplitudes
                a1 = sample * np.conj(nco1)
                a2 = sample * np.conj(nco2)
                signal_est = a1 * nco1 + a2 * nco2
            
            # Error
            error = sample - signal_est
            history['error'].append(np.abs(error))
            
            # Phase errors
            if track_amplitude:
                phase_error1 = np.real(np.conj(error) * 1j * A1 * nco1)
                phase_error2 = np.real(np.conj(error) * 1j * A2 * nco2)
            else:
                phase_error1 = np.real(np.conj(error) * 1j * a1 * nco1)
                phase_error2 = np.real(np.conj(error) * 1j * a2 * nco2)
            
            history['phase_error1'].append(phase_error1)
            history['phase_error2'].append(phase_error2)
            
            # Regularization force
            separation = abs(freq2 - freq1)
            reg_force = 0
            if separation < min_separation:
                reg_force = freq_regularization * (min_separation - separation) / min_separation
                if freq2 > freq1:
                    phase_error2 += reg_force
                    phase_error1 -= reg_force
                else:
                    phase_error2 -= reg_force
                    phase_error1 += reg_force
            
            history['reg_force'].append(reg_force)
            
            # Update frequencies
            phase_error1_integral += phase_error1
            phase_error2_integral += phase_error2
            
            freq1 = f1_init + g1 * phase_error1 + g2 * phase_error1_integral
            freq2 = f2_init + g1 * phase_error2 + g2 * phase_error2_integral
            
            # Update phases
            phase1 += 2 * np.pi * freq1 / self.fs
            phase2 += 2 * np.pi * freq2 / self.fs
            phase1 = np.angle(np.exp(1j * phase1))
            phase2 = np.angle(np.exp(1j * phase2))
            
            # Update amplitudes if tracking
            if track_amplitude:
                # Gradient descent on amplitudes with regularization
                learning_rate = 0.01
                
                dA1 = -2 * np.real(np.conj(error) * nco1)
                dA2 = -2 * np.real(np.conj(error) * nco2)
                
                # Add regularization gradient
                dA1 += amplitude_regularization * (A1 - 1.0)
                dA2 += amplitude_regularization * (A2 - 1.0)
                
                A1 -= learning_rate * dA1
                A2 -= learning_rate * dA2
                
                # Constrain to positive
                A1 = max(0.1, A1)
                A2 = max(0.1, A2)
            
            # Store history
            history['freq1'].append(freq1)
            history['freq2'].append(freq2)
            history['A1'].append(A1)
            history['A2'].append(A2)
            history['phase1'].append(phase1)
            history['phase2'].append(phase2)
            history['separation'].append(abs(freq2 - freq1))
        
        # Convert to arrays
        for key in history:
            history[key] = np.array(history[key])
        
        # Final estimates
        converged_f1 = np.mean(history['freq1'][-n_samples//4:])
        converged_f2 = np.mean(history['freq2'][-n_samples//4:])
        
        return {
            'f1': converged_f1,
            'f2': converged_f2,
            'beat': converged_f2 - converged_f1,
            'history': history
        }
    
    def run_from_multiple_initializations(self, signal_data, f1_true, f2_true):
        """Test dual PLL from various starting points"""
        
        # Define test cases
        test_cases = [
            # (f1_init, f2_init, label)
            (f1_true, f2_true, "Truth"),
            (f1_true - 0.010, f2_true + 0.010, "Far from truth"),
            (f2_true, f1_true, "Swapped"),
            (f1_true, f1_true + 0.001, "Very close"),
            (f1_true, f1_true + 0.020, "Far apart"),
            (f1_true - 0.005, f2_true + 0.005, "Symmetric offset"),
            (f1_true + 0.002, f2_true - 0.002, "Inward offset"),
            (5.5, 5.7, "Random far"),
        ]
        
        results = []
        for f1_init, f2_init, label in test_cases:
            result = self.dual_pll_with_tracking(signal_data, f1_init, f2_init)
            result['label'] = label
            result['f1_init'] = f1_init
            result['f2_init'] = f2_init
            results.append(result)
        
        return results
    
    def compute_error_landscape(self, signal_data, f1_range, f2_range, true_f1, true_f2):
        """Compute the error landscape for visualization"""
        n_points = 50
        f1_grid = np.linspace(f1_range[0], f1_range[1], n_points)
        f2_grid = np.linspace(f2_range[0], f2_range[1], n_points)
        
        error_landscape = np.zeros((n_points, n_points))
        
        # Pre-compute true signal for efficiency
        t = np.arange(len(signal_data)) / self.fs
        
        for i, f1 in enumerate(f1_grid):
            for j, f2 in enumerate(f2_grid):
                # Compute error for this (f1, f2) pair
                s1 = np.exp(1j * 2 * np.pi * f1 * t)
                s2 = 0.7 * np.exp(1j * 2 * np.pi * f2 * t)
                estimate = s1 + s2
                
                error = np.mean(np.abs(signal_data - estimate)**2)
                error_landscape[j, i] = error  # Note: j, i for proper orientation
        
        return f1_grid, f2_grid, error_landscape
    
    def visualize_dual_pll_analysis(self, results, signal_data, f1_true, f2_true):
        """Comprehensive visualization of dual PLL behavior"""
        
        fig = plt.figure(figsize=(20, 16))
        gs = gridspec.GridSpec(4, 4, figure=fig, hspace=0.3, wspace=0.3)
        
        # 1. 2D Phase Space Trajectories
        ax1 = fig.add_subplot(gs[0:2, 0:2])
        
        # Compute and plot error landscape
        f1_range = (f1_true - 0.015, f1_true + 0.015)
        f2_range = (f2_true - 0.015, f2_true + 0.015)
        f1_grid, f2_grid, error_landscape = self.compute_error_landscape(
            signal_data, f1_range, f2_range, f1_true, f2_true
        )
        
        # Plot error landscape as contours
        contour = ax1.contourf(f1_grid, f2_grid, np.log10(error_landscape + 1e-10), 
                               levels=20, cmap='viridis', alpha=0.6)
        
        # Plot trajectories
        colors = cm.rainbow(np.linspace(0, 1, len(results)))
        for result, color in zip(results, colors):
            history = result['history']
            ax1.plot(history['freq1'], history['freq2'], '-', color=color, 
                    linewidth=2, alpha=0.8, label=result['label'])
            # Start point
            ax1.plot(result['f1_init'], result['f2_init'], 'o', 
                    color=color, markersize=10, markeredgecolor='black')
            # End point
            ax1.plot(history['freq1'][-1], history['freq2'][-1], 's', 
                    color=color, markersize=10, markeredgecolor='black')
        
        # True values
        ax1.plot(f1_true, f2_true, '*', color='red', markersize=20, 
                markeredgecolor='black', markeredgewidth=2, label='True')
        
        # Diagonal line (f1 = f2)
        diag_line = np.array([min(f1_range[0], f2_range[0]), 
                             max(f1_range[1], f2_range[1])])
        ax1.plot(diag_line, diag_line, 'k--', alpha=0.5, label='f1=f2')
        
        ax1.set_xlabel('f1 (Hz)')
        ax1.set_ylabel('f2 (Hz)')
        ax1.set_title('2D Frequency Space Trajectories')
        ax1.legend(bbox_to_anchor=(1.05, 1), loc='upper left')
        ax1.grid(True, alpha=0.3)
        ax1.set_aspect('equal')
        
        # 2. Separation Evolution
        ax2 = fig.add_subplot(gs[0, 2:])
        
        for result, color in zip(results, colors):
            history = result['history']
            samples = np.arange(len(history['separation']))
            ax2.plot(samples, history['separation'] * 1000, '-', color=color, 
                    linewidth=2, label=result['label'])
        
        ax2.axhline(6.0, color='red', linestyle='--', linewidth=2, label='True separation')
        ax2.axhline(3.0, color='orange', linestyle=':', linewidth=2, label='Min separation')
        ax2.set_xlabel('Sample')
        ax2.set_ylabel('|f2 - f1| (mHz)')
        ax2.set_title('Frequency Separation Evolution')
        ax2.legend()
        ax2.grid(True, alpha=0.3)
        ax2.set_ylim([0, max(20, ax2.get_ylim()[1])])
        
        # 3. Regularization Force
        ax3 = fig.add_subplot(gs[1, 2:])
        
        for result, color in zip(results, colors):
            history = result['history']
            samples = np.arange(len(history['reg_force']))
            ax3.plot(samples, history['reg_force'], '-', color=color, 
                    linewidth=2, label=result['label'])
        
        ax3.set_xlabel('Sample')
        ax3.set_ylabel('Regularization Force')
        ax3.set_title('Regularization Activity')
        ax3.legend()
        ax3.grid(True, alpha=0.3)
        
        # 4. Convergence Comparison
        ax4 = fig.add_subplot(gs[2, :2])
        
        # Bar chart of final errors
        labels = [r['label'] for r in results]
        f1_errors = [(r['f1'] - f1_true) * 1000 for r in results]
        f2_errors = [(r['f2'] - f2_true) * 1000 for r in results]
        beat_errors = [(r['beat'] - (f2_true - f1_true)) * 1000 for r in results]
        
        x = np.arange(len(labels))
        width = 0.25
        
        ax4.bar(x - width, f1_errors, width, label='f1 error', alpha=0.8)
        ax4.bar(x, f2_errors, width, label='f2 error', alpha=0.8)
        ax4.bar(x + width, beat_errors, width, label='beat error', alpha=0.8)
        
        ax4.set_xlabel('Initialization')
        ax4.set_ylabel('Error (mHz)')
        ax4.set_title('Final Estimation Errors')
        ax4.set_xticks(x)
        ax4.set_xticklabels(labels, rotation=45, ha='right')
        ax4.legend()
        ax4.grid(True, alpha=0.3, axis='y')
        ax4.axhline(0, color='black', linewidth=1)
        
        # 5. Signal Reconstruction (for one case)
        ax5 = fig.add_subplot(gs[2, 2:])
        
        # Use the "Truth" initialization case
        truth_result = results[0]
        history = truth_result['history']
        
        # Reconstruct signals at a few time points
        t = np.arange(len(signal_data)) / self.fs
        time_points = [0, len(signal_data)//4, len(signal_data)//2, -1]
        
        for i, tp in enumerate(time_points):
            alpha = 0.3 + 0.7 * i / len(time_points)
            if tp == -1:
                label = 'Final'
            else:
                label = f'Sample {tp}'
                
            # Reconstruct
            s1 = history['A1'][tp] * np.exp(1j * 2 * np.pi * history['freq1'][tp] * t)
            s2 = history['A2'][tp] * np.exp(1j * 2 * np.pi * history['freq2'][tp] * t)
            reconstruction = s1 + s2
            
            if tp == -1:
                ax5.plot(t[:100], np.real(reconstruction[:100]), 'k-', 
                        linewidth=2, alpha=alpha, label=label)
            else:
                ax5.plot(t[:100], np.real(reconstruction[:100]), '-', 
                        linewidth=1, alpha=alpha, label=label)
        
        ax5.plot(t[:100], np.real(signal_data[:100]), 'r--', 
                linewidth=2, alpha=0.8, label='True signal')
        ax5.set_xlabel('Time (s)')
        ax5.set_ylabel('Real part')
        ax5.set_title('Signal Reconstruction Evolution')
        ax5.legend()
        ax5.grid(True, alpha=0.3)
        
        # 6. Phase Error Evolution
        ax6 = fig.add_subplot(gs[3, :2])
        
        for i, result in enumerate(results[:4]):  # Show first 4 to avoid clutter
            history = result['history']
            samples = np.arange(len(history['phase_error1']))
            
            ax6.plot(samples[::10], history['phase_error1'][::10], '-', 
                    color=colors[i], alpha=0.6, label=f"{result['label']} PLL1")
            ax6.plot(samples[::10], history['phase_error2'][::10], '--', 
                    color=colors[i], alpha=0.6, label=f"{result['label']} PLL2")
        
        ax6.set_xlabel('Sample')
        ax6.set_ylabel('Phase Error')
        ax6.set_title('Phase Error Evolution')
        ax6.legend()
        ax6.grid(True, alpha=0.3)
        ax6.set_ylim([-0.5, 0.5])
        
        # 7. Summary Statistics
        ax7 = fig.add_subplot(gs[3, 2:])
        ax7.axis('off')
        
        summary_text = "Dual PLL Analysis Summary\n" + "="*40 + "\n\n"
        summary_text += f"True frequencies: f1={f1_true:.6f} Hz, f2={f2_true:.6f} Hz\n"
        summary_text += f"True beat: {(f2_true-f1_true)*1000:.3f} mHz\n\n"
        
        # Find best and worst cases
        beat_errors_abs = [abs(e) for e in beat_errors]
        best_idx = np.argmin(beat_errors_abs)
        worst_idx = np.argmax(beat_errors_abs)
        
        summary_text += f"Best case: {results[best_idx]['label']}\n"
        summary_text += f"  Beat error: {beat_errors[best_idx]:+.3f} mHz\n\n"
        
        summary_text += f"Worst case: {results[worst_idx]['label']}\n"
        summary_text += f"  Beat error: {beat_errors[worst_idx]:+.3f} mHz\n\n"
        
        # Check for exact 6.000 mHz results
        exact_6_count = sum(1 for r in results if abs(r['beat']*1000 - 6.0) < 0.001)
        summary_text += f"Cases with exactly 6.000 mHz: {exact_6_count}/{len(results)}\n"
        
        if exact_6_count > 0:
            summary_text += "\nWARNING: Some cases converged to exactly 6.000 mHz!\n"
            summary_text += "This suggests the algorithm may be biased by:\n"
            summary_text += "- Initial conditions\n"
            summary_text += "- Regularization parameters\n"
            summary_text += "- Numerical precision\n"
        
        ax7.text(0.05, 0.95, summary_text, transform=ax7.transAxes,
                fontsize=11, fontfamily='monospace', verticalalignment='top',
                bbox=dict(boxstyle='round', facecolor='lightyellow', alpha=0.8))
        
        plt.suptitle('Dual PLL Comprehensive Analysis', fontsize=16)
        plt.tight_layout()
        plt.show()
        
        return fig

# Test the dual PLL analyzer
def test_dual_pll_analyzer():
    # Generate test signal
    fs_baseband = 960.0
    duration = 0.3
    n_samples = int(fs_baseband * duration)
    t = np.arange(n_samples) / fs_baseband
    
    # True frequencies (at baseband)
    f1_true = 5.625480
    f2_true = 5.631480  # 6 mHz separation
    
    # Generate two-tone signal
    signal_data = (np.exp(1j * 2 * np.pi * f1_true * t) + 
                   0.7 * np.exp(1j * 2 * np.pi * f2_true * t))
    
    # Add some noise
    noise = 0.01 * (np.random.randn(n_samples) + 1j * np.random.randn(n_samples)) / np.sqrt(2)
    signal_data += noise
    
    # Create analyzer
    analyzer = DualPLLAnalyzer(fs_baseband)
    
    # Run from multiple initializations
    print("Running dual PLL from multiple initializations...")
    results = analyzer.run_from_multiple_initializations(signal_data, f1_true, f2_true)
    
    # Print results
    print("\n" + "="*60)
    print("DUAL PLL ANALYSIS RESULTS")
    print("="*60)
    print(f"True: f1={f1_true:.6f} Hz, f2={f2_true:.6f} Hz, beat={6.000:.3f} mHz")
    print("\nInitialization -> Result:")
    
    for result in results:
        print(f"\n{result['label']}:")
        print(f"  Init: f1={result['f1_init']:.6f}, f2={result['f2_init']:.6f}")
        print(f"  Final: f1={result['f1']:.6f}, f2={result['f2']:.6f}")
        print(f"  Beat: {result['beat']*1000:.3f} mHz (error: {(result['beat']-(f2_true-f1_true))*1000:+.3f} mHz)")
    
    # Visualize
    fig = analyzer.visualize_dual_pll_analysis(results, signal_data, f1_true, f2_true)
    
    # Test with amplitude tracking
    print("\n" + "="*60)
    print("TESTING WITH AMPLITUDE TRACKING")
    print("="*60)
    
    result_amp = analyzer.dual_pll_with_tracking(signal_data, f1_true, f2_true, 
                                                 track_amplitude=True)
    print(f"With amplitude tracking:")
    print(f"  f1={result_amp['f1']:.6f} Hz, A1={result_amp['history']['A1'][-1]:.3f}")
    print(f"  f2={result_amp['f2']:.6f} Hz, A2={result_amp['history']['A2'][-1]:.3f}")
    print(f"  Beat: {result_amp['beat']*1000:.3f} mHz")
    
    return analyzer, results

# Run the test
analyzer, results = test_dual_pll_analyzer()