# Project guidance

- Launcher is a dependency-free Swift 6 / AppKit application for macOS 14+; prefer native APIs.
- `Launcher.swift` owns panel lifecycle and input; `Views.swift` owns presentation; `Catalog.swift`, `Rank.swift`, and `History.swift` own discovery, matching, and persistence.
- Search uses exact, prefix, and word-prefix matching plus learned aliases and usage; preserve the Unicode behavior covered by existing checks.
- User data lives in `~/Library/Application Support/Launcher/{aliases,usage,hidden}.json`; use temporary directories for persistence checks.
- Run `make check` for code changes; extend `Tests/LauncherTests/Checks.swift` for uncovered behavior.
- Verify UI changes in the native app, including affected hotkey, focus, dismissal, input-source restoration, and launch behavior; tests alone do not prove these.
- `make app` packages locally; `make install` replaces `/Applications/Launcher.app`, opens it, and may register a login item, so use it only when installation is requested.
- Keep scratch files and distribution artifacts under `.local/`; use `make dmg` for disk images.
