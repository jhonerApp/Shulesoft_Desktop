#Requires -Version 5.1
<#
.SYNOPSIS
    Builds Shulesoft V1, packages an update zip, updates the manifest, and publishes to GitHub Releases.

.EXAMPLE
    .\Publish-ShulesoftUpdate.ps1 -Version 1.0.2 -Title "Bug fixes" -Message "Fixed exam module issues"

.EXAMPLE
    .\Publish-ShulesoftUpdate.ps1 -Version 1.0.2 -Configuration Debug -SkipBuild
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string] $Version,

    [string] $Title = "Shulesoft V1 update",
    [string] $Message = "System update",
    [ValidateSet("Release", "Debug")]
    [string] $Configuration = "Release",

    [string] $MainProjectRoot = "D:\Repository\ShulesoftProject\2026\Shulesoft_latest",
    [string] $PublishRoot = "D:\Repository\ShulesoftProject\2026\publish",
    [string] $GitHubOwner = "jhonerApp",
    [string] $GitHubRepo = "Shulesoft_Desktop",
    [string] $GitHubBranch = "master",

    [switch] $SkipBuild,
    [switch] $SkipPush,
    [switch] $SkipReleaseUpload
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Step([string] $Text) {
    Write-Host "`n==> $Text" -ForegroundColor Cyan
}

function Get-MsBuildPath {
    $vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
    if (-not (Test-Path $vswhere)) {
        throw "vswhere.exe not found. Install Visual Studio with MSBuild."
    }

    $msbuild = & $vswhere -latest -requires Microsoft.Component.MSBuild -find "MSBuild\**\Bin\MSBuild.exe" | Select-Object -First 1
    if (-not $msbuild) {
        throw "MSBuild.exe not found via vswhere."
    }

    return $msbuild
}

function Get-GitHubToken {
    $inputText = "protocol=https`nhost=github.com`n`n"
    $output = $inputText | git credential fill 2>$null
    if (-not $output) {
        throw "GitHub credentials not found. Sign in with Git once: git ls-remote https://github.com/$GitHubOwner/$GitHubRepo.git"
    }

    foreach ($line in $output -split "`n") {
        if ($line -like "password=*") {
            return $line.Substring("password=".Length)
        }
    }

    throw "GitHub token/password not returned by git credential fill."
}

function Invoke-GitHubApi {
    param(
        [string] $Method = "Get",
        [string] $Uri,
        [hashtable] $Headers = @{},
        [byte[]] $Body = $null,
        [string] $ContentType = $null
    )

    $token = Get-GitHubToken
    $baseHeaders = @{
        Authorization          = "Bearer $token"
        Accept                 = "application/vnd.github+json"
        "X-GitHub-Api-Version" = "2022-11-28"
        "User-Agent"           = "Shulesoft-Publish-Script"
    }

    foreach ($key in $Headers.Keys) {
        $baseHeaders[$key] = $Headers[$key]
    }

    $params = @{
        Method      = $Method
        Uri         = $Uri
        Headers     = $baseHeaders
        ErrorAction = "Stop"
    }

    if ($Body) {
        $params.Body = $Body
        if ($ContentType) {
            $params.ContentType = $ContentType
        }
    }

    return Invoke-RestMethod @params
}

function Ensure-BuildOutput {
    param([string] $BinDir)

    $required = @(
        (Join-Path $BinDir "Shulesoft V1.exe"),
        (Join-Path $BinDir "Shulesoft V1.exe.config"),
        (Join-Path $BinDir "lib"),
        (Join-Path $BinDir "config\config.json")
    )

    foreach ($path in $required) {
        if (-not (Test-Path $path)) {
            throw "Build output missing required path: $path"
        }
    }
}

function Resolve-UpdaterExe {
    param(
        [string] $MainBinDir,
        [string] $UpdaterProjectRoot,
        [string] $Configuration
    )

    $candidates = @(
        (Join-Path $MainBinDir "Updater\ShuleUpdater.exe"),
        (Join-Path $MainBinDir "Updater\Shulesoft.Updater.exe"),
        (Join-Path $MainBinDir "updater\ShuleUpdater.exe"),
        (Join-Path $MainBinDir "updater\Shulesoft.Updater.exe"),
        (Join-Path $UpdaterProjectRoot "bin\$Configuration\ShuleUpdater.exe")
    )

    foreach ($path in $candidates) {
        if (Test-Path $path) { return $path }
    }

    throw "ShuleUpdater.exe not found. Build the ShuleUpdater project first."
}

