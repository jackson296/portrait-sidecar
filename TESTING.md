# Validation — 2026-10-24

- Built with the macOS 27 SDK, explicitly targeting macOS 14+ on the development Mac's architecture.
- Preset tests passed for six native iPad pixel sizes, including portrait/landscape input dimensions and native Retina point sizes.
- CoreGraphics validation on the development Mac advertised all four generated Air 3 workspace sizes at both 1× and 2×: 667 × 889, 834 × 1112, 1001 × 1335, and 1251 × 1668.
- The redesigned app launched with its icon and the Display, Workspace, and Rendering controls. Its native dark appearance was visually inspected.
- The preceding GPU build was user-confirmed working on iPad Air 3, with Retina rendering, Dock placement, and cursor redirection. A local animation test measured 57 updated fps.
- The new build requires Screen Recording permission to be refreshed before live dropdown changes can be verified end to end. This remains an explicit pending check.
- Light/dark system adaptation is implemented through native AppKit colors, materials, appearance, and controls. Full visual testing under all OS appearance/accessibility settings, macOS 14/15, Intel hardware, and other iPad models remains pending.
