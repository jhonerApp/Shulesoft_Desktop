# Shulesoft update publish

## Repo contents

- `update-manifest.json` — served via raw GitHub URL to clients
- `ShulesoftV1-*.zip` — **not** stored in git (over 100 MB limit)

## Publish a new version

1. Build Release packages and create the zip locally.
2. Update `update-manifest.json` (version, sha256, sizeBytes, release URL).
3. Commit and push this folder (manifest only).
4. Create a GitHub Release (tag e.g. `v1.0.1`) and upload the zip as a release asset.
5. Ensure `package.url` in the manifest matches:
   `https://github.com/jhonerApp/Shulesoft_Desktop/releases/download/v1.0.1/ShulesoftV1-1.0.1.zip`

## Upload release (GitHub website)

1. Open https://github.com/jhonerApp/Shulesoft_Desktop/releases/new
2. Choose tag `v1.0.1`, title `v1.0.1`
3. Attach `ShulesoftV1-1.0.1.zip` from this machine (same folder as this repo, gitignored)
4. Publish release
