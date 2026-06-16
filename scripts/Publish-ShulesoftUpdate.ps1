#Requires -Version 5.1
<#
.SYNOPSIS
    Builds Shulesoft V1, packages an update zip, updates the manifest, and publishes to GitHub Releases.

    Database migrations are packaged from publish\database\migrations\v{Version}.sql first,
    then Shulesoft_latest\database\migrations\ as a fallback.

.EXAMPLE
    .\Publish-ShulesoftUpdate.ps1 -Version 1.0.2 -Title "Bug fixes" -Message "Fixed exam module issues"

.EXAMPLE
    .\Publish-ShulesoftUpdate.ps1 -Version 1.0.2 -ChangeItems @(
        "Database: Applied schema patch",
        "Exam: Fixed result export",
        "Dormitory: Improved rent list"
    )

.EXAMPLE
    .\Publish-ShulesoftUpdate.ps1 -Version 1.0.2 -ItemListFile ".\release-items.txt"
    # Or omit -ItemListFile when scripts\release-items.txt exists (auto-detected).

.EXAMPLE
    .\Publish-ShulesoftUpdate.ps1 -Version 1.0.3
    # Uses scripts\release-items.txt automatically if present.

.EXAMPLE
    .\Publish-ShulesoftUpdate.ps1 -Version 1.0.2 -Configuration Debug -SkipBuild

.EXAMPLE
    .\Publish-ShulesoftUpdate.ps1 -Version 1.0.2 -SkipBuild -SkipReleaseUpload
    # Skips upload only when GitHub already matches the local zip; re-uploads automatically on SHA mismatch.

.EXAMPLE
    .\Publish-ShulesoftUpdate.ps1 -Version 1.0.2 -SkipReleaseVerify
    # Upload without waiting for GitHub CDN verification.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string] $Version,

    [string] $Title = "",
    [string] $Message = "",
    [string[]] $ChangeItems = @(),
    [string] $ItemListFile = "",
    [ValidateSet("Release", "Debug")]
    [string] $Configuration = "Debug",

    [string] $MainProjectRoot = "D:\Repository\ShulesoftProject\2026\Shulesoft_latest",
    [string] $PublishRoot = "D:\Repository\ShulesoftProject\2026\publish",
    [string] $GitHubOwner = "jhonerApp",
    [string] $GitHubRepo = "Shulesoft_Desktop",
    [string] $GitHubBranch = "master",

    [switch] $SkipBuild,
    [switch] $SkipPush,
    [switch] $SkipReleaseUpload,
    [switch] $SkipReleaseVerify
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $ItemListFile) {
    $defaultItemList = Join-Path $ScriptDir "release-items.txt"
    if (Test-Path $defaultItemList) {
        $ItemListFile = $defaultItemList
        Write-Host "Using release items file: $ItemListFile" -ForegroundColor DarkGray
    }
}
elseif (-not [System.IO.Path]::IsPathRooted($ItemListFile)) {
    $candidate = Join-Path $ScriptDir $ItemListFile
    if (Test-Path $candidate) {
        $ItemListFile = $candidate
    }
}

function Write-Step([string] $Text) {
    Write-Host "`n==> $Text" -ForegroundColor Cyan
}

function Assert-PublishNotBlocked {
    param([string] $MainBinDir)

    $running = Get-Process -Name "Shulesoft V1" -ErrorAction SilentlyContinue
    if ($running) {
        throw @"
Shulesoft V1 is running and may lock build output files.
Close the application, then run publish again.

Tip: Use -SkipBuild if you already built in Visual Studio and only need to repackage.
"@
    }
}

function Remove-DirectoryForPublish {
    param([string] $Path)

    if (-not (Test-Path $Path)) { return }

    try {
        Remove-Item $Path -Recurse -Force -ErrorAction Stop
    }
    catch {
        throw @"
Could not remove folder because files are in use:
$Path

Close Shulesoft V1 and any Explorer windows showing that folder, then retry.
Original error: $($_.Exception.Message)
"@
    }
}

function Copy-FileShared {
    param(
        [string] $SourcePath,
        [string] $DestinationPath
    )

    $destinationDirectory = Split-Path -Parent $DestinationPath
    if ($destinationDirectory -and -not (Test-Path $destinationDirectory)) {
        New-Item -ItemType Directory -Path $destinationDirectory -Force | Out-Null
    }

    $sourceStream = [System.IO.File]::Open(
        $SourcePath,
        [System.IO.FileMode]::Open,
        [System.IO.FileAccess]::Read,
        [System.IO.FileShare]::ReadWrite)
    try {
        $destinationStream = [System.IO.File]::Open(
            $DestinationPath,
            [System.IO.FileMode]::Create,
            [System.IO.FileAccess]::Write,
            [System.IO.FileShare]::None)
        try {
            $sourceStream.CopyTo($destinationStream)
        }
        finally {
            $destinationStream.Dispose()
        }
    }
    finally {
        $sourceStream.Dispose()
    }
}

