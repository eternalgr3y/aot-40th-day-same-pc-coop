[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$setup = Join-Path $root 'Setup-AOT-Coop.ps1'
$portableConfig = Join-Path $root 'aot-coop.portable.psd1'
$setupState = Join-Path $root 'setup-state.json'
$rigsRoot = Join-Path $root 'rigs'

if (-not (Test-Path -LiteralPath $setup -PathType Leaf)) {
    throw 'Setup-AOT-Coop.ps1 is missing'
}
$source = Get-Content -Raw -LiteralPath $setup
foreach ($forbidden in 'Start-Process', 'New-Item', 'Set-Content',
                       'Copy-Item', 'Move-Item', 'Remove-Item',
                       'Stop-Process', 'taskkill', '_play_hero.ps1') {
    if ($source -match ('(?m)^\s*' + [regex]::Escape($forbidden))) {
        throw "status-only setup contains a mutating operation: $forbidden"
    }
}
foreach ($required in 'STATUS_ONLY', 'Writes = 0', 'Launches = 0',
                       'never copy current xconfig/profile files',
                       "Daddy's nonempty middle-slot CONTINUE save",
                       "CJ's right slot 2 verified empty") {
    if (-not $source.Contains($required)) {
        throw "status-only setup lacks required safety label: $required"
    }
}

function Get-State {
    [pscustomobject]@{
        ConfigExists = Test-Path -LiteralPath $portableConfig -PathType Leaf
        ConfigHash = if (Test-Path -LiteralPath $portableConfig -PathType Leaf) {
            (Get-FileHash -Algorithm SHA256 -LiteralPath $portableConfig).Hash
        } else { '' }
        StateExists = Test-Path -LiteralPath $setupState -PathType Leaf
        StateHash = if (Test-Path -LiteralPath $setupState -PathType Leaf) {
            (Get-FileHash -Algorithm SHA256 -LiteralPath $setupState).Hash
        } else { '' }
        RigsExists = Test-Path -LiteralPath $rigsRoot -PathType Container
        XeniaPids = @(Get-Process -Name xenia_canary_netplay `
            -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Id)
        GitStatus = if (Test-Path -LiteralPath (Join-Path $root '.git')) {
            @(& git -C $root status --porcelain=v1 `
                --untracked-files=all) -join "`n"
        } else { 'NO_GIT_METADATA' }
    }
}

$before = Get-State
$windowsPowerShell = Join-Path $env:SystemRoot `
    'System32\WindowsPowerShell\v1.0\powershell.exe'
$jsonText = @(& $windowsPowerShell -NoProfile -ExecutionPolicy Bypass `
    -File $setup -AsJson 2>&1 | ForEach-Object { "$_" }) -join "`n"
if ($LASTEXITCODE -ne 0) {
    throw "status-only setup failed: $jsonText"
}
$status = $jsonText | ConvertFrom-Json
$after = Get-State

foreach ($property in 'ConfigExists', 'ConfigHash', 'StateExists',
                           'StateHash', 'RigsExists', 'GitStatus') {
    if ($before.$property -cne $after.$property) {
        throw "status-only setup changed $property"
    }
}

# A schema-2 config owns its reservation contract. Setup must derive that mask
# without requiring the user to repeat it as a command-line argument, and must
# compare the configured controller routes (not merely count arbitrary pads).
$modulePath = Join-Path $root 'tools\runtime\AotPortableHardware.psm1'
Import-Module $modulePath -Force
$topology = Get-AotCpuTopology
$firstCore = @($topology.CpuSets | Group-Object CoreIndex |
    Sort-Object { [int]$_.Name } | Select-Object -First 1)[0]
