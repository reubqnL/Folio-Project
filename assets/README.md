# Project assets

Branding and identity assets for the Folio project.

| File | Purpose |
|---|---|
| `folio-app-icon.png` | The approved Folio logo, 1024×1024. Do not edit without approval. |

This is **not** the app's asset catalogue. The images compiled into the
application bundle live in [`App/Resources/Assets.xcassets/`](../App/Resources/Assets.xcassets)
(`AppIcon.appiconset` and `FolioLogo.imageset`). The logo in
`FolioLogo.imageset/folio.png` is a byte-identical copy of
`folio-app-icon.png`; `tools/package-native.py` asserts that they stay in sync.

Design concepts and captures are documentation, not app assets — see
[`docs/design/concepts/`](../docs/design/concepts).
