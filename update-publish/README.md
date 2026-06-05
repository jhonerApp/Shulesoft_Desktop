# Shulesoft update publish

## Repo contents

- `update-manifest.json` — served via raw GitHub URL to clients
- `ShulesoftV1-*.zip` — hosted on **GitHub Releases** (not in git; over 100 MB limit)

## Automated publish (recommended)

From the main project folder:

```powershell
cd D:\Repository\ShulesoftProject\2026\Shulesoft_latest

# Item list (recommended)
.\publish-update.ps1 -Version 1.0.2 -ChangeItems @(
    "Database: Applied schema patch",
    "Exam: Fixed result export",
    "Dormitory: Improved rent list"
)

# Item list from a text file (one item per line)
.\publish-update.ps1 -Version 1.0.2 -ItemListFile "..\publish\scripts\release-items.txt"

# Single-line title/message (still supported)
.\publish-update.ps1 -Version 1.0.2 -Title "Exam fixes" -Message "Fixed exam result export"
```

### Item list format

Each line is one change. Use `Area: detail` to auto-build the manifest title:

| Input line | Effect |
|------------|--------|
| `Database: Applied schema patch` | Adds **Database** to title; detail in message |
| `Exam: Fixed result export` | Adds **Exam** to title |
| `Fixed login bug` | Detail only (no module name) |

Example file (`release-items.txt`):

```text
# Release 1.0.2
Database: Applied schema patch
Exam: Fixed result export
Dormitory: Improved rent list
```

Auto-generated manifest example:

- **title:** `Database + Exam + Dormitory update`
- **message:** `Database: Applied schema patch; Exam: Fixed result export; Dormitory: Improved rent list`
- **GitHub release notes:** markdown bullet list

Copy `scripts\release-items.example.txt` as a starting template.

Or run the script directly:

```powershell
cd D:\Repository\ShulesoftProject\2026\publish\scripts
.\Publish-ShulesoftUpdate.ps1 -Version 1.0.2 -Title "Exam fixes" -Message "Fixed exam result export"
```

### What the script does

1. Builds `Shulesoft V1` + `ShuleUpdater` (Release by default)
2. Stages `Shulesoft V1.exe`, `lib\`, `config\`, `Images\`, `Updater\`
3. Excludes dev folders (`server\`, `logs\`, `*.pdb`)
4. Creates `ShulesoftV1-{version}.zip`
5. Updates `update-manifest.json` (sha256, sizeBytes, download URL)
6. Commits and pushes the manifest
7. Creates tag `v{version}` if missing
8. Uploads the zip to GitHub Releases

### Useful flags

| Flag | Purpose |
|------|---------|
| `-Configuration Debug` | Package from `bin\Debug` instead of Release |
| `-SkipBuild` | Reuse existing build output |
| `-SkipPush` | Only build/package locally |
| `-SkipReleaseUpload` | Push manifest only; upload zip manually |

### Requirements

- Visual Studio / MSBuild installed
- Git authenticated with GitHub (`git push` works)
- GitHub repo: `jhonerApp/Shulesoft_Desktop`

## Manual publish

1. Build Release packages and create the zip locally.
2. Update `update-manifest.json` (version, sha256, sizeBytes, release URL).
3. Commit and push this folder (manifest only).
4. Create a GitHub Release (tag e.g. `v1.0.2`) and upload the zip as a release asset.
5. Ensure `package.url` matches:
   `https://github.com/jhonerApp/Shulesoft_Desktop/releases/download/v1.0.2/ShulesoftV1-1.0.2.zip`

## Client config

Installed apps read:

`https://raw.githubusercontent.com/jhonerApp/Shulesoft_Desktop/master/update-publish/update-manifest.json`

Keep `current_version` in the **installed** app lower than `latestVersion` in the manifest so updates are detected.