[uint64]$reservedValue = 0
foreach ($member in @($firstCore.Group)) {
    $reservedValue = $reservedValue -bor
        ([uint64]1 -shl [int]$member.LogicalProcessorIndex)
}
$reservedPlan = $null
try {
    $reservedPlan = Get-AotCpuAllocationPlan -Topology $topology `
        -ReservedCpuMask (Format-AotCpuMask $reservedValue)
} catch {
    # The supported minimum topology can have no spare coexistence core. The
    # behavior is covered by the pure allocator test in that case.
}
if ($null -ne $reservedPlan) {
    $tempConfig = Join-Path ([IO.Path]::GetTempPath()) (
        'aot_setup_reserved_{0}.psd1' -f [Guid]::NewGuid().ToString('N'))
    $escapedRoot = $root.Replace("'", "''")
    $configText = @"
@{
    SchemaVersion = 2
    InstallRoot = '$escapedRoot'
    GamePath = 'missing-game.iso'
    XeniaFileName = 'xenia_canary_netplay.exe'
    ApiAddress = 'http://127.0.0.1:36000/'
    XwsRoot = 'services\xws'
    NodeExe = 'tools\node.exe'
    PythonExe = 'tools\python.exe'
    XwsCpuMask = '$($reservedPlan.XwsCpuMask)'
    FeslCpuMask = '$($reservedPlan.FeslCpuMask)'
    FeslSeconds = 86400
    CpuAllocationPolicy = '$($reservedPlan.Policy)'
    CpuTopologySignature = '$($reservedPlan.TopologySignature)'
    ReservedCpuMask = '$($reservedPlan.ReservedCpuMask)'
    SaveSlot = 1
    Daddy = @{
        RigDir = 'rigs\daddy'
        ProfileXuid = 'E000A1A152111111'
        OnlineXuid = '0009000000000001'
        MacAddress = '7C1E52111111'
        HostAddress = '127.17.17.17'
        Controller = '0x1234/0x0001'
        CpuMask = '$($reservedPlan.DaddyCpuMask)'
        InvertRightX = `$false
    }
    Cj = @{
        RigDir = 'rigs\cj'
        ProfileXuid = 'E000B2B252222222'
        OnlineXuid = '0009000000000002'
        MacAddress = '7C1E52222222'
        HostAddress = '127.34.34.34'
        Controller = '0x1234/0x0002'
        CpuMask = '$($reservedPlan.CjCpuMask)'
        InvertRightX = `$false
    }
}
"@
    try {
        [IO.File]::WriteAllText($tempConfig, $configText,
            [Text.UTF8Encoding]::new($false))
        $reservedJson = @(& $windowsPowerShell -NoProfile `
            -ExecutionPolicy Bypass -File $setup -ConfigPath $tempConfig `
            -AsJson 2>&1 | ForEach-Object { "$_" }) -join "`n"
        if ($LASTEXITCODE -ne 0) {
            throw "reserved-config setup failed: $reservedJson"
        }
        $reservedStatus = $reservedJson | ConvertFrom-Json
        $portableCheck = @($reservedStatus.Checks | Where-Object {
            $_.Name -eq 'PortableConfig'
        })
        $routeCheck = @($reservedStatus.Checks | Where-Object {
            $_.Name -eq 'ConfiguredControllers'
        })
        if ($reservedStatus.CpuPlan.ReservedCpuMask -cne
                $reservedPlan.ReservedCpuMask -or
            $portableCheck.State -cne 'PASS' -or
            $routeCheck.State -cne 'NEEDS_ACTION' -or
            $routeCheck.Detail -notmatch 'Daddy=0x1234/0x0001' -or
            $routeCheck.Detail -notmatch 'CJ=0x1234/0x0002') {
            throw 'setup did not derive the config reservation or identify configured-route mismatch'
        }
    } finally {
        Remove-Item -LiteralPath $tempConfig -Force -ErrorAction SilentlyContinue
    }
}
if ((@($before.XeniaPids) -join ',') -cne (@($after.XeniaPids) -join ',')) {
    throw 'status-only setup changed live Xenia process state'
}
if ($status.Mode -cne 'STATUS_ONLY' -or
    [int]$status.Writes -ne 0 -or [int]$status.Launches -ne 0 -or
    -not [bool]$status.StaticFoundationReady -or
    [bool]$status.PlayerKitReady -or
    $status.Status -cne
        'FOUNDATION_ONLY_NEEDS_PROFILE_SAVE_AND_FRESH_MACHINE_ACCEPTANCE') {
    throw 'status-only setup overstated readiness or lost its zero-write contract'
}

Write-Host 'PASS: Setup-AOT-Coop status is zero-write, zero-launch, statically verifies B19, and preserves fresh-profile/save blockers'
