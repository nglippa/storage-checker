# Visual comparison evidence

The design decision remains Prototype B. This is implementation evidence, not a new design comparison or tournament.

`integration-board.png` places the selected source reference beside integrated Structured Explorer and the preserved classic fallback: dark overview, dark large selection, and light deep selection. The reference screenshots are copied intact into `selected-prototype-b/`; the integrated/classic originals live in `../headless-renders/`. The board only scales and places the source images. The existing classic canvas deliberately stays dark even in light application appearance.

Full-resolution integrated evidence also includes light/dark overview and selections, 40% zoom, framed selection, Levels 1/2/4/6, repeated names, a 1000×640 pt window, and the explored Users folder. These are offscreen hosted production views, not desktop screenshots or proof of physical input/VoiceOver behavior.

Recreate the board with `python3 artifacts/structured-explorer-integration/visual-comparison/render_board.py` from the integration worktree after running the benchmark. Pillow is needed only for the evidence board, not the application.
