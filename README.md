# files-portable-builder

Build an **unpackaged, self-contained portable** build of [Files](https://github.com/files-community/Files) with **GitHub Actions**.

- No MSIX registration
- .NET + Windows App SDK bundled in the output folder
- Settings under `Data\` next to `Files.exe`
- Artifact ZIP attached to each successful run / release

> Not affiliated with Files Community. Upstream is MIT/MPL. Use at your own risk.

## Quick start

1. Open **Actions** → **Build Portable Files**
2. **Run workflow** (optional: choose arch / upstream ref)
3. When green, download **Artifacts** → `Files-Portable-win-x64` (or arm64)
4. Unzip on any Windows 10/11 PC (offline OK) → run `Files.exe`

No local SDK, no NuGet, no internet on the target PC required for **running** the artifact.

## What you get

```text
Files-Portable-win-x64/
  Files.exe                 # double-click, no install
  Files.App.Server.exe
  *.dll                     # runtimes confined here
  Data/                     # created on first launch
  PORTABLE_README.txt
  Files-Portable.cmd
```

## Workflow inputs

| Input | Default | Meaning |
|--------|---------|--------|
| `upstream_ref` | `main` | files-community/Files branch/tag/SHA |
| `arch` | `x64` | `x64` or `arm64` |
| `configuration` | `Release` | `Release` / `Debug` |

## Offline target PCs

1. Build **on GitHub** (this repo has network).
2. Copy the artifact ZIP via USB to the offline machine.
3. Extract and run `Files.exe`.

## Limits

- Default file manager / some shell integration may not work without package identity
- Auto-update (MSIX) is disabled in portable mode
- Output is large (self-contained)
- Build runs on `windows-latest` GitHub-hosted runners

## License

- Scripts / workflow in this repo: MIT
- Files application: upstream MIT / MPL — see [files-community/Files](https://github.com/files-community/Files)
