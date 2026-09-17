# Launcher

A macOS application launcher built with Swift and AppKit. Requires macOS 14 or later.

`make check` runs the tests. `make install` builds `/Applications/Launcher.app` and opens it; the running app registers itself as a login item. `make dmg` writes a disk image to `.local/dist`; `make uninstall` removes the installed app.

The panel scans application folders whenever it opens, including `~/Applications`, `/Applications`, and system applications. Apps inside one folder level are included.

Search uses case-insensitive exact, prefix, and word-prefix matching, then usage frequency and recency. Launching an app learns the typed query. Learned aliases and usage live in `aliases.json` and `usage.json` under `~/Library/Application Support/Launcher`. To hide apps, list their bundle identifiers in `hidden.json` in the same folder, for example `["com.apple.Automator"]`; the list is re-read each time the panel opens.

The implementation follows one path:

```text
Main → Launcher → Catalog → Rank ← History
          ↓                        ↑
     PanelContent ── launch ────────┘
```
