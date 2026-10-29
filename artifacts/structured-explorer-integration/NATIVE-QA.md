# Native QA — session complete; acceptance BLOCKED

The explicitly authorized native session completed in **9m32.94s**. The exact bundle, PID and frontmost window were checked before input, and a separate focus/deadline guard ran throughout. The QA app is closed; the QA preference snapshot was restored and compared equal. No focus-safety stop occurred.

See [NATIVE-RESULTS.md](native-qa/NATIVE-RESULTS.md) for actual outcomes, screenshots, timing evidence and the final seven-check acceptance matrix. The integration report contains the full seventeen-requirement matrix.

Verified natively: Users/Applications selection and Navigator/Inspector agreement; pan without selection change; Fit/Reset; Up navigation; classic fallback and return to Structured Explorer. Native scroll-in changed 100% to 102%.

Acceptance blockers and gaps:

1. **Hierarchy replacement delay:** first matching tree-read completion was 1.52–2.72 seconds after navigation, while earlier snapshots still showed the old tree. First UI frames were 43–77 ms; they do not prove hierarchy readiness. Cause is not yet diagnosed.
2. **Chart hover not positively verified:** eight sampled chart crops were identical, but the expected hover callout was not observed. Static non-hover frames cannot establish hover/flicker acceptance.
3. **Reverse scroll not positively verified:** the sampled reverse-scroll attempt still showed 100%. Physical wheel/trackpad use, pinch and momentum were not verified.
4. **Double-click target and Return retest:** a double-click reached VMware Fusion.app; the intended Applications target was not conclusively matched. Return was sent during pending navigation and did not establish an independent success.
5. **Minimum-window polish:** the app enforced 1000×692 when 1000×640 was requested. Controls remained available, but ring captions crowded/overlapped.
6. **Accessibility:** VoiceOver, larger text, increased contrast and RTL/localization remain NOT VERIFIED. VoiceOver/system accessibility settings were not changed and require separate permission.
7. **Frame pacing:** offscreen frame benchmarks and native first-frame logs are not a controlled display-pacing measurement.

No further GUI interaction, implementation fixes or development milestone was started after the session. A further native session requires fresh authorization.
