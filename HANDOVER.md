# Handover: new IcePick logo and wordmark

The logo is changing from **icicles dripping off a window** to **concept B, "Ice cube"**: an ice pick driven into a cracked ice cube. There is also a new **wordmark** for the README, where the pick stands in for the "I" of "IcePick". The owner has approved both designs exactly as specified below, including the tightened pick-to-text spacing, so don't change them.

## Where the logo lives today

The logo is drawn in code, not stored as a file. [lib/Logo.ps1](lib/Logo.ps1) defines the shapes once on a 64×64 grid and draws them in two ways:

| Function | Draws with | Used by |
|---|---|---|
| `Get-CFLogoSvg -Size -Id` | SVG string | [lib/Report.ps1:172](lib/Report.ps1:172) (favicon, base64) and [lib/Report.ps1:174](lib/Report.ps1:174) (report header, inline) |
| `New-CFLogoBitmap -Size` | GDI+ | [IcePick-GUI.ps1:125](IcePick-GUI.ps1:125) (title-row picture) and `Get-CFLogoIcoBytes` |
| `Get-CFLogoIcoBytes` / `New-CFLogoIcon` | calls `New-CFLogoBitmap` for 9 sizes | [IcePick-GUI.ps1:118](IcePick-GUI.ps1:118) (window icon), `tools\Export-Logo.ps1` |

[tools/Export-Logo.ps1](tools/Export-Logo.ps1) writes `assets\icepick.ico`, `assets\logo.svg` and `assets\logo-256.png` from those functions. [README.md:1](README.md:1) shows `assets/logo.svg`.

**Keep the function names and parameters unchanged** so that no caller has to change. Only the drawing code inside them changes.

## 1. The new mark (concept B, 64×64 grid)

Here is the approved SVG, self-contained. It is the reference that both renderers must match:

```svg
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64" width="256" height="256" role="img" aria-label="IcePick logo">
  <defs>
    <linearGradient id="cf-steel" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#F2F6FA"/><stop offset="1" stop-color="#8FA0B2"/></linearGradient>
    <linearGradient id="cf-iceSoft" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#EAF7FF"/><stop offset="1" stop-color="#7CC3F0"/></linearGradient>
  </defs>
  <!-- cube: top face, right face, front face -->
  <path d="M8,22 L18,12 L54,12 L44,22 Z" fill="#E6F6FF" stroke="#1E3A5F" stroke-width="2.5" stroke-linejoin="round"/>
  <path d="M44,22 L54,12 L54,48 L44,58 Z" fill="#4AA3E0" stroke="#1E3A5F" stroke-width="2.5" stroke-linejoin="round"/>
  <rect x="8" y="22" width="36" height="36" rx="3" fill="url(#cf-iceSoft)" stroke="#1E3A5F" stroke-width="2.5"/>
  <!-- highlight on the front face -->
  <path d="M14,28 h10 M14,28 v8" stroke="#FFFFFF" stroke-width="2" stroke-linecap="round" opacity=".8"/>
  <!-- cracks radiating from the impact point (27,40) -->
  <path d="M27,40 l-5,4 l1,5 M27,40 l6,6 M27,40 l-2,-7" stroke="#1E3A5F" stroke-width="1.5" stroke-linecap="round" fill="none"/>
  <!-- the pick: drawn horizontally (handle butt at x=0, tip at x=50), then moved and rotated -->
  <g transform="translate(62.4,4.6) rotate(135)">
    <rect x="0" y="-5" width="20" height="10" rx="5" fill="#1E3A5F"/>
    <g stroke="#4F7FB3" stroke-width="1.3" stroke-linecap="round">
      <line x1="6" y1="-2.8" x2="6" y2="2.8"/><line x1="10" y1="-2.8" x2="10" y2="2.8"/><line x1="14" y1="-2.8" x2="14" y2="2.8"/>
    </g>
    <rect x="19" y="-3.6" width="5" height="7.2" rx="1" fill="#C3CED9" stroke="#1E3A5F" stroke-width="1"/>
    <path d="M24,-2.6 L50,0 L24,2.6 Z" fill="url(#cf-steel)" stroke="#1E3A5F" stroke-width="1" stroke-linejoin="round"/>
  </g>
</svg>
```

Draw in exactly this order: the cube faces, then the highlight, then the cracks, then the pick on top. The pick's tip lands on the crack centre at (27,40).

### Porting notes

- **Colours.** Replace `$script:CFLogoColors` with named entries for the colours above:
  - Navy `#1E3A5F` is used for the outlines, the pick handle and the cracks.
  - The handle grooves are `#4F7FB3` and the ferrule is `#C3CED9`.
  - The cube faces are `#E6F6FF` (top) and `#4AA3E0` (right).
  - The front face is a gradient from `#EAF7FF` to `#7CC3F0`.
  - The spike is a gradient from `#F2F6FA` to `#8FA0B2`.
- **Remove the old tables.** Delete `$script:CFLogoWindow` and `$script:CFLogoIcicles`. Put the new geometry in similar script-scope tables if it helps keep both renderers in sync.
- **SVG gradient ids.** Prefix every gradient id with `$Id`, as the current code does with `$Id-ice`. The report inlines one copy of the logo and embeds another as the favicon. Their ids must not collide.
- **GDI+ transforms.** GDI+ and SVG use the same convention here: y points down and positive angles turn clockwise. So the SVG transforms map directly:
  - The pick is `$g.TranslateTransform(62.4, 4.6); $g.RotateTransform(135)`. Draw the pick parts in its local coordinates, then restore the state with `$g.Save()` / `$g.Restore()`. All of this happens after the existing `ScaleTransform($Size/64, $Size/64)`.
