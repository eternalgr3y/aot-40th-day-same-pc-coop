[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$backupTool = Join-Path $root `
    'tools\runtime\backup_retail_acceptance_saves.ps1'
if (-not (Test-Path -LiteralPath $backupTool -PathType Leaf)) {
    throw 'portable save-backup tool is missing'
}

$tempBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
$tempRoot = Join-Path $tempBase ('AoT save backup {0}' -f
    [Guid]::NewGuid().ToString('N'))
$resolvedTempRoot = [IO.Path]::GetFullPath($tempRoot)
if (-not ($resolvedTempRoot + '\').StartsWith(
        $tempBase, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'temporary backup fixture escaped the system temp directory'
}

function Write-FixtureFile {
    param([string]$Path, [string]$Text)
    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Path))
    [IO.File]::WriteAllText($Path, $Text, [Text.UTF8Encoding]::new($false))
}

function New-RigFixture {
    param([string]$RigDir, [string]$Xuid, [string]$Leaf, [string]$Side)
    $profileRoot = Join-Path $RigDir "content\$Xuid"
    foreach ($container in 'default_checkpoint_0.sav',
                           'default_checkpoint_1.sav', 'game_data.sav') {
        Write-FixtureFile -Path (Join-Path $profileRoot `
            "454108D8\00000001\$container\$Leaf") `
            -Text "$Side-$container"
        Write-FixtureFile -Path (Join-Path $profileRoot `
            "454108D8\Headers\00000001\$container.header") `
            -Text "$Side-$container-header"
    }
    Write-FixtureFile -Path (Join-Path $profileRoot `
        "FFFE07D1\00010000\$Xuid\454108D8.gpd") -Text "$Side-gpd"
}

$daddyXuid = 'E000000011111111'
$cjXuid = 'E000000022222222'
$daddyRig = Join-Path $tempRoot 'rigs\host alpha'
$cjRig = Join-Path $tempRoot 'rigs\guest alpha'
$backupRoot = Join-Path $tempRoot 'backups'

try {
    New-RigFixture -RigDir $daddyRig -Xuid $daddyXuid `
        -Leaf 'Fresh Host alpha player save 000000000000000000000000000000000000000000000000000000000000' -Side Daddy
    New-RigFixture -RigDir $cjRig -Xuid $cjXuid `
        -Leaf 'Fresh Guest beta player save' -Side CJ

    $output = @(& $backupTool -Name portable_fixture `
        -DaddyProfileXuid $daddyXuid -CjProfileXuid $cjXuid `
        -DaddyRigDir $daddyRig -CjRigDir $cjRig -BackupRoot $backupRoot)
    if (($output -join ' ') -notmatch
        '^PASS save_backup .*files=14 verified=1$') {
        throw "portable backup did not pass: $($output -join ' ')"
    }
    $target = Join-Path $backupRoot 'portable_fixture'
    $manifest = Get-Content -Raw -LiteralPath `
        (Join-Path $target 'manifest.json') | ConvertFrom-Json
    if ($manifest.Count -ne 14) {
        throw "portable backup manifest count is $($manifest.Count), expected 14"
    }
    foreach ($entry in $manifest) {
        $copyPath = Join-Path $target ([string]$entry.Relative)
        if (-not (Test-Path -LiteralPath $copyPath -PathType Leaf) -or
            (Get-FileHash -Algorithm SHA256 -LiteralPath $copyPath).Hash -cne
                [string]$entry.SHA256) {
            throw "portable backup copy failed verification: $($entry.Relative)"
        }
    }

    Write-FixtureFile -Path (Join-Path $daddyRig `
        "content\$daddyXuid\454108D8\00000001\game_data.sav\SecondLeaf") `
        -Text duplicate
    $duplicateMessage = ''
    try {
        & $backupTool -Name duplicate_should_fail `
            -DaddyProfileXuid $daddyXuid -CjProfileXuid $cjXuid `
            -DaddyRigDir $daddyRig -CjRigDir $cjRig `
            -BackupRoot $backupRoot | Out-Null
    } catch {
        $duplicateMessage = $_.Exception.Message
    }
    if ($duplicateMessage -notmatch 'exactly one plain save leaf' -or
        (Test-Path -LiteralPath (Join-Path $backupRoot `
            'duplicate_should_fail')) -or
        (Test-Path -LiteralPath (Join-Path $backupRoot `
            'duplicate_should_fail.partial'))) {
        throw "duplicate save leaf did not fail before writing: $duplicateMessage"
    }
} finally {
    if (($resolvedTempRoot + '\').StartsWith(
            $tempBase, [StringComparison]::OrdinalIgnoreCase) -and
        (Test-Path -LiteralPath $resolvedTempRoot)) {
        Remove-Item -LiteralPath $resolvedTempRoot -Recurse -Force
    }
}

Write-Host 'PASS: portable backup accepts arbitrary stable save-leaf names, atomically publishes 14 verified files, and rejects ambiguous containers'
