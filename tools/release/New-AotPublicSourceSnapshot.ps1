[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^v[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?$')]
    [string]$Version,

    [string]$RepoRoot = '',
    [string]$OutputRoot = '',
    [string]$Commit = 'HEAD',
    [switch]$SourceOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Resolve-ContainedPath {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$RelativePath
    )

    if ([string]::IsNullOrWhiteSpace($RelativePath) -or
        [IO.Path]::IsPathRooted($RelativePath) -or
        $RelativePath -match '(^|[\\/])\.\.(?:[\\/]|$)') {
        throw "unsafe relative path: $RelativePath"
    }
    $resolvedRoot = [IO.Path]::GetFullPath($Root).TrimEnd('\') + '\'
    $resolved = [IO.Path]::GetFullPath((Join-Path $Root $RelativePath))
    if (-not ($resolved + '\').StartsWith(
            $resolvedRoot, [StringComparison]::OrdinalIgnoreCase)) {
        throw "path escaped root: $RelativePath"
    }
    return $resolved
}

function Get-SourceFileRecords {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string[]]$RelativePaths
    )

    $records = foreach ($relativePath in @($RelativePaths | Sort-Object)) {
        $normalized = $relativePath.Replace('\', '/')
        $path = Resolve-ContainedPath -Root $Root -RelativePath $normalized
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            throw "snapshot file is missing: $normalized"
        }
        $item = Get-Item -LiteralPath $path
        [pscustomobject][ordered]@{
            Path = $normalized
            SHA256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $path).Hash
            Bytes = [int64]$item.Length
        }
    }
    return @($records)
}

function Assert-SourceFileRecords {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][object[]]$Records
    )

    foreach ($record in $Records) {
        $path = Resolve-ContainedPath -Root $Root `
            -RelativePath ([string]$record.Path)
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            throw "verified snapshot file is missing: $($record.Path)"
        }
        $item = Get-Item -LiteralPath $path
        $actual = (Get-FileHash -Algorithm SHA256 -LiteralPath $path).Hash
        if ($actual -cne [string]$record.SHA256 -or
            [int64]$item.Length -ne [int64]$record.Bytes) {
            throw "verified snapshot file changed: $($record.Path)"
        }
    }
}

function Remove-SafeTree {
    param([string]$Path, [string]$AllowedRoot)
    if ([string]::IsNullOrWhiteSpace($Path) -or
        -not (Test-Path -LiteralPath $Path)) {
        return
    }
    $resolvedRoot = [IO.Path]::GetFullPath($AllowedRoot).TrimEnd('\') + '\'
    $resolvedPath = [IO.Path]::GetFullPath($Path)
    if (-not ($resolvedPath + '\').StartsWith(
            $resolvedRoot, [StringComparison]::OrdinalIgnoreCase) -or
        $resolvedPath.TrimEnd('\') -ieq $resolvedRoot.TrimEnd('\')) {
        throw "refusing cleanup outside the expected root: $resolvedPath"
    }
    Remove-Item -LiteralPath $resolvedPath -Recurse -Force
}

if ($SourceOnly) {
    return
}

if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
    $RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
}
$RepoRoot = [IO.Path]::GetFullPath($RepoRoot)
$gitExe = (Get-Command git.exe -ErrorAction Stop | Select-Object -First 1).Source

$topLevel = @(& $gitExe -C $RepoRoot rev-parse --show-toplevel 2>&1 |
    ForEach-Object { "$_" }) -join ''
if ($LASTEXITCODE -ne 0 -or
    [IO.Path]::GetFullPath($topLevel.Trim()) -ine $RepoRoot) {
    throw 'RepoRoot is not the exact Git worktree root.'
}

$status = @(& $gitExe -C $RepoRoot status --porcelain=v1 `
    --untracked-files=normal 2>&1 | ForEach-Object { "$_" })