- **GDI+ gradients:**
  - Front face (`iceSoft`): the gradient runs diagonally over the rect's bounding box, from (8,22) to (44,58).
  - Spike (`steel`): the gradient runs across the spike's width in the pick's local coordinates, from (0,-2.6) to (0,2.6). Create the brush while the rotation is applied.
  - Nudge the end point by `+0.01`, as the current icicle code does, to avoid GDI+ seam artefacts.
- **Rounded rects.** GDI+ has no rounded-rect primitive. The rect with rx=3, the handle with rx=5 (fully rounded ends) and the ferrule with rx=1 each need an arc path, like the existing `$window` path.
- **Highlight opacity.** The `.8` opacity becomes `Color.FromArgb(204, 255, 255, 255)`.
- **Edge clearance.** The handle butt reaches about x≈63.9 and y≈3.1, so it only just fits inside 64. Don't add padding or clip it.
- **Header comment.** Update the top comment in `Logo.ps1` to say "a pick driven into a cracked ice cube".

## 2. The wordmark (README header)

The approved wordmark uses a 176×64 viewBox. The pick is vertical, with the butt at the top and the tip pointing down. It replaces the "I", so the text only reads "cePick":

```svg
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 176 64" width="264" height="96" role="img" aria-label="IcePick">
  <defs>
    <linearGradient id="wm-steel" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#F2F6FA"/><stop offset="1" stop-color="#8FA0B2"/></linearGradient>
  </defs>
  <g transform="translate(16,4) rotate(90) scale(1.12)">
    <rect x="0" y="-5" width="20" height="10" rx="5" fill="#1E3A5F"/>
    <g stroke="#4F7FB3" stroke-width="1.3" stroke-linecap="round">
      <line x1="6" y1="-2.8" x2="6" y2="2.8"/><line x1="10" y1="-2.8" x2="10" y2="2.8"/><line x1="14" y1="-2.8" x2="14" y2="2.8"/>
    </g>
    <rect x="19" y="-3.6" width="5" height="7.2" rx="1" fill="#C3CED9" stroke="#1E3A5F" stroke-width="1"/>
    <path d="M24,-2.6 L50,0 L24,2.6 Z" fill="url(#wm-steel)" stroke="#1E3A5F" stroke-width="1" stroke-linejoin="round"/>
  </g>
  <text x="24" y="50" font-family="Segoe UI, system-ui, sans-serif" font-weight="700" font-size="46" fill="#1E3A5F" letter-spacing="-1">ce<tspan fill="#3E9BE0">Pick</tspan></text>
</svg>
```

- **Spacing is final.** The pick is centred on x=16, and its right edge is at about x=22.7. The text starts at `x="24"`. Don't move either one.
- **Fonts.** GitHub shows README SVGs through `<img>`, so the viewer's browser renders the text with the viewer's fonts. Segoe UI only exists on Windows, and on macOS or Linux the fallback font changes the letter widths and the spacing. To make it look the same everywhere, pick one of these:
  1. **Preferred:** convert the text to paths so the SVG no longer depends on fonts. For example, run `inkscape wordmark.svg --export-text-to-path --export-plain-svg -o wordmark.svg` on a Windows machine that has Segoe UI. Commit the outlined file.
  2. Alternatively, render a 2× PNG (528×192) from the SVG in a browser on Windows and use that in the README.

  In both cases, keep the editable source with its `<text>` element as `assets/wordmark-source.svg`.
- **Where it goes.** Save the file as `assets/wordmark.svg`, or `wordmark.png` if you use the PNG route. It is a static asset: no PowerShell function is needed, and the app and report don't use it.

## 3. Regenerate and update the docs

1. Rewrite the drawing code in `lib\Logo.ps1` (section 1).
2. Run `powershell -ExecutionPolicy Bypass -File tools\Export-Logo.ps1` to regenerate `assets\icepick.ico`, `assets\logo.svg` and `assets\logo-256.png`.
3. Add the wordmark files to `assets\` (section 2).
4. In [README.md](README.md):
   - Replace line 1, `<img src="assets/logo.svg" width="96" alt="IcePick logo">`, with `<img src="assets/wordmark.svg" height="64" alt="IcePick">`.
   - The `# IcePick` heading on line 3 then repeats the name. Removing it is optional; ask the owner.
   - Update the `assets\` line (around line 85) so it also lists the wordmark files.
5. Run the test suite (`tests\Run-Tests.ps1`). No test covers the logo, but `Logo.ps1` is loaded by both the app and the tests, so a syntax error there would break everything.

## 4. How to check it

- **SVG matches the reference.** Open `assets\logo.svg` in a browser next to the reference SVG in section 1. They should look identical.
- **GDI+ matches the SVG.** Open `assets\logo-256.png` and compare it with the SVG. Check that the pick angle, the tip landing on the crack centre and the gradient directions all match.
- **Small sizes.** Check the `.ico` at 16 and 32 px. For example, point a desktop shortcut at it, or view the frames. The cube and the diagonal pick must still read at 16 px.
- **App and report.** Run `IcePick-GUI.ps1` and check the window icon and the title-row logo. Generate a report and check the header logo and the browser-tab favicon.
- **Wordmark.** Preview the README on GitHub, or in a Markdown preview, on a non-Windows machine if possible. That confirms the outlined wordmark keeps its spacing.