function Update-ManifestJson {
    param(
        [string] $ManifestPath,
        [string] $Version,
        [string] $Title,
        [string] $Message,
        [string] $DownloadUrl,
        [string] $Sha256,
        [long] $SizeBytes
    )

    $manifest = [ordered]@{
        appId         = "ShulesoftV1"
        latestVersion = $Version
        releasedAtUtc = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
        title         = $Title
        message       = $Message
        package       = [ordered]@{
            url       = $DownloadUrl
            sha256    = $Sha256.ToLowerInvariant()
            sizeBytes = $SizeBytes
        }
    }

    $json = ($manifest | ConvertTo-Json -Depth 4)
    Set-Content -Path $ManifestPath -Value $json -Encoding UTF8
}

function Publish-GitHubReleaseAsset {
    param(
        [string] $Tag,
        [string] $ZipPath,
        [string] $ReleaseTitle,
        [string] $ReleaseNotes
    )

    $zipName = [IO.Path]::GetFileName($ZipPath)
    $release = $null

    try {
        $release = Invoke-GitHubApi -Uri "https://api.github.com/repos/$GitHubOwner/$GitHubRepo/releases/tags/$Tag"
    }
    catch {
        $release = $null
    }

    if (-not $release) {
        Write-Step "Creating GitHub release $Tag"
        $payload = @{
            tag_name         = $Tag
            target_commitish = $GitHubBranch
            name             = $ReleaseTitle
            body             = $ReleaseNotes
            draft            = $false
            prerelease       = $false
        } | ConvertTo-Json

        $release = Invoke-GitHubApi `
            -Method Post `
            -Uri "https://api.github.com/repos/$GitHubOwner/$GitHubRepo/releases" `
            -Headers @{ "Content-Type" = "application/json" } `
            -Body ([Text.Encoding]::UTF8.GetBytes($payload)) `
            -ContentType "application/json"
    }
    else {
        Write-Step "GitHub release $Tag already exists"
        foreach ($asset in @($release.assets)) {
            if ($asset.name -eq $zipName) {
                Write-Step "Removing previous asset $zipName"
                Invoke-GitHubApi -Method Delete -Uri "https://api.github.com/repos/$GitHubOwner/$GitHubRepo/releases/assets/$($asset.id)"
            }
        }
    }

    Write-Step "Uploading $zipName to GitHub release"
    $uploadUrl = "https://uploads.github.com/repos/$GitHubOwner/$GitHubRepo/releases/$($release.id)/assets?name=$zipName"
    $bytes = [IO.File]::ReadAllBytes($ZipPath)
    $uploaded = Invoke-GitHubApi -Method Post -Uri $uploadUrl -Body $bytes -ContentType "application/zip"
    return $uploaded.browser_download_url
}

$tag = if ($Version.StartsWith("v", [StringComparison]::OrdinalIgnoreCase)) { $Version } else { "v$Version" }
$zipName = "ShulesoftV1-$Version.zip"
$zipPath = Join-Path $PublishRoot $zipName
$stagingDir = Join-Path $PublishRoot "staging-$Version"
$manifestPath = Join-Path $PublishRoot "update-publish\update-manifest.json"
$solutionPath = Join-Path $MainProjectRoot "Shulesoft V1.sln"
$mainBinDir = Join-Path $MainProjectRoot "Shulesoft V1\bin\$Configuration"
$updaterProjectRoot = Join-Path $MainProjectRoot "ShuleUpdater"
$downloadUrl = "https://github.com/$GitHubOwner/$GitHubRepo/releases/download/$tag/$zipName"
$manifestUrl = "https://raw.githubusercontent.com/$GitHubOwner/$GitHubRepo/$GitHubBranch/update-publish/update-manifest.json"

if (-not (Test-Path $solutionPath)) {
    throw "Solution not found: $solutionPath"
}

if (-not $SkipBuild) {
    Write-Step "Building solution ($Configuration)"
    $msbuild = Get-MsBuildPath
    & $msbuild $solutionPath `
        /t:"ShuleUpdater;Shulesoft V1" `
        /p:Configuration=$Configuration `
        /p:Platform="Any CPU" `
        /m `
        /restore `
        /verbosity:minimal

    if ($LASTEXITCODE -ne 0) {
        throw "MSBuild failed with exit code $LASTEXITCODE"
    }
}

Ensure-BuildOutput -BinDir $mainBinDir

Write-Step "Creating staging folder"
if (Test-Path $stagingDir) {
    Remove-Item $stagingDir -Recurse -Force
}
New-Item -ItemType Directory -Path $stagingDir | Out-Null
New-Item -ItemType Directory -Path (Join-Path $stagingDir "Updater") | Out-Null

Copy-Item (Join-Path $mainBinDir "Shulesoft V1.exe") $stagingDir
Copy-Item (Join-Path $mainBinDir "Shulesoft V1.exe.config") $stagingDir
Copy-Item (Join-Path $mainBinDir "lib") (Join-Path $stagingDir "lib") -Recurse
Copy-Item (Join-Path $mainBinDir "config") (Join-Path $stagingDir "config") -Recurse
if (Test-Path (Join-Path $mainBinDir "Images")) {
    Copy-Item (Join-Path $mainBinDir "Images") (Join-Path $stagingDir "Images") -Recurse
}

$updaterExe = Resolve-UpdaterExe -MainBinDir $mainBinDir -UpdaterProjectRoot $updaterProjectRoot -Configuration $Configuration
Copy-Item $updaterExe (Join-Path $stagingDir "Updater\ShuleUpdater.exe")
$updaterConfig = [IO.Path]::ChangeExtension($updaterExe, ".exe.config")
if (Test-Path $updaterConfig) {
    Copy-Item $updaterConfig (Join-Path $stagingDir "Updater\ShuleUpdater.exe.config")
}

$configPath = Join-Path $stagingDir "config\config.json"
if (Test-Path $configPath) {
    $config = Get-Content $configPath -Raw | ConvertFrom-Json
    $config | Add-Member -NotePropertyName update_manifest_url -NotePropertyValue $manifestUrl -Force
    $config | Add-Member -NotePropertyName current_version -NotePropertyValue $Version -Force
    $config | Add-Member -NotePropertyName auto_check_updates -NotePropertyValue $true -Force
    ($config | ConvertTo-Json -Depth 4) | Set-Content $configPath -Encoding UTF8
}

Write-Step "Creating zip $zipName"
if (Test-Path $zipPath) {
    Remove-Item $zipPath -Force
}
Compress-Archive -Path (Join-Path $stagingDir "*") -DestinationPath $zipPath -CompressionLevel Optimal

$hash = (Get-FileHash $zipPath -Algorithm SHA256).Hash
$size = (Get-Item $zipPath).Length

Write-Step "Updating manifest"
Update-ManifestJson `
    -ManifestPath $manifestPath `
    -Version $Version `
    -Title $Title `
    -Message $Message `
    -DownloadUrl $downloadUrl `
    -Sha256 $hash `
    -SizeBytes $size

if (-not $SkipPush) {
    Write-Step "Committing and pushing manifest"
    Push-Location $PublishRoot
    try {
        git add "update-publish/update-manifest.json"
        git diff --cached --quiet
        if ($LASTEXITCODE -ne 0) {
            git commit -m "Publish system update $Version"
        }

        git push origin $GitHubBranch

        git rev-parse -q --verify "refs/tags/$tag" > $null 2>&1
        if ($LASTEXITCODE -ne 0) {
            git tag -a $tag -m "Shulesoft V1 system update $Version"
            git push origin $tag
        }
    }
    finally {
        Pop-Location
    }
}

if (-not $SkipReleaseUpload) {
    $assetUrl = Publish-GitHubReleaseAsset `
        -Tag $tag `
        -ZipPath $zipPath `
        -ReleaseTitle $tag `
        -ReleaseNotes $Message

    if ($assetUrl -ne $downloadUrl) {
        Write-Warning "Uploaded asset URL differs from expected URL.`nExpected: $downloadUrl`nActual:   $assetUrl"
    }
}

Write-Step "Done"
Write-Host "Version:      $Version"
Write-Host "Zip:          $zipPath"
Write-Host "SHA256:       $($hash.ToLowerInvariant())"
Write-Host "SizeBytes:    $size"
Write-Host "Manifest URL: $manifestUrl"
Write-Host "Download URL: $downloadUrl"
