# Top Menu-Bar Logo Design QA

- source visual truth path: `docs/duck-logo.png`
- implementation screenshot path: `docs/verification/status-bar-logo-render.png`
- full-view comparison evidence: `docs/verification/status-bar-logo-comparison.png`
- viewport: 18 × 18 pt macOS status item; 36 × 36 px at 2× density
- source pixel dimensions: 1254 × 1254 px, RGB, no alpha channel
- implementation pixel dimensions: 18 × 18 px at 1×, 36 × 36 px at 2×, 54 × 54 px at 3×
- density normalization: the source subject was isolated from its baked checkerboard, optically centered, and sampled at the real 18 pt menu-bar size
- state: light and dark macOS menu-bar backgrounds

## Findings

No actionable P0, P1, or P2 differences remain for the requested dedicated light-gray top menu-bar icon.

## Full-view comparison evidence

`docs/verification/status-bar-logo-comparison.png` places the supplied source and the compiled status-item asset in one board. The implementation preserves the ring geometry, metallic light-gray treatment, highlights, center opening, and visual direction. The baked checkerboard is intentionally removed because it is not transparency in the source file.

## Focused region comparison evidence

The implementation board includes the 36 px @2× asset rendered at its real menu-bar size on both light and dark backgrounds, plus a nearest-neighbor inspection enlargement. A separate focused crop is unnecessary because the complete component is only 18 pt and is already shown at actual size and enlarged in the same comparison.

## Required fidelity surfaces

- Fonts and typography: not applicable to the icon itself; no text or glyph substitute is used.
- Spacing and layout rhythm: the icon remains 18 × 18 pt, with the logo filling about 90% of the slot so it is readable without crowding the menu bar.
- Colors and visual tokens: the supplied light-gray metallic palette is preserved with `isTemplate = false`; both light and dark background checks remain legible.
- Image quality and asset fidelity: the supplied raster asset is used directly after alpha extraction, not redrawn as SVG/CSS/code. The center is truly transparent and the outer edge has antialiasing with no checkerboard residue.
- Copy and content: no copy is present; the existing tooltip and accessibility label remain “一念”.

## Comparison history

- Pass 1 — P1: the source PNG had no alpha channel, so using it directly would display a white checkerboard square in the macOS menu bar.
- Fix: isolated the supplied gray logo, restored transparency to both the exterior and center opening, then generated dedicated 1×/2×/3× status assets.
- Pass 2 — passed: the combined light/dark render shows clean transparency, preserved gray shading, balanced optical size, and no baked-background artifacts.

## Implementation checklist

- [x] Add a dedicated `StatusBarLogo` asset separate from the launcher brand logo and application icon.
- [x] Generate 18, 36, and 54 px transparent resources.
- [x] Point the macOS `NSStatusItem` at `StatusBarLogo`.
- [x] Preserve the existing colored brand and Dock application icon.
- [x] Compile the asset catalog and confirm `StatusBarLogo` is embedded in the built `Assets.car`.
- [x] Verify light and dark menu-bar contrast at real 18 pt size.

## Follow-up polish

No additional visual polish is required for this component.

final result: passed
