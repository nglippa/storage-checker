# Native QA observations

No window was focused, launched, raised or clicked, and no pointer, scroll or keyboard input was sent to the desktop. This follows AGENTS.md desktop-safety rules 1–10. Every hosted view ran offscreen: a borderless window never ordered in, or `ImageRenderer`, in processes with activation policy `.prohibited`. The dev viewer the user had open (PID 85896, `application.local.macbook.storage-monitor.viewer.dev…`) was left alone.

## Verified headlessly (in-process, no desktop input)

- The real `CapacityChart` hover geometry: 47 readings × 4 sizes × 2 appearances × with or without a selection.
- `LivingTreeInputView.scrollWheel` receiving real `NSEvent`s built from `CGEvent`s (line and pixel units, Shift).
- Gesture interpretation: 80 combinations.
- Every screenshot in this folder is an offscreen render of the real views.

## NOT VERIFIED (each needs a focused window and real input, so the user's permission)

1. Monitoring chart: moving a physical pointer across the whole trace, especially its right third, shows no flicker, and the callout follows smoothly.
2. Monitoring chart: clicking a point still selects the event and focuses the table row.
3. Living Tree: a physical mouse wheel zooms in 2D and 3D and never orbits.
4. Living Tree: the Mac mini's actual mouse (Magic Mouse or smooth-scrolling) zooms rather than pans.
5. Living Tree: trackpad pinch, vertical scroll, sideways swipe and momentum, if a trackpad is attached.
6. Living Tree: scrolling the Inspector or Navigator beside the tree still scrolls those panels.
7. Living Tree: drag pans or turns, a drag from a label doesn't select, and double-click explores.
8. Prototypes A and B in the showcase app: the same input checks; Levels stepper, Up, breadcrumb and Explore; inspector contents list with the keyboard.
9. VoiceOver on the prototypes' inspector rows and the Explore action.
10. Keyboard focus after clicking the chart (it should go to the event table) in a real window.
