#Requires -Version 7.0
<#
.SYNOPSIS
    Builds the sellable release zip for the conditional access policy pack.
.DESCRIPTION
    Runs a set of preflight checks, then packages exactly the files an operator needs into
    dist\ca-policy-pack-<version>.zip. Nothing here connects to a tenant, uploads a file,
    creates a git tag, or pushes anything; it only reads the working tree and writes local
    files under -OutputPath.

    The repository root is always the parent folder of this script's own location
    ($PSScriptRoot), never the current working directory, and every git call this script
    makes is run against that fixed root with "git -C <repoRoot>"; the script behaves the
    same no matter which folder it is invoked from.

    Preflight, in order, every check must pass before anything is written:

    1. The working tree is clean (git status --porcelain reports nothing).
    2. The current branch is main or a release/* branch. Pass -SkipBranchCheck to build
       deliberately from another branch; every other check still runs.
    3. -Version matches the newest "## [x.y.z]" heading in CHANGELOG.md.
    4. -Version is greater than every existing "v*" git tag.
    5. Invoke-Pester passes every test under tests\, run in a fresh pwsh -NoProfile process so
       the result reflects a clean environment rather than whatever is already loaded here.
    6. Invoke-ScriptAnalyzer reports zero findings (Warning and Error) across the repository.
    7. None of the shipped text files (README.md, DEPLOYMENT-ORDER.md, CHANGELOG.md,
       LICENSE.md, templates\*.json, manifest.json) contain the word "DRAFT" or the word
       the DRAFT marker; this check runs even under -DryRun, so a dry run reports the same failure a
       real build would.

    Once every check passes, the file list is built from a fixed allow list (see "Contents"
    below), never from "everything except some exclusions", so a file added anywhere else in
    the repository never ships by accident. A VERSION.txt (version, UTC build timestamp, short
    git commit hash) and a SHA256SUMS.txt (one SHA-256 hash per file in the zip, VERSION.txt
    included) are generated and added alongside the repository files. The finished zip is
    hashed and that hash is written to a sidecar file next to it.

    Contents of the zip: the repository's root .ps1 scripts, src\*.ps1, templates\*.json,
    manifest.json, the schema file under schema\, README.md, DEPLOYMENT-ORDER.md,
    CHANGELOG.md, LICENSE.md when present, plus the generated VERSION.txt and SHA256SUMS.txt.
    Never included: tests\, .github\, tools\, dist\, any CaBaseline-* folder, and any file or
    folder starting with .git (.gitignore, .gitattributes, .githooks, .git itself).
.PARAMETER Version
    The release version, for example 1.0.0. Mandatory, semantic major.minor.patch only (no
    pre-release or build metadata suffix).
.PARAMETER OutputPath
    Folder to write the zip and its .sha256 sidecar into. Defaults to dist under the
    repository root. This script never commits anything under this folder; dist\ is
    git-ignored.
.PARAMETER DryRun
    Runs every preflight check and reports what would be built (version, planned zip path,
    planned file count, suggested tag) without writing a zip, VERSION.txt, SHA256SUMS.txt, or
    a .sha256 sidecar.
.PARAMETER SkipBranchCheck
    Skips only the branch preflight check (main or release/*); every other check still runs.
    Use this to build the zip from a short-lived feature branch deliberately, for example
    while the release automation itself is still under review on its own branch, instead of
    from main or a release/* branch.
.OUTPUTS
    PSCustomObject with Version, RepoRoot, ZipPath, Sha256, Sha256Path, FileCount,
    SuggestedTag, and Created. Sha256 and Sha256Path are $null and Created is $false when
    -DryRun is supplied; ZipPath and FileCount are still the path and count that would have
    been used.
.NOTES
    Author: Sec Oak
    Date: 2026-10-01
    No network access and no Microsoft Graph permissions are required. Never uploads, never
    creates a git tag, never pushes. Prints the suggested "v<version>" tag for a person to
    create and push themselves once they are satisfied with the zip.
.EXAMPLE
    .\tools\New-ReleaseZip.ps1 -Version 1.0.0

    Builds dist\ca-policy-pack-1.0.0.zip from the current clean checkout of main (or a
    release/* branch), after every preflight check passes.
.EXAMPLE
    .\tools\New-ReleaseZip.ps1 -Version 1.0.0 -DryRun

    Runs every preflight check and reports the planned zip path and file count without
    writing anything.
.EXAMPLE
    .\tools\New-ReleaseZip.ps1 -Version 1.0.0 -SkipBranchCheck

    Builds the zip from the current branch regardless of its name, for example while this
    release script itself is still on its own feature branch. Every other preflight check
    still runs.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^\d+\.\d+\.\d+$')]
    [string]$Version,

    [Parameter()]
    [string]$OutputPath,

    [Parameter()]
    [switch]$DryRun,

    [Parameter()]
    [switch]$SkipBranchCheck
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-CaPackReleaseFileList {
    <#
    .SYNOPSIS
        Builds the list of repository files that belong in the release zip.
    .DESCRIPTION
        An allow list, not everything in the repository minus some exclusions: the root
        .ps1 scripts, src\*.ps1, templates\*.json, manifest.json, the schema file, README.md,
        DEPLOYMENT-ORDER.md, CHANGELOG.md, and LICENSE.md when present. Throws if any required
        file or folder is missing. As a last safety net, also throws if any resolved path
        matches tests\, tools\, .github\, dist\, a CaBaseline-* folder, or a .git* file or
        folder, so a future change to this function can never ship one of those by accident.
    .PARAMETER RepoRoot
        Absolute path to the repository root.
    .OUTPUTS
        System.Object[]. One object per file, each with RelativePath (relative to RepoRoot,
        using \ on Windows) and FullPath.
    .NOTES
        Internal helper, new for this product.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)]
        [string]$RepoRoot
    )

    $files = [System.Collections.Generic.List[object]]::new()

    $rootScripts = @(Get-ChildItem -Path $RepoRoot -File -Filter '*.ps1')
    if ($rootScripts.Count -eq 0) {
        throw "No root .ps1 scripts found under '$RepoRoot'."
    }
    foreach ($item in $rootScripts) {
        $files.Add([pscustomobject]@{ RelativePath = $item.Name; FullPath = $item.FullName })
    }

    $srcPath = Join-Path $RepoRoot 'src'
    $srcScripts = @(Get-ChildItem -Path $srcPath -File -Filter '*.ps1' -ErrorAction SilentlyContinue)
    if ($srcScripts.Count -eq 0) {
        throw "No helper scripts found under '$srcPath'."
    }
    foreach ($item in $srcScripts) {
        $files.Add([pscustomobject]@{ RelativePath = (Join-Path 'src' $item.Name); FullPath = $item.FullName })
    }

    $templatesPath = Join-Path $RepoRoot 'templates'
    $templateFiles = @(Get-ChildItem -Path $templatesPath -File -Filter '*.json' -ErrorAction SilentlyContinue)
    if ($templateFiles.Count -eq 0) {
        throw "No template files found under '$templatesPath'."
    }
    foreach ($item in $templateFiles) {
        $files.Add([pscustomobject]@{ RelativePath = (Join-Path 'templates' $item.Name); FullPath = $item.FullName })
    }

    $manifestPath = Join-Path $RepoRoot 'manifest.json'
    if (-not (Test-Path -Path $manifestPath -PathType Leaf)) {
        throw "manifest.json not found at '$manifestPath'."
    }
    $files.Add([pscustomobject]@{ RelativePath = 'manifest.json'; FullPath = $manifestPath })

    $schemaPath = Join-Path $RepoRoot 'schema'
    $schemaFiles = @(Get-ChildItem -Path $schemaPath -File -Filter '*.json' -ErrorAction SilentlyContinue)
    if ($schemaFiles.Count -eq 0) {
        throw "No schema file found under '$schemaPath'."
    }
    foreach ($item in $schemaFiles) {
        $files.Add([pscustomobject]@{ RelativePath = (Join-Path 'schema' $item.Name); FullPath = $item.FullName })
    }

    foreach ($requiredDocument in 'README.md', 'DEPLOYMENT-ORDER.md', 'CHANGELOG.md') {
        $documentPath = Join-Path $RepoRoot $requiredDocument
        if (-not (Test-Path -Path $documentPath -PathType Leaf)) {
            throw "$requiredDocument not found at '$documentPath'."
        }
        $files.Add([pscustomobject]@{ RelativePath = $requiredDocument; FullPath = $documentPath })
    }

    foreach ($licenseName in 'LICENSE.md', 'LICENSE', 'LICENSE.txt') {
        $licensePath = Join-Path $RepoRoot $licenseName
        if (Test-Path -Path $licensePath -PathType Leaf) {
            $files.Add([pscustomobject]@{ RelativePath = $licenseName; FullPath = $licensePath })
            break
        }
    }

    $forbiddenPattern = '(^|[\\/])(tests|tools|\.github|dist)([\\/]|$)|(^|[\\/])CaBaseline-|(^|[\\/])\.git'
    foreach ($file in $files) {
        if ($file.RelativePath -match $forbiddenPattern) {
            throw "Internal error building the release file list: '$($file.RelativePath)' matches an excluded path and must never ship in the release zip."
        }
    }

    , $files.ToArray()
}

function New-CaPackReleaseVersionFileContent {
    <#
    .SYNOPSIS
        Builds the plain text content of VERSION.txt.
    .PARAMETER Version
        The release version, for example 1.0.0.
    .PARAMETER BuildTimestampUtc
        The UTC build timestamp, already formatted as text.
    .PARAMETER CommitHash
        The short git commit hash the zip was built from.
    .OUTPUTS
        System.String
    .NOTES
        Internal helper, new for this product.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string]$Version,

        [Parameter(Mandatory)]
        [string]$BuildTimestampUtc,

        [Parameter(Mandatory)]
        [string]$CommitHash
    )
    "Version: $Version`nBuild: $BuildTimestampUtc`nCommit: $CommitHash`n"
}

# ---- Preflight: locate the repository and the output folder ----
# The repository root is always this script's own parent folder, never the current working
# directory, so every git call below is pinned to it with "-C $repoRoot" and cannot be
# redirected by the caller's current folder.

$repoRoot = [System.IO.Path]::GetFullPath((Split-Path -Path $PSScriptRoot -Parent))
$repoCheck = (git -C $repoRoot rev-parse --is-inside-work-tree 2>$null | Select-Object -First 1)
if ($repoCheck -ne 'true') {
    throw "This script's own folder ('$repoRoot') is not a git repository working tree."
}

if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $OutputPath = Join-Path $repoRoot 'dist'
}
$OutputPath = [System.IO.Path]::GetFullPath($OutputPath)

# ---- Preflight: clean tree ----

$statusOutput = git -C $repoRoot status --porcelain 2>$null
$dirtyLines = @($statusOutput | Where-Object { $_ })
if ($dirtyLines.Count -gt 0) {
    throw 'The working tree has uncommitted changes; commit or stash them before building a release zip.'
}

# ---- Preflight: branch ----

if (-not $SkipBranchCheck) {
    $branchName = (git -C $repoRoot rev-parse --abbrev-ref HEAD 2>$null | Select-Object -First 1)
    if ([string]::IsNullOrWhiteSpace($branchName) -or -not ($branchName -eq 'main' -or $branchName -match '^release/')) {
        throw "This script must run on 'main' or a 'release/*' branch (current branch '$branchName'); pass -SkipBranchCheck to build deliberately from another branch."
    }
}

# ---- Preflight: version matches the newest CHANGELOG.md heading ----

$changelogPath = Join-Path $repoRoot 'CHANGELOG.md'
if (-not (Test-Path -Path $changelogPath -PathType Leaf)) {
    throw "CHANGELOG.md not found at '$changelogPath'."
}
$changelogText = Get-Content -Path $changelogPath -Raw
$headingMatch = [regex]::Match($changelogText, '(?m)^##\s*\[(\d+\.\d+\.\d+)\]')
if (-not $headingMatch.Success) {
    throw "CHANGELOG.md has no '## [x.y.z]' heading; add one for this release before building the zip."
}
$newestChangelogVersion = $headingMatch.Groups[1].Value
if ($newestChangelogVersion -ne $Version) {
    throw "Version '$Version' does not match the newest CHANGELOG.md heading '## [$newestChangelogVersion]'."
}

# ---- Preflight: version exceeds every existing tag ----

$existingTags = @(git -C $repoRoot tag --list 'v*' 2>$null | Where-Object { $_ })
$versionObject = [version]$Version
foreach ($tag in $existingTags) {
    if ($tag -match '^v(\d+\.\d+\.\d+)$') {
        $tagVersionObject = [version]$Matches[1]
        if ($versionObject -le $tagVersionObject) {
            throw "Version '$Version' does not exceed existing tag '$tag'."
        }
    }
}

# ---- Preflight: Pester passes in a fresh pwsh -NoProfile process ----

$testsPath = Join-Path $repoRoot 'tests'
$pesterCommand = "Set-StrictMode -Version Latest; Import-Module Pester -MinimumVersion 5.5 -MaximumVersion 5.99.99 -Force -ErrorAction Stop; " +
"`$result = Invoke-Pester -Path '$testsPath' -Output None -PassThru; if (`$result.FailedCount -gt 0) { exit 1 } else { exit 0 }"
& pwsh -NoLogo -NoProfile -NonInteractive -Command $pesterCommand | Out-Null
if ($LASTEXITCODE -ne 0) {
    throw "Pester did not pass cleanly in a fresh pwsh -NoProfile process (exit code $LASTEXITCODE)."
}

# ---- Preflight: PSScriptAnalyzer reports zero findings ----

$analyzerSettingsPath = Join-Path $repoRoot 'PSScriptAnalyzerSettings.psd1'
$findings = @(Invoke-ScriptAnalyzer -Path $repoRoot -Recurse -Severity Warning, Error -Settings $analyzerSettingsPath)
if ($findings.Count -gt 0) {
    throw "PSScriptAnalyzer reported $($findings.Count) finding(s); run Invoke-ScriptAnalyzer locally before releasing."
}

# ---- Build the file list and the suggested tag, used by both -DryRun and a real build ----

$releaseFiles = Get-CaPackReleaseFileList -RepoRoot $repoRoot

# ---- Preflight: no shipped text file still carries a DRAFT marker ----
# Runs even under -DryRun, so a dry run surfaces the same failure a real build would. Only
# the operator-facing documents, templates, and manifest are scanned; the root .ps1 scripts and
# src\*.ps1 helpers are source code, not operator-facing prose, and are not scanned here.

$scannedDocumentNames = @('README.md', 'DEPLOYMENT-ORDER.md', 'CHANGELOG.md', 'LICENSE.md', 'LICENSE', 'LICENSE.txt', 'manifest.json')
$scannedFiles = @($releaseFiles | Where-Object {
        $scannedDocumentNames -contains $_.RelativePath -or $_.RelativePath -match '^templates[\\/]'
    })
foreach ($markerText in 'DRAFT') {
    foreach ($scannedFile in $scannedFiles) {
        $scannedContent = Get-Content -Path $scannedFile.FullPath -Raw
        if ($scannedContent.Contains($markerText)) {
            throw "'$($scannedFile.RelativePath)' contains the word '$markerText', which must not ship in the release zip."
        }
    }
}

$suggestedTag = "v$Version"
$zipPath = Join-Path $OutputPath "ca-policy-pack-$Version.zip"
$plannedFileCount = $releaseFiles.Count + 2

if ($DryRun) {
    [pscustomobject]@{
        Version      = $Version
        RepoRoot     = $repoRoot
        ZipPath      = $zipPath
        Sha256       = $null
        Sha256Path   = $null
        FileCount    = $plannedFileCount
        SuggestedTag = $suggestedTag
        Created      = $false
    }
    return
}

# ---- Package ----

$commitHash = (git -C $repoRoot rev-parse --short HEAD 2>$null | Select-Object -First 1)
if ([string]::IsNullOrWhiteSpace($commitHash)) {
    $commitHash = 'unknown'
}
$buildTimestampUtc = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
$versionFileContent = New-CaPackReleaseVersionFileContent -Version $Version -BuildTimestampUtc $buildTimestampUtc -CommitHash $commitHash

New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
if (Test-Path -Path $zipPath -PathType Leaf) {
    Remove-Item -Path $zipPath -Force
}

$stagingDir = Join-Path ([System.IO.Path]::GetTempPath()) ('ca-policy-pack-release-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $stagingDir -Force | Out-Null

try {
    $versionFilePath = Join-Path $stagingDir 'VERSION.txt'
    Set-Content -Path $versionFilePath -Value $versionFileContent -NoNewline -Encoding utf8

    $hashableFiles = @($releaseFiles) + @([pscustomobject]@{ RelativePath = 'VERSION.txt'; FullPath = $versionFilePath })
    $hashLines = foreach ($file in ($hashableFiles | Sort-Object -Property RelativePath)) {
        $hash = (Get-FileHash -Path $file.FullPath -Algorithm SHA256).Hash.ToLowerInvariant()
        $entryName = $file.RelativePath.Replace('\', '/')
        "$hash  $entryName"
    }
    $sha256SumsContent = ($hashLines -join "`n") + "`n"
    $sha256SumsPath = Join-Path $stagingDir 'SHA256SUMS.txt'
    Set-Content -Path $sha256SumsPath -Value $sha256SumsContent -NoNewline -Encoding utf8

    $zipArchive = [System.IO.Compression.ZipFile]::Open($zipPath, [System.IO.Compression.ZipArchiveMode]::Create)
    try {
        foreach ($file in $releaseFiles) {
            $entryName = $file.RelativePath.Replace('\', '/')
            [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zipArchive, $file.FullPath, $entryName) | Out-Null
        }
        [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zipArchive, $versionFilePath, 'VERSION.txt') | Out-Null
        [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zipArchive, $sha256SumsPath, 'SHA256SUMS.txt') | Out-Null
    }
    finally {
        $zipArchive.Dispose()
    }
}
finally {
    Remove-Item -Path $stagingDir -Recurse -Force -ErrorAction SilentlyContinue
}

$zipHash = (Get-FileHash -Path $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()
$sha256SidecarPath = "$zipPath.sha256"
Set-Content -Path $sha256SidecarPath -Value "$zipHash  $(Split-Path -Path $zipPath -Leaf)" -NoNewline -Encoding utf8

[pscustomobject]@{
    Version      = $Version
    RepoRoot     = $repoRoot
    ZipPath      = $zipPath
    Sha256       = $zipHash
    Sha256Path   = $sha256SidecarPath
    FileCount    = $releaseFiles.Count + 2
    SuggestedTag = $suggestedTag
    Created      = $true
}
