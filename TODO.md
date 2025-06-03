# TODO



# Eigenvalue decomposition of peaks.
# Start with two organ pipes playing distinct tones. One pipe's fundamental is very close to some overtone of the other pipe.
# We identify all relevant peaks, using Newton's method with DFTs to accurately find peaks in frequency space.
# Each peak attests to one fundamental, but if there are very slight tuning errors, then they may appear to be a single peak.
# But we can infer the frequency of each fundamental by looking at the ensemble and using linear algebra, or non-negative matrix factorization some optimization method.
# We assume that the frequencies are mathematically almost perfect.
# There will be small errors, but we should be able to determine the fundamental of each pipe. 





# Fix rendering scales and bounds



# Do time domain tracking
# Use Newton's method in the frequency domain to find peaks

# Tuning stuff: Temperament, partials, note names, buttons, state storage, 
# Watch integration



# Someday maybe:
- SensorPush HT.w or HTP.xw integration
- Stretch tuning
- 




formula, approach, context, assumptions/limits, accuracy, use-case, parameters, return



# UI Specification:

# UI Style
- All buttons are large, and either filled, tinted, or grayed out
- All control panels and buttons take up as much space as possible.
- Distinct separation between buttons.

Tuning Parameter Store:
- This is an object that manages the actual tuning target and settings. It stores variables like
        - Concert pitch
        - Target pitch
        - Target partial
        - Overtone profile (depends on the timbre)
        - Profile for end correction.
        - Temperament
        - Gate time (milliseconds)
        - Audible tone generator, on/off
        - Setting to change how many semitones the buttons change the target pitch by
        - UI state
        - Mutation stop? (Transpose)

Additional return values from Study.swift:

- Refined pitch ensemble
        - Uses the Newton's method (with DFT calls) to find peaks in frequency space
        - Requires peak finding first


Fine pitch bar display
- Visual aid
```
(       +---     )
(  -----+        )
```


Amplitude bar display
- Visual aid
- At some point we may expand this to show the relative amplitude of overtoness
```
 |->
 |----->
```

Carousel Display
- Visual aid
- Within a box, green bars get animated like a carousel. The carousel rotates left or right depending on the pitch, and the speed increases the more out of tune it is.
```
________________________
|  ###   ###   ###   ##|
------------------------
```

Numerical Display for Pitch
- Shows actual pitch's deviation from target pitch
- Multiple units displayed in a table:
        - cents
        - beat
        - error in Hz
        - target Hz
        - actual Hz from microphone
        - theoretical target pipe length (naive)
        - pipe length correction value (naive)
        - pipe length correction value (advanced method, selected in submenu)
        
