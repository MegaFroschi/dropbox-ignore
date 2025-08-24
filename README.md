# Dropbox Ignore

A _lightweight_ PowerShell utility that brings **`.gitignore`-style rules** to Dropbox on Windows.
It uses the NTFS alternate data stream `com.dropbox.ignored` to tell Dropbox which files/folders to skip.

-   Supports: `*`, `?`, `**` (globstar), negation `!`, **root anchoring** with leading `/`, and directory-only rules with trailing `/`
-   **Dry-run** mode (`-Check`) to preview changes
-   Does not use a “Clear then Reapply” strategy to avoid sync storms
-   Uses `%USERPROFILE%\Dropbox` as the default dir

> **Heads up:** The script relies on NTFS Alternate Data Streams (ADS). This is **Windows/NTFS only**.

## Quick start

1. Clone repository onto your system.
2. Modify the `.ignoredropbox` file with rules (see examples below).
3. Run a dry run:
    ```powershell
    .\dropbox-ignore.ps1 -Check
    ```
4. Check if result is good
5. Apply for real:
    ```powershell
    .\dropbox-ignore.ps1
    ```

### Parameters

-   `-IgnoreFile` → path to `.ignoredropbox` (default: `.ignoredropbox` in current dir of script)
-   `-Root` → folder tree to apply rules on (default: `%USERPROFILE%\Dropbox`)
-   `-Check` → dry-run mode, shows what would change without touching ADS
-   `-Unsafe` → include **symlinks/junctions (reparse points)** in traversal (default: skipped)

## Rule syntax

Patterns are evaluated relative to the chosen `-Root`.

-   `*` → any chars within a single path segment
-   `?` → single char within a segment
-   `**` → any chars across **any number of directories**
-   `name/` → **directory-only** rule (matches the dir itself and everything under it)
-   `!pattern` → **negate** a previous match (last match wins)
-   `/pattern` → **root-anchored** rule, matches only at the root of `-Root`

### Examples

| Pattern         | Matches (examples)                               | Doesn’t match                   |
| --------------- | ------------------------------------------------ | ------------------------------- |
| `node_modules/` | `proj/node_modules/…`, `a/b/node_modules/…`      | a **file** named `node_modules` |
| `dist/**`       | contents of any `dist` dir, not the dir itself   | the `dist/` dir itself          |
| `dist/`         | the `dist` dir **and** everything under it       | —                               |
| `dist/**/`      | subfolders inside `dist/`                        | files inside `dist/`            |
| `*.log`         | `error.log`, `a/b/trace.log`, `c.LOG`, `.log`    | a folder named `something.log`  |
| `**/*.tmp`      | `a/b/c/file.tmp`, `root.tmp`, `.tmp`             | a folder named `file.tmp`       |
| `/main.log`     | only `main.log` at the root of `-Root`           | `src/main.log`                  |
| `/dist/`        | only the top-level `dist` folder                 | `src/dist/`                     |
| `!keepme.log`   | re-includes `keepme.log` even if `*.log` matched | —                               |

> Matching is **case-insensitive** on Windows.

## Typical `.ignoredropbox`

```gitignore
# Dropbox defaults
/.dropbox.cache

# Common junk
_.log
_.tmp

# Packages & build output
node_modules/
dist/

# Root-only
/.env
```

## What the script actually does

-   Walks the tree from `-Root`.
-   For each path, decides **should be ignored** or **not ignored** (last matching rule wins).
-   Compares desired vs actual ADS flag:
    -   **Ignore** → writes ADS `com.dropbox.ignored` with value `1`
    -   **Unignore** → deletes the ADS (fallback: clears it if deletion fails)
-   **Skips** recursing into directories that are (or will be) ignored.
-   **Descends** into directories that become unignored to clean any stale child flags.
-   Quiet output; summary shows: `X ignored, Y unignored, Z unchanged`.

### Dry-run

```powershell
.\dropbox-ignore.ps1 -Check
```

Shows “Would IGNORE/UNIGNORE …” only for **real changes**.
Summary reflects what would happen.

## Notes & limits

-   **Windows/NTFS only** (uses ADS).
-   **Dropbox behavior:** once a directory is flagged ignored, Dropbox ignores its contents automatically.
-   **Symlinks/junctions:** reparse points are **skipped** by default. Use `-Unsafe` to include them in traversal.
-   **Performance:** first run scans everything; subsequent runs are fast and usually silent.
-   **Processing:** not reactive. Adding or removing files/folders, or editing `.ignoredropbox`, requires re-running the script. Keep in mind: if you delete and recreate an already ignored file or folder, the Dropbox ignore flag is lost and the script must be rerun for this also.

## Troubleshooting

-   **I see “Would UNIGNORE …” spam.**
    The script only unignores when the ADS value is `1`. Empty ADS left by other tools will be cleaned on a real run.

-   **`**/_.log`didn’t catch root logs.**
That’s expected. Use`_.log` to catch logs at any depth, including root.

-   **A folder matched `dist/**`, but the folder itself shows nothing.**
Correct — `dist/**` matches **contents only\*\*. Use `dist/` to match folder + contents.

## License & attribution

MIT License. See [LICENSE](./LICENSE). <br>
Built by [@MegaFroschi](https://github.com/MegaFroschi). Pattern engine and logic generated with help of ChatGPT.

---

<br>

> **Disclaimer:** While tested (very loosely) on real projects, use at your own risk.