if ($LASTEXITCODE -ne 0 -or $status.Count -ne 0) {
    throw 'Public snapshots require a completely clean committed worktree.'
}

$resolvedCommit = @(& $gitExe -C $RepoRoot rev-parse "$Commit^{commit}" 2>&1 |
    ForEach-Object { "$_" }) -join ''
$headCommit = @(& $gitExe -C $RepoRoot rev-parse 'HEAD^{commit}' 2>&1 |
    ForEach-Object { "$_" }) -join ''
if ($LASTEXITCODE -ne 0 -or
    $resolvedCommit.Trim() -notmatch '^[0-9a-f]{40,64}$' -or
    $resolvedCommit.Trim() -cne $headCommit.Trim()) {
    throw 'Public snapshots must be built from the clean checked-out HEAD commit.'
}
$resolvedCommit = $resolvedCommit.Trim()

$validator = Join-Path $RepoRoot `
    'tests\test_portable_runtime_source_allowlist.ps1'
$validationOutput = @(& powershell.exe -NoProfile -NonInteractive `
    -ExecutionPolicy Bypass -File $validator -RepoRoot $RepoRoot 2>&1 |
    ForEach-Object { "$_" }) -join "`n"
if ($LASTEXITCODE -ne 0 -or
    $validationOutput -notmatch '(?m)^PASS: portable runtime source candidate') {
    throw "portable source validation failed: $validationOutput"
}

