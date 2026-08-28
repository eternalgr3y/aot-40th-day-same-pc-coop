[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9_-]{0,80}$')]
    [string]$Name,

    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[0-9A-Fa-f]{16}$')]
    [string]$DaddyProfileXuid,

    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[0-9A-Fa-f]{16}$')]
    [string]$CjProfileXuid,

    [string]$DaddyRigDir = '',
    [string]$CjRigDir = '',
    [string]$BackupRoot = '',

    [ValidatePattern('(?i)^xenia[A-Za-z0-9._-]{0,95}\.exe$')]
    [string]$XeniaFileName = 'xenia_canary_netplay.exe')

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
if ([string]::IsNullOrWhiteSpace($DaddyRigDir)) {
    $DaddyRigDir = Join-Path $root 'my_xbox'
}
if ([string]::IsNullOrWhiteSpace($CjRigDir)) {
    $CjRigDir = Join-Path $root 'cjs_xbox'
}
if ([string]::IsNullOrWhiteSpace($BackupRoot)) {
    $BackupRoot = Join-Path $root '_backups'
}
$DaddyRigDir = [IO.Path]::GetFullPath($DaddyRigDir).TrimEnd('\')
$CjRigDir = [IO.Path]::GetFullPath($CjRigDir).TrimEnd('\')
$backupRoot = [IO.Path]::GetFullPath($BackupRoot).TrimEnd('\')
if ([string]::Equals($DaddyRigDir, $CjRigDir,
        [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Daddy and CJ rig directories must be distinct.'
}
if ($backupRoot -ceq ([IO.Path]::GetPathRoot($backupRoot)).TrimEnd('\')) {
    throw 'BackupRoot may not be a volume root.'
}
$target = [IO.Path]::GetFullPath((Join-Path $backupRoot $Name))
$targetPrefix = $backupRoot.TrimEnd([IO.Path]::DirectorySeparatorChar) +
    [IO.Path]::DirectorySeparatorChar
if (-not $target.StartsWith($targetPrefix, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Backup target escapes the workspace backup directory.'
}
if (Test-Path -LiteralPath $target) {
    throw "Backup target already exists: $target"
}
$partialTarget = $target + '.partial'
if (-not $partialTarget.StartsWith($targetPrefix,
        [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Partial backup target escapes the workspace backup directory.'
}
if (Test-Path -LiteralPath $partialTarget) {
    throw "Incomplete backup staging directory already exists: $partialTarget"
}

$liveXenia = @(Get-CimInstance Win32_Process -ErrorAction Stop |
    Where-Object {
        $_.Name -like 'xenia*.exe' -or $_.Name -ieq $XeniaFileName
    })
if ($liveXenia.Count -ne 0) {
    throw 'Refusing a mutable save backup while any Xenia netplay process is live.'
}

function Get-StableSaveLeaf {
    param(
        [Parameter(Mandatory = $true)][string]$RigDir,
        [Parameter(Mandatory = $true)][string]$ProfileXuid,
        [Parameter(Mandatory = $true)][string]$Side)

    $leaves = [Collections.Generic.List[string]]::new()
    $saveRoot = Join-Path $RigDir `
        "content\$ProfileXuid\454108D8\00000001"
    foreach ($container in 'default_checkpoint_0.sav',
                           'default_checkpoint_1.sav', 'game_data.sav') {
        $containerPath = Join-Path $saveRoot $container
        if (-not (Test-Path -LiteralPath $containerPath -PathType Container)) {
            throw "$Side save container is missing: $containerPath"
        }
        $files = @(Get-ChildItem -LiteralPath $containerPath -File)
        if ($files.Count -ne 1 -or
            ($files.Count -eq 1 -and
             ($files[0].Attributes -band [IO.FileAttributes]::ReparsePoint))) {
            throw "$Side $container must contain exactly one plain save leaf."
        }
        $leaves.Add($files[0].Name)
    }
    $unique = @($leaves | Sort-Object -Unique)
    if ($unique.Count -ne 1) {
        throw "$Side save containers do not use one stable leaf name."
    }
    return $unique[0]
}

$DaddySaveLeaf = Get-StableSaveLeaf -RigDir $DaddyRigDir `
    -ProfileXuid $DaddyProfileXuid -Side Daddy
$CjSaveLeaf = Get-StableSaveLeaf -RigDir $CjRigDir `
    -ProfileXuid $CjProfileXuid -Side CJ
$daddy = Join-Path $DaddyRigDir "content\$DaddyProfileXuid"
$cj = Join-Path $CjRigDir "content\$CjProfileXuid"
$entries = @(
    @{ Source = (Join-Path $cj "454108D8\00000001\default_checkpoint_0.sav\$CjSaveLeaf"); Relative = "CJ\454108D8\00000001\default_checkpoint_0.sav\$CjSaveLeaf" },
    @{ Source = (Join-Path $cj "454108D8\00000001\default_checkpoint_1.sav\$CjSaveLeaf"); Relative = "CJ\454108D8\00000001\default_checkpoint_1.sav\$CjSaveLeaf" },
    @{ Source = (Join-Path $cj "454108D8\00000001\game_data.sav\$CjSaveLeaf"); Relative = "CJ\454108D8\00000001\game_data.sav\$CjSaveLeaf" },
    @{ Source = (Join-Path $cj '454108D8\Headers\00000001\default_checkpoint_0.sav.header'); Relative = 'CJ\454108D8\Headers\00000001\default_checkpoint_0.sav.header' },
    @{ Source = (Join-Path $cj '454108D8\Headers\00000001\default_checkpoint_1.sav.header'); Relative = 'CJ\454108D8\Headers\00000001\default_checkpoint_1.sav.header' },
    @{ Source = (Join-Path $cj '454108D8\Headers\00000001\game_data.sav.header'); Relative = 'CJ\454108D8\Headers\00000001\game_data.sav.header' },
    @{ Source = (Join-Path $cj "FFFE07D1\00010000\$CjProfileXuid\454108D8.gpd"); Relative = 'CJProfile\454108D8.gpd' },
    @{ Source = (Join-Path $daddy "454108D8\00000001\default_checkpoint_0.sav\$DaddySaveLeaf"); Relative = "Daddy\454108D8\00000001\default_checkpoint_0.sav\$DaddySaveLeaf" },
    @{ Source = (Join-Path $daddy "454108D8\00000001\default_checkpoint_1.sav\$DaddySaveLeaf"); Relative = "Daddy\454108D8\00000001\default_checkpoint_1.sav\$DaddySaveLeaf" },
    @{ Source = (Join-Path $daddy "454108D8\00000001\game_data.sav\$DaddySaveLeaf"); Relative = "Daddy\454108D8\00000001\game_data.sav\$DaddySaveLeaf" },
    @{ Source = (Join-Path $daddy '454108D8\Headers\00000001\default_checkpoint_0.sav.header'); Relative = 'Daddy\454108D8\Headers\00000001\default_checkpoint_0.sav.header' },
    @{ Source = (Join-Path $daddy '454108D8\Headers\00000001\default_checkpoint_1.sav.header'); Relative = 'Daddy\454108D8\Headers\00000001\default_checkpoint_1.sav.header' },
    @{ Source = (Join-Path $daddy '454108D8\Headers\00000001\game_data.sav.header'); Relative = 'Daddy\454108D8\Headers\00000001\game_data.sav.header' },
    @{ Source = (Join-Path $daddy "FFFE07D1\00010000\$DaddyProfileXuid\454108D8.gpd"); Relative = 'DaddyProfile\454108D8.gpd' }
)

$manifest = foreach ($entry in $entries) {
    $source = [string]$entry.Source
    if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
        throw "Required save file is missing: $source"
    }
    $info = Get-Item -LiteralPath $source
    [pscustomobject][ordered]@{
        Relative = $entry.Relative
        Source = $source
        Length = $info.Length
        SHA256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $source).Hash
        LastWriteTimeUtc = $info.LastWriteTimeUtc.ToString('o')
    }
}

$partialCreated = $false
try {
    [void][IO.Directory]::CreateDirectory($partialTarget)
    $partialCreated = $true
    foreach ($entry in $manifest) {
        $destination = Join-Path $partialTarget $entry.Relative
        [void][IO.Directory]::CreateDirectory((Split-Path -Parent $destination))
        Copy-Item -LiteralPath $entry.Source -Destination $destination
        $copy = Get-Item -LiteralPath $destination
        $copyHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $destination).Hash
        if ($copy.Length -ne $entry.Length -or $copyHash -cne $entry.SHA256) {
            throw "Backup verification failed: $($entry.Relative)"
        }
    }

    $json = $manifest | ConvertTo-Json -Depth 3
    [IO.File]::WriteAllText((Join-Path $partialTarget 'manifest.json'),
        $json + "`n", [Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $partialTarget -Destination $target
    $partialCreated = $false
} catch {
    if ($partialCreated -and
        $partialTarget.StartsWith($targetPrefix,
            [StringComparison]::OrdinalIgnoreCase) -and
        (Test-Path -LiteralPath $partialTarget -PathType Container)) {
        Remove-Item -LiteralPath $partialTarget -Recurse -Force
    }
    throw
}
Write-Output "PASS save_backup path=$target files=$($manifest.Count) verified=1"