function Copy-DirectoryForPackaging {
    param(
        [string] $SourceDirectory,
        [string] $DestinationDirectory
    )

    New-Item -ItemType Directory -Path $DestinationDirectory -Force | Out-Null
    foreach ($sourceFile in Get-ChildItem -Path $SourceDirectory -Recurse -File) {
        $relativePath = $sourceFile.FullName.Substring($SourceDirectory.Length).TrimStart('\', '/')
        $targetPath = Join-Path $DestinationDirectory $relativePath
        Copy-FileShared -SourcePath $sourceFile.FullName -DestinationPath $targetPath
    }
}

function New-UpdateZipArchive {
    param(
        [string] $SourceDirectory,
        [string] $ZipPath
    )

    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem

    if (Test-Path $ZipPath) {
        Remove-Item $ZipPath -Force
    }

    $zipArchive = [System.IO.Compression.ZipFile]::Open(
        $ZipPath,
        [System.IO.Compression.ZipArchiveMode]::Create)
    try {
        foreach ($sourceFile in Get-ChildItem -Path $SourceDirectory -Recurse -File) {
            $relativePath = ($sourceFile.FullName.Substring($SourceDirectory.Length).TrimStart('\', '/')).Replace('\', '/')
            $entry = $zipArchive.CreateEntry($relativePath, [System.IO.Compression.CompressionLevel]::Optimal)
            $entryStream = $entry.Open()
            try {
                $sourceStream = [System.IO.File]::Open(
                    $sourceFile.FullName,
                    [System.IO.FileMode]::Open,
                    [System.IO.FileAccess]::Read,
                    [System.IO.FileShare]::ReadWrite)
                try {
                    $sourceStream.CopyTo($entryStream)
                }
                finally {
                    $sourceStream.Dispose()
                }
            }
            finally {
                $entryStream.Dispose()
            }
        }
    }
    finally {
        $zipArchive.Dispose()
    }

    if (-not (Test-Path $ZipPath)) {
        throw "Zip was not created: $ZipPath"
    }
}

function Test-ChangeItemSegment {
    param([string] $Text)

    return $Text -match '^([^:|]+)[:|]\s*(.+)$'
}

function Expand-ChangeItemLine {
    param([string] $Line)

    $segments = New-Object System.Collections.Generic.List[string]
    if ($Line -notmatch ';') {
        [void]$segments.Add($Line)
        return ,$segments
    }

    foreach ($part in ($Line -split ';')) {
        $segment = $part.Trim()
        if (-not $segment) { continue }
        if ((Test-ChangeItemSegment -Text $segment)) {
            [void]$segments.Add($segment)
            continue
        }

        if ($segments.Count -gt 0 -and (Test-ChangeItemSegment -Text $segments[$segments.Count - 1])) {
            $segments[$segments.Count - 1] = ($segments[$segments.Count - 1] + "; " + $segment).Trim()
        }
        else {
            [void]$segments.Add($segment)
        }
    }

    if ($segments.Count -eq 0) {
        [void]$segments.Add($Line)
    }

    return ,$segments
}

function Read-ChangeItemLines {
    param([string[]] $Lines)

    $items = New-Object System.Collections.Generic.List[string]
    foreach ($line in $Lines) {
        if ($null -eq $line) { continue }
        $trimmed = $line.Trim()
        if (-not $trimmed) { continue }
        if ($trimmed.StartsWith("#")) { continue }

        foreach ($segment in (Expand-ChangeItemLine -Line $trimmed)) {
            [void]$items.Add($segment)
        }
    }

    return ,$items
}

function Build-ReleaseTextFromItems {
    param([string[]] $Items)

    $parsed = Read-ChangeItemLines -Lines $Items
    if ($parsed.Count -eq 0) {
        throw "No change items found. Add -ChangeItems or -ItemListFile with at least one line."
    }

    $modules = New-Object System.Collections.Generic.List[string]
    $details = New-Object System.Collections.Generic.List[string]

    foreach ($entry in $parsed) {
        if ($entry -match '^([^:|]+)[:|]\s*(.+)$') {
            $module = $matches[1].Trim()
            $detail = $matches[2].Trim()
            if ($module -and ($modules -notcontains $module)) {
                [void]$modules.Add($module)
            }
            [void]$details.Add("$module`: $detail")
        }
        else {
            [void]$details.Add($entry)
        }
    }

    $uniqueModules = $modules | Select-Object -Unique
    $autoTitle = if ($uniqueModules.Count -gt 0) {
        if ($uniqueModules.Count -le 6) {
            (($uniqueModules) -join " + ") + " update"
        }
        else {
            "Shulesoft V1 update ($($details.Count) changes)"
        }
    }
    else {
        "Shulesoft V1 update"
    }

    $autoMessage = ($details -join "; ")
    $releaseNotes = ($details | ForEach-Object { "- $_" }) -join [Environment]::NewLine

    return [pscustomobject]@{
        Title        = $autoTitle
        Message      = $autoMessage
        ReleaseNotes = $releaseNotes
        Changes      = @([string[]]$details.ToArray())
        ItemCount    = $details.Count
    }
}

function Resolve-ReleaseText {
    param(
        [string] $Title,
        [string] $Message,
        [string[]] $ChangeItems,
        [string] $ItemListFile
    )

    $allItems = New-Object System.Collections.Generic.List[string]
    foreach ($item in $ChangeItems) {
        if ($item) { [void]$allItems.Add($item) }
    }

    if ($ItemListFile) {
        if (-not (Test-Path $ItemListFile)) {
            throw "Item list file not found: $ItemListFile"
        }
        foreach ($line in (Get-Content -Path $ItemListFile -Encoding UTF8)) {
            if ($line) { [void]$allItems.Add($line) }
        }
    }

    if ($allItems.Count -gt 0) {
        $built = Build-ReleaseTextFromItems -Items $allItems
        return [pscustomobject]@{
            Title        = if ($Title) { $Title } else { $built.Title }
            Message      = if ($Message) { $Message } else { $built.Message }
            ReleaseNotes = $built.ReleaseNotes
            Changes      = @([string[]]$built.Changes)
            ItemCount    = $built.ItemCount
        }
    }

    $manualChanges = @()
    if ($Message) {
        $manualChanges = @($Message -split ';' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    }

    return [pscustomobject]@{
        Title        = if ($Title) { $Title } else { "Shulesoft V1 update" }
        Message      = if ($Message) { $Message } else { "System update" }
        ReleaseNotes = if ($Message) { $Message } else { "System update" }
        Changes      = $manualChanges
        ItemCount    = $manualChanges.Count
    }
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

function Test-IsGitHubNotFoundError {
    param($ErrorRecord)

    if ($null -eq $ErrorRecord) {
        return $false
    }

    $response = $ErrorRecord.Exception.Response
    if ($response) {
        try {
            if ([int]$response.StatusCode -eq 404) {
                return $true
            }
        }
        catch {
            # Ignore response parsing issues and fall back to message matching.
        }
    }

    $message = $ErrorRecord.Exception.Message
    return (-not [string]::IsNullOrWhiteSpace($message)) -and ($message -match '(?i)\b404\b|not found')
}

function Get-GitHubReleaseByTag {
    param(
        [string] $Tag,
        [string] $Owner,
        [string] $Repo
    )

    try {
        return Invoke-GitHubApi -Uri "https://api.github.com/repos/$Owner/$Repo/releases/tags/$Tag"
    }
    catch {
        if (Test-IsGitHubNotFoundError -ErrorRecord $_) {
            return $null
        }
        throw
    }
}

function Save-GitHubReleaseAsset {
    param(
        [long] $AssetId,
        [string] $DestinationPath,
        [string] $Owner,
        [string] $Repo
    )

    $token = Get-GitHubToken
    $uri = "https://api.github.com/repos/$Owner/$Repo/releases/assets/$AssetId"

    Invoke-WebRequest -Uri $uri `
        -Headers @{
            Authorization          = "Bearer $token"
            Accept                 = "application/octet-stream"
            "X-GitHub-Api-Version" = "2022-11-28"
            "User-Agent"           = "Shulesoft-Publish-Script"
        } `
        -OutFile $DestinationPath `
        -UseBasicParsing `
        -ErrorAction Stop
}

function Ensure-BuildOutput {
    param([string] $BinDir)

    $libDir = @(
        (Join-Path $BinDir "lib"),
        (Join-Path $BinDir "Lib")
    ) | Where-Object { Test-Path $_ } | Select-Object -First 1

    if (-not $libDir) {
        throw "Build output missing lib folder under: $BinDir"
    }

    $configJson = @(
        (Join-Path $BinDir "config\config.json"),
        (Join-Path $BinDir "Config\config.json")
    ) | Where-Object { Test-Path $_ } | Select-Object -First 1

    $required = @(
        (Join-Path $BinDir "Shulesoft V1.exe"),
        (Join-Path $BinDir "Shulesoft V1.exe.config"),
        $libDir,
        $configJson
    )

    foreach ($path in $required) {
        if (-not $path -or -not (Test-Path $path)) {
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
        [string[]] $Changes = @(),
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
        changes       = @($Changes)
        package       = [ordered]@{
            url       = $DownloadUrl
            sha256    = $Sha256.ToLowerInvariant()
            sizeBytes = $SizeBytes
        }
    }

    $json = ($manifest | ConvertTo-Json -Depth 4)
    $utf8NoBom = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllText($ManifestPath, $json, $utf8NoBom)

    Write-Host "Manifest package.sha256: $($Sha256.ToLowerInvariant())" -ForegroundColor Green
    Write-Host "Manifest package.sizeBytes: $SizeBytes" -ForegroundColor Green
}

function Get-ZipPackageMetadata {
    param([string] $ZipPath)

    if (-not (Test-Path $ZipPath)) {
        throw "Zip not found: $ZipPath"
    }

    return [pscustomobject]@{
        Sha256    = (Get-FileHash $ZipPath -Algorithm SHA256).Hash.ToLowerInvariant()
        SizeBytes = [long](Get-Item $ZipPath).Length
    }
}

function Add-CacheBusterQuery {
    param([string] $Url)

    if ([string]::IsNullOrWhiteSpace($Url)) {
        return $Url
    }

    $separator = if ($Url.Contains("?")) { "&" } else { "?" }
    return "$Url$separator" + "t=" + [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
}

function Wait-GitHubReleaseAssetRemoved {
    param(
        [string] $Tag,
        [string] $AssetName,
        [string] $Owner,
        [string] $Repo,
        [int] $MaxAttempts = 15,
        [int] $RetryDelaySeconds = 2
    )

    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        $asset = Get-GitHubReleaseAsset -Tag $Tag -AssetName $AssetName -Owner $Owner -Repo $Repo
        if (-not $asset) {
            return
        }

        if ($attempt -lt $MaxAttempts) {
            Write-Host "Waiting for GitHub to remove previous asset (attempt $attempt/$MaxAttempts)..." -ForegroundColor Yellow
            Start-Sleep -Seconds $RetryDelaySeconds
        }
    }

    throw "GitHub release asset '$AssetName' was not removed after $MaxAttempts attempt(s)."
}

function ConvertTo-GitHubReleaseAssetInfo {
    param([object] $Asset)

    if ($null -eq $Asset) {
        return $null
    }

    return [pscustomobject]@{
        AssetId            = [long]$Asset.AssetId
        BrowserDownloadUrl = [string]$Asset.BrowserDownloadUrl
        SizeBytes          = if ($Asset.PSObject.Properties.Name -contains "SizeBytes") { [long]$Asset.SizeBytes } else { 0 }
    }
}

function Get-GitHubReleaseAssetMetadata {
    param(
        [long] $AssetId,
        [string] $DownloadUrl,
        [string] $Owner,
        [string] $Repo,
        [int] $MaxAttempts = 12,
        [int] $RetryDelaySeconds = 10
    )

    $tempZip = Join-Path $env:TEMP ("ShulesoftV1-metadata-" + [Guid]::NewGuid().ToString("N") + ".zip")
    $lastError = $null

    try {
        for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
            if (Test-Path $tempZip) {
                Remove-Item $tempZip -Force -ErrorAction SilentlyContinue
            }

            try {
                Save-GitHubReleaseAsset `
                    -AssetId $AssetId `
                    -DestinationPath $tempZip `
                    -Owner $Owner `
                    -Repo $Repo
            }
            catch {
                $lastError = $_
                if ($DownloadUrl) {
                    try {
                        Invoke-WebRequest -Uri (Add-CacheBusterQuery -Url $DownloadUrl) -OutFile $tempZip -UseBasicParsing -ErrorAction Stop
                    }
                    catch {
                        $lastError = $_
                        if ($attempt -lt $MaxAttempts) {
                            Write-Host "GitHub asset download not ready (attempt $attempt/$MaxAttempts), retrying in ${RetryDelaySeconds}s..." -ForegroundColor Yellow
                            Start-Sleep -Seconds $RetryDelaySeconds
                        }
                        continue
                    }
                }
                elseif ($attempt -lt $MaxAttempts) {
                    Write-Host "GitHub asset download not ready (attempt $attempt/$MaxAttempts), retrying in ${RetryDelaySeconds}s..." -ForegroundColor Yellow
                    Start-Sleep -Seconds $RetryDelaySeconds
                    continue
                }
                else {
                    throw
                }
            }

            if (-not (Test-Path $tempZip)) {
                if ($attempt -lt $MaxAttempts) {
                    Start-Sleep -Seconds $RetryDelaySeconds
                    continue
                }
                throw "Downloaded GitHub release asset is missing: $tempZip"
            }

            return Get-ZipPackageMetadata -ZipPath $tempZip
        }

        throw "Could not download GitHub release asset after $MaxAttempts attempt(s). Last error: $($lastError.Exception.Message)"
    }
    finally {
        Remove-Item $tempZip -Force -ErrorAction SilentlyContinue
    }
}

function Confirm-GitHubReleasePackage {
    param(
        [long] $AssetId,
        [string] $DownloadUrl,
        [string] $ExpectedSha256,
        [long] $ExpectedSizeBytes,
        [string] $Owner,
        [string] $Repo,
        [int] $MaxAttempts = 12,
        [int] $RetryDelaySeconds = 10
    )

    $expectedSha = $ExpectedSha256.ToLowerInvariant()
    $lastActual = $null

    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        $actual = Get-GitHubReleaseAssetMetadata `
            -AssetId $AssetId `
            -DownloadUrl $DownloadUrl `
            -Owner $Owner `
            -Repo $Repo `
            -MaxAttempts 1 `
            -RetryDelaySeconds 0

        $lastActual = $actual

        if ($actual.Sha256 -eq $expectedSha -and $actual.SizeBytes -eq $ExpectedSizeBytes) {
            Write-Host "Verified GitHub release matches local package metadata." -ForegroundColor Green
            Write-Host "SHA256:    $($actual.Sha256)" -ForegroundColor Green
            Write-Host "SizeBytes: $($actual.SizeBytes)" -ForegroundColor Green
            return
        }

        if ($attempt -lt $MaxAttempts) {
            Write-Host "GitHub release metadata not in sync yet (attempt $attempt/$MaxAttempts)." -ForegroundColor Yellow
            Write-Host "  Local SHA256:   $expectedSha" -ForegroundColor Yellow
            Write-Host "  GitHub SHA256:  $($actual.Sha256)" -ForegroundColor Yellow
            Write-Host "  Local size:     $ExpectedSizeBytes" -ForegroundColor Yellow
            Write-Host "  GitHub size:    $($actual.SizeBytes)" -ForegroundColor Yellow
            Write-Host "Retrying in ${RetryDelaySeconds}s (GitHub CDN may still be updating)..." -ForegroundColor Yellow
            Start-Sleep -Seconds $RetryDelaySeconds
        }
    }

    throw @"
GitHub release SHA256 does not match the local zip after $MaxAttempts verification attempt(s).
Local SHA256:   $expectedSha
GitHub SHA256:  $($lastActual.Sha256)
Local size:     $ExpectedSizeBytes
GitHub size:    $($lastActual.SizeBytes)

The script will try to replace the GitHub asset automatically when re-upload is enabled.
"@
}

function Sync-GitHubReleasePackage {
    param(
        [string] $Tag,
        [string] $ZipPath,
        [string] $ReleaseTitle,
        [string] $ReleaseNotes,
        [string] $Owner,
        [string] $Repo,
        [switch] $SkipUpload,
        [switch] $Verify,
        [int] $MaxUploadAttempts = 2
    )

    $zipName = [IO.Path]::GetFileName($ZipPath)
    $localMeta = Get-ZipPackageMetadata -ZipPath $ZipPath
    $asset = Get-GitHubReleaseAsset -Tag $Tag -AssetName $zipName -Owner $Owner -Repo $Repo
    $needsUpload = $false

    if ($asset) {
        try {
            $remoteMeta = Get-GitHubReleaseAssetMetadata `
                -AssetId $asset.AssetId `
                -DownloadUrl $asset.BrowserDownloadUrl `
                -Owner $Owner `
                -Repo $Repo `
                -MaxAttempts 3 `
                -RetryDelaySeconds 5

            if ($remoteMeta.Sha256 -eq $localMeta.Sha256 -and $remoteMeta.SizeBytes -eq $localMeta.SizeBytes) {
                Write-Host "GitHub release already matches local zip." -ForegroundColor Green
                Write-Host "SHA256:    $($localMeta.Sha256)" -ForegroundColor Green
                if ($Verify) {
                    Confirm-GitHubReleasePackage `
                        -AssetId $asset.AssetId `
                        -DownloadUrl $asset.BrowserDownloadUrl `
                        -ExpectedSha256 $localMeta.Sha256 `
                        -ExpectedSizeBytes $localMeta.SizeBytes `
                        -Owner $Owner `
                        -Repo $Repo
                }
                return ConvertTo-GitHubReleaseAssetInfo -Asset $asset
            }

            $needsUpload = $true
            Write-Warning @"
GitHub release asset does not match the freshly built local zip.
Local SHA256:   $($localMeta.Sha256)
GitHub SHA256:  $($remoteMeta.Sha256)
"@
        }
        catch {
            $needsUpload = $true
            Write-Host "Could not read existing GitHub asset metadata; uploading local zip. $($_.Exception.Message)" -ForegroundColor Yellow
        }
    }
    else {
        $needsUpload = $true
        $existingRelease = Get-GitHubReleaseByTag -Tag $Tag -Owner $Owner -Repo $Repo
        if ($existingRelease) {
            Write-Host "GitHub release $Tag exists but has no asset named $zipName." -ForegroundColor Yellow
        }
        else {
            Write-Host "GitHub release $Tag does not exist yet; it will be created during upload." -ForegroundColor Yellow
        }
    }

    if ($SkipUpload -and -not $needsUpload) {
        return ConvertTo-GitHubReleaseAssetInfo -Asset $asset
    }

    if ($SkipUpload -and $needsUpload) {
        Write-Warning "Uploading replacement zip because local package is the source of truth (overrides -SkipReleaseUpload)."
    }

    $uploadResult = $null
    for ($uploadAttempt = 1; $uploadAttempt -le $MaxUploadAttempts; $uploadAttempt++) {
        if ($uploadAttempt -gt 1) {
            Write-Host "Re-uploading local zip to GitHub (attempt $uploadAttempt/$MaxUploadAttempts)..." -ForegroundColor Yellow
        }
        else {
            Write-Step "Uploading $zipName to GitHub Releases"
        }

        $uploadResult = Publish-GitHubReleaseAsset `
            -Tag $Tag `
            -ZipPath $ZipPath `
            -ReleaseTitle $ReleaseTitle `
            -ReleaseNotes $ReleaseNotes

        if (-not $uploadResult) {
            throw "GitHub release upload did not return asset metadata."
        }

        if (-not $Verify) {
            return ConvertTo-GitHubReleaseAssetInfo -Asset $uploadResult
        }

        try {
            Confirm-GitHubReleasePackage `
                -AssetId $uploadResult.AssetId `
                -DownloadUrl $uploadResult.BrowserDownloadUrl `
                -ExpectedSha256 $localMeta.Sha256 `
                -ExpectedSizeBytes $localMeta.SizeBytes `
                -Owner $Owner `
                -Repo $Repo
            return ConvertTo-GitHubReleaseAssetInfo -Asset $uploadResult
        }
        catch {
            if ($uploadAttempt -ge $MaxUploadAttempts) {
                throw
            }

            Write-Warning $_.Exception.Message
        }
    }

    return ConvertTo-GitHubReleaseAssetInfo -Asset $uploadResult
}

function Publish-GitHubReleaseAsset {
    param(
        [string] $Tag,
        [string] $ZipPath,
        [string] $ReleaseTitle,
        [string] $ReleaseNotes
    )

    $zipName = [IO.Path]::GetFileName($ZipPath)
    $release = Get-GitHubReleaseByTag -Tag $Tag -Owner $GitHubOwner -Repo $GitHubRepo

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
        foreach ($existingAsset in @($release.assets)) {
            if ($existingAsset.name -eq $zipName) {
                Write-Step "Removing previous asset $zipName"
                $null = Invoke-GitHubApi -Method Delete -Uri "https://api.github.com/repos/$GitHubOwner/$GitHubRepo/releases/assets/$($existingAsset.id)"
                Wait-GitHubReleaseAssetRemoved `
                    -Tag $Tag `
                    -AssetName $zipName `
                    -Owner $GitHubOwner `
                    -Repo $GitHubRepo
            }
        }
    }

    Write-Step "Uploading $zipName to GitHub release"
    $uploadUrl = "https://uploads.github.com/repos/$GitHubOwner/$GitHubRepo/releases/$($release.id)/assets?name=$zipName"
    $bytes = [IO.File]::ReadAllBytes($ZipPath)
    $uploadResponse = Invoke-GitHubApi -Method Post -Uri $uploadUrl -Body $bytes -ContentType "application/zip"

    if ($uploadResponse -and $uploadResponse.id) {
        return [pscustomobject]@{
            AssetId            = [long]$uploadResponse.id
            BrowserDownloadUrl = [string]$uploadResponse.browser_download_url
            SizeBytes          = [long]$uploadResponse.size
        }
    }

    for ($attempt = 1; $attempt -le 12; $attempt++) {
        $asset = Get-GitHubReleaseAsset -Tag $Tag -AssetName $zipName -Owner $GitHubOwner -Repo $GitHubRepo
        if ($asset) {
            return $asset
        }

        if ($attempt -lt 12) {
            Write-Host "Waiting for GitHub release asset index (attempt $attempt/12)..." -ForegroundColor Yellow
            Start-Sleep -Seconds 5
        }
    }

    throw "Upload reported success but GitHub release $Tag has no asset named $zipName."
}

function Get-GitHubReleaseAsset {
    param(
        [string] $Tag,
        [string] $AssetName,
        [string] $Owner,
        [string] $Repo
    )

    $release = Get-GitHubReleaseByTag -Tag $Tag -Owner $Owner -Repo $Repo
    if (-not $release) {
        return $null
    }

    foreach ($asset in @($release.assets)) {
        if ($asset.name -eq $AssetName) {
            return [pscustomobject]@{
                AssetId            = [long]$asset.id
                BrowserDownloadUrl = [string]$asset.browser_download_url
            }
        }
    }

    return $null
}

function Resolve-GitHubUploadResult {
    param([object] $UploadResult)

    if ($null -eq $UploadResult) {
        return $null
    }

    if ($UploadResult -is [System.Array]) {
        for ($i = $UploadResult.Length - 1; $i -ge 0; $i--) {
            if ($UploadResult[$i].PSObject.Properties.Name -contains "BrowserDownloadUrl") {
                return $UploadResult[$i]
            }
        }
    }

    return $UploadResult
}

$releaseText = Resolve-ReleaseText -Title $Title -Message $Message -ChangeItems $ChangeItems -ItemListFile $ItemListFile
$Title = $releaseText.Title
$Message = $releaseText.Message
$releaseNotes = $releaseText.ReleaseNotes
$Changes = @($releaseText.Changes)

if ($releaseText.ItemCount -gt 0) {
    Write-Step "Release notes ($($releaseText.ItemCount) items)"
    Write-Host "Title:   $Title"
    Write-Host "Message: $Message"
    Write-Host ""
    Write-Host $releaseNotes
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
        /restore `
        /verbosity:minimal

    if ($LASTEXITCODE -ne 0) {
        throw @"
MSBuild failed with exit code $LASTEXITCODE.

Release builds may fail if NuGet packages or DLL HintPaths are missing.
Try one of these:
  -Configuration Debug
  -SkipBuild -Configuration Debug   (reuse existing Visual Studio Debug output)

Close Shulesoft V1 if DLLs are locked, then retry.
Build in Visual Studio first (Debug), then publish with -SkipBuild.
"@
    }
}

Ensure-BuildOutput -BinDir $mainBinDir

Write-Step "Creating staging folder"
Assert-PublishNotBlocked -MainBinDir $mainBinDir
Remove-DirectoryForPublish -Path $stagingDir
New-Item -ItemType Directory -Path $stagingDir | Out-Null
New-Item -ItemType Directory -Path (Join-Path $stagingDir "Updater") | Out-Null

Copy-FileShared -SourcePath (Join-Path $mainBinDir "Shulesoft V1.exe") -DestinationPath (Join-Path $stagingDir "Shulesoft V1.exe")
Copy-FileShared -SourcePath (Join-Path $mainBinDir "Shulesoft V1.exe.config") -DestinationPath (Join-Path $stagingDir "Shulesoft V1.exe.config")

$sourceLib = @(
    (Join-Path $mainBinDir "lib"),
    (Join-Path $mainBinDir "Lib")
) | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $sourceLib) { throw "Build output missing lib folder under: $mainBinDir" }
Copy-DirectoryForPackaging -SourceDirectory $sourceLib -DestinationDirectory (Join-Path $stagingDir "lib")

$sourceConfig = @(
    (Join-Path $mainBinDir "config"),
    (Join-Path $mainBinDir "Config")
) | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $sourceConfig) { throw "Build output missing config folder under: $mainBinDir" }
Copy-DirectoryForPackaging -SourceDirectory $sourceConfig -DestinationDirectory (Join-Path $stagingDir "config")
if (Test-Path (Join-Path $mainBinDir "Images")) {
    Copy-DirectoryForPackaging -SourceDirectory (Join-Path $mainBinDir "Images") -DestinationDirectory (Join-Path $stagingDir "Images")
}

$migrationCandidates = @(
    (Join-Path $PublishRoot "database\migrations\v$Version.sql"),
    (Join-Path $PublishRoot "database\migrations\V$Version.sql"),
    (Join-Path $MainProjectRoot "database\migrations\v$Version.sql"),
    (Join-Path $MainProjectRoot "database\migrations\V$Version.sql")
)
$migrationSrc = $migrationCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1
if ($migrationSrc) {
    $migrationDstDir = Join-Path $stagingDir "database\migrations"
    New-Item -ItemType Directory -Path $migrationDstDir -Force | Out-Null
    Copy-FileShared -SourcePath $migrationSrc -DestinationPath (Join-Path $migrationDstDir (Split-Path $migrationSrc -Leaf))
    Write-Host "Included migration: $migrationSrc" -ForegroundColor Green
}
else {
    Write-Host "No migration file for v$Version (optional)" -ForegroundColor Yellow
}

$updaterExe = Resolve-UpdaterExe -MainBinDir $mainBinDir -UpdaterProjectRoot $updaterProjectRoot -Configuration $Configuration
$updaterSourceDir = Split-Path $updaterExe -Parent
$updaterTargetDir = Join-Path $stagingDir "Updater"
New-Item -ItemType Directory -Path $updaterTargetDir -Force | Out-Null
Copy-FileShared -SourcePath $updaterExe -DestinationPath (Join-Path $updaterTargetDir "ShuleUpdater.exe")
$updaterConfig = [IO.Path]::ChangeExtension($updaterExe, ".exe.config")
if (Test-Path $updaterConfig) {
    Copy-FileShared -SourcePath $updaterConfig -DestinationPath (Join-Path $updaterTargetDir "ShuleUpdater.exe.config")
}
foreach ($dependency in @("MySql.Data.dll", "AdysTech.CredentialManager.dll")) {
    $dependencyPath = Join-Path $updaterSourceDir $dependency
    if (Test-Path $dependencyPath) {
        Copy-FileShared -SourcePath $dependencyPath -DestinationPath (Join-Path $updaterTargetDir $dependency)
        Write-Host "Included updater dependency: $dependency" -ForegroundColor Green
    }
    else {
        Write-Host "Updater dependency missing: $dependencyPath" -ForegroundColor Yellow
    }
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
try {
    New-UpdateZipArchive -SourceDirectory $stagingDir -ZipPath $zipPath
}
catch {
    throw @"
Failed to create update zip: $zipPath

Close Shulesoft V1 if it is running, then retry.
If the error persists, delete the staging folder and run again:
  $stagingDir

Original error: $($_.Exception.Message)
"@
}

$packageMeta = Get-ZipPackageMetadata -ZipPath $zipPath

Write-Host "Local zip SHA256:    $($packageMeta.Sha256)" -ForegroundColor Cyan
Write-Host "Local zip sizeBytes: $($packageMeta.SizeBytes)" -ForegroundColor Cyan

$uploadResult = Sync-GitHubReleasePackage `
    -Tag $tag `
    -ZipPath $zipPath `
    -ReleaseTitle $tag `
    -ReleaseNotes $releaseNotes `
    -Owner $GitHubOwner `
    -Repo $GitHubRepo `
    -SkipUpload:$SkipReleaseUpload `
    -Verify:(-not $SkipReleaseVerify)

if ($uploadResult -and $uploadResult.BrowserDownloadUrl) {
    $downloadUrl = $uploadResult.BrowserDownloadUrl
}

if ($uploadResult -and $uploadResult.BrowserDownloadUrl -and $uploadResult.BrowserDownloadUrl -ne "https://github.com/$GitHubOwner/$GitHubRepo/releases/download/$tag/$zipName") {
    Write-Warning "Uploaded asset URL differs from expected URL.`nExpected: https://github.com/$GitHubOwner/$GitHubRepo/releases/download/$tag/$zipName`nActual:   $($uploadResult.BrowserDownloadUrl)"
}

Write-Step "Updating update-manifest.json (auto SHA256 from local zip)"
Update-ManifestJson `
    -ManifestPath $manifestPath `
    -Version $Version `
    -Title $Title `
    -Message $Message `
    -Changes $Changes `
    -DownloadUrl $downloadUrl `
    -Sha256 $packageMeta.Sha256 `
    -SizeBytes $packageMeta.SizeBytes

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

Write-Step "Done"
Write-Host "Version:      $Version"
Write-Host "Zip:          $zipPath"
Write-Host "SHA256:       $($packageMeta.Sha256)"
Write-Host "SizeBytes:    $($packageMeta.SizeBytes)"
Write-Host "Manifest URL: $manifestUrl"
Write-Host "Download URL: $downloadUrl"
