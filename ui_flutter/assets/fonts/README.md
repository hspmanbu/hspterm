# Bundled fonts

Unmodified upstream font files under SIL Open Font License 1.1:

- JetBrains Mono Regular: https://github.com/JetBrains/JetBrainsMono/tree/master/fonts/ttf ; license: JetBrainsMono-OFL.txt.
- Noto Sans CJK SC Regular: https://github.com/notofonts/noto-cjk/tree/main/Sans/OTF/SimplifiedChinese ; license: NotoSansCJK-LICENSE.txt.

License texts are bundled as Flutter assets and registered with Flutter's license page. User font import/selection already has static source, pending the final unified verification stage. Font files never enter configuration cloud synchronization.

`HSPNerdSymbols.ttf` is an HSPTerm-generated subset of Nerd Fonts v3.5.1's
Symbols Nerd Font Mono. It retains 1111 codepoints from MIT-licensed Devicon,
Octicons, Seti/original, Powerline and Powerline Extra; it does not claim complete
Nerd icon coverage. Nonselected icon sets are excluded. Two Octicon mappings
use U+2665/U+26A1; other selected mappings are in the BMP private-use area.

- Complete aggregate and component notices: `HSPNerdSymbols-LICENSES.txt`.
- Pinned input hashes, output hash, tool version and exact cmap allowlist:
  `HSPNerdSymbols-MANIFEST.json`.
- Reproduce using the installed HarfBuzz C subset library:
  `python3 tools/prepare_nerd_symbols.py --write` from the repository root.
  Current artifact used HarfBuzz 8.3.0 and is 455944 bytes. Different HarfBuzz
  versions may change the serialized bytes; review the manifest and regenerate
  the source checkpoint together. The packaged application needs neither the
  tool nor a font download.
- UI candidate: JetBrains Mono + Nerd symbols (licensed subset), leaving the
  original default unchanged. The same fixed terminal grid and CJK fallback
  remain in use. Full Nerd families can still be explicitly imported by users.

Asset generation verified pinned downloads and the subset cmap; it is not a
Flutter build or visual rendering/Windows verification. Those remain pending.