$allowlistRelative = 'release/portable-runtime-source.allowlist.psd1'
$allowlistPath = Join-Path $RepoRoot $allowlistRelative
$allowlist = Import-PowerShellDataFile -LiteralPath $allowlistPath
if ([bool]$allowlist.PlayerKitReady -or [bool]$allowlist.RuntimeTested -or
    [string]$allowlist.ArtifactClass -cne
        'SOURCE_RUNTIME_CANDIDATE_NOT_PLAYER_KIT') {
    throw 'The allowlist overstates the public artifact readiness.'
}
$files = @($allowlist.Files | ForEach-Object {
    ([string]$_).Replace('\', '/')
})
if ($files.Count -eq 0) { throw 'The public source allowlist is empty.' }

if ([string]::IsNullOrWhiteSpace($OutputRoot)) {
    $OutputRoot = Join-Path $RepoRoot '_release'
}
$OutputRoot = [IO.Path]::GetFullPath($OutputRoot)
[void][IO.Directory]::CreateDirectory($OutputRoot)

$artifactName = "aot-40th-day-same-pc-coop-$Version-source"
$targetRoot = Resolve-ContainedPath -Root $OutputRoot `
    -RelativePath $artifactName
$zipPath = Resolve-ContainedPath -Root $OutputRoot `
    -RelativePath ($artifactName + '.zip')
if ((Test-Path -LiteralPath $targetRoot) -or
    (Test-Path -LiteralPath $zipPath)) {
    throw "release output already exists: $artifactName"
}

$partialName = '.partial-' + [Guid]::NewGuid().ToString('N')
$partialRoot = Resolve-ContainedPath -Root $OutputRoot `
    -RelativePath $partialName
$tempBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$tempRoot = Join-Path $tempBase `
    ('aot-source-snapshot-' + [Guid]::NewGuid().ToString('N'))
$archivePath = Join-Path $tempRoot 'source.zip'
$verifyRoot = Join-Path $tempRoot 'verify'
$published = $false

try {
    [void][IO.Directory]::CreateDirectory($tempRoot)
    & $gitExe -C $RepoRoot archive --format=zip `
        "--output=$archivePath" $resolvedCommit -- @files
    if ($LASTEXITCODE -ne 0 -or
        -not (Test-Path -LiteralPath $archivePath -PathType Leaf)) {
        throw 'git archive could not produce the allowlisted source snapshot.'
    }

    Expand-Archive -LiteralPath $archivePath -DestinationPath $partialRoot
    $publicIgnoreTemplate = Join-Path $partialRoot `
        'release\public-source.gitignore'
    if (-not (Test-Path -LiteralPath $publicIgnoreTemplate -PathType Leaf)) {
        throw 'public source ignore template is missing from the archive.'
    }
    Copy-Item -LiteralPath $publicIgnoreTemplate `
        -Destination (Join-Path $partialRoot '.gitignore')
    $payloadSourcePaths = @($files + '.gitignore')
    $sourceRecords = Get-SourceFileRecords -Root $partialRoot `
        -RelativePaths $payloadSourcePaths
    $extracted = @(Get-ChildItem -LiteralPath $partialRoot -Recurse -File |
        ForEach-Object {
            $_.FullName.Substring($partialRoot.Length).TrimStart('\').Replace('\', '/')
        })
    if ($extracted.Count -ne $payloadSourcePaths.Count -or
        @($extracted | Where-Object {
            $_ -notin $payloadSourcePaths
        }).Count -ne 0) {
        throw 'git archive contents differ from the public allowlist.'
    }

    $manifest = [ordered]@{
        SchemaVersion = 1
        ArtifactClass = 'SOURCE_ALPHA_NOT_PLAYER_KIT'
        Version = $Version
        SourceCommit = $resolvedCommit
        GeneratedUtc = [DateTime]::UtcNow.ToString('o')
        PlayerKitReady = $false
        RuntimeTested = $false
        Validation = 'portable-runtime-source-allowlist-pass'
        Files = $sourceRecords
    }
    $manifestPath = Join-Path $partialRoot 'release-manifest.json'
    $manifestJson = $manifest | ConvertTo-Json -Depth 6
    [IO.File]::WriteAllText($manifestPath, $manifestJson + "`n",
        [Text.UTF8Encoding]::new($false))

    $sumInputs = @($payloadSourcePaths + 'release-manifest.json')
    $sumRecords = Get-SourceFileRecords -Root $partialRoot `
        -RelativePaths $sumInputs
    $sumText = @($sumRecords | ForEach-Object {
        '{0}  {1}' -f $_.SHA256, $_.Path
    }) -join "`n"
    [IO.File]::WriteAllText((Join-Path $partialRoot 'SHA256SUMS'),
        $sumText + "`n", [Text.UTF8Encoding]::new($false))

    [IO.Directory]::Move($partialRoot, $targetRoot)
    Compress-Archive -LiteralPath $targetRoot -DestinationPath $zipPath `
        -CompressionLevel Optimal

    Expand-Archive -LiteralPath $zipPath -DestinationPath $verifyRoot
    $verifiedRoot = Join-Path $verifyRoot $artifactName
    Assert-SourceFileRecords -Root $verifiedRoot -Records $sumRecords
    $verifiedSums = Get-Content -Raw -LiteralPath `
        (Join-Path $verifiedRoot 'SHA256SUMS')
    if ($verifiedSums -cne ($sumText + "`n")) {
        throw 'fresh-extraction checksum list differs from the staged source.'
    }
    $published = $true

    [pscustomobject][ordered]@{
        Version = $Version
        SourceCommit = $resolvedCommit
        Directory = $targetRoot
        Zip = $zipPath
        ZipSHA256 = (Get-FileHash -Algorithm SHA256 `
            -LiteralPath $zipPath).Hash
        SourceFiles = $sourceRecords.Count
        PayloadFiles = $sumRecords.Count + 1
        PlayerKitReady = $false
    }
} finally {
    Remove-SafeTree -Path $partialRoot -AllowedRoot $OutputRoot
    Remove-SafeTree -Path $tempRoot -AllowedRoot $tempBase
    if (-not $published) {
        Remove-SafeTree -Path $targetRoot -AllowedRoot $OutputRoot
        if (Test-Path -LiteralPath $zipPath -PathType Leaf) {
            [IO.File]::Delete($zipPath)
        }
    }
}
