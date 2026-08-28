[CmdletBinding()]
param(
    [string]$ConfigPath = '',
    [string]$GamePath = '',
    [string]$ReservedCpuMask = '',
    [switch]$VerifyGameHash,
    [switch]$AsJson
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module Microsoft.PowerShell.Utility -ErrorAction Stop

$root = [IO.Path]::GetFullPath($PSScriptRoot).TrimEnd('\')
if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    $ConfigPath = Join-Path $root 'aot-coop.portable.psd1'
}
$profileRoot = Join-Path $root 'profiles\b19'
$manifestPath = Join-Path $profileRoot 'profile.psd1'
$builderPath = Join-Path $root 'tools\runtime\New-AotPortableLaunchPlan.ps1'
$hardwareModulePath = Join-Path $root 'tools\runtime\AotPortableHardware.psm1'
$checks = [Collections.Generic.List[object]]::new()
Import-Module $hardwareModulePath -Force -ErrorAction Stop

function Add-Check {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)]
        [ValidateSet('PASS', 'INFO', 'NEEDS_ACTION', 'BLOCKED')]
        [string]$State,
        [Parameter(Mandatory = $true)][string]$Detail
    )
    $checks.Add([pscustomobject][ordered]@{
        Name = $Name
        State = $State
        Detail = $Detail
    })
}

function Get-CommandPath {
    param([string[]]$Names)
    foreach ($name in $Names) {
        $command = Get-Command $name -CommandType Application `
            -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($null -ne $command) { return $command.Source }
    }
    return ''
}

$isDesktopPowerShell = $PSVersionTable.PSEdition -eq 'Desktop' -and
    $PSVersionTable.PSVersion.Major -eq 5
$is64Bit = [Environment]::Is64BitOperatingSystem -and
    [Environment]::Is64BitProcess
if ($isDesktopPowerShell -and $is64Bit) {
    Add-Check 'WindowsPowerShell' 'PASS' `
        "64-bit Windows PowerShell $($PSVersionTable.PSVersion)"
} else {
    Add-Check 'WindowsPowerShell' 'BLOCKED' `
        'Run setup with 64-bit Windows PowerShell 5.1.'
}

$cpuTopology = $null
$cpuPlan = $null
$effectiveReservedCpuMask = '0'
if ($PSBoundParameters.ContainsKey('ReservedCpuMask')) {
    $effectiveReservedCpuMask = $ReservedCpuMask
} elseif (Test-Path -LiteralPath $ConfigPath -PathType Leaf) {
    try {
        $previewConfig = Import-PowerShellDataFile -LiteralPath $ConfigPath
        if ([int]$previewConfig.SchemaVersion -eq 2 -and
            $previewConfig.ContainsKey('ReservedCpuMask')) {
            $effectiveReservedCpuMask = [string]$previewConfig.ReservedCpuMask
        }
    } catch {
        # PortableConfig reports malformed config data below. CPU inspection can
        # still proceed independently with the full-machine default.
    }
}
try {
    $cpuTopology = Get-AotCpuTopology
    $cpuPlan = Get-AotCpuAllocationPlan -Topology $cpuTopology `
        -ReservedCpuMask $effectiveReservedCpuMask
    Add-Check 'ProcessorGroup' 'PASS' `
        ("group=0 logical={0} active=0x{1} topology={2}" -f
            $cpuTopology.LogicalProcessorCount, $cpuTopology.ActiveMask,
            $cpuTopology.Signature)
    Add-Check 'CpuAllocation' 'PASS' `
        (("policy={0} daddy=0x{1} cj=0x{2} xws=0x{3} fesl=0x{4} " +
          "reserved=0x{5}") -f $cpuPlan.Policy, $cpuPlan.DaddyCpuMask,
            $cpuPlan.CjCpuMask, $cpuPlan.XwsCpuMask, $cpuPlan.FeslCpuMask,
            $cpuPlan.ReservedCpuMask)
    if (-not [string]::IsNullOrWhiteSpace($cpuPlan.Warning)) {
        Add-Check 'CpuCoexistence' 'NEEDS_ACTION' $cpuPlan.Warning
    }
} catch {
    Add-Check 'ProcessorGroup' 'BLOCKED' $_.Exception.Message
}

$controllerRoutes = @()
$controllerQueryError = ''
try {
    $controllerRoutes = @(Get-AotControllerRoutes)
    if ($controllerRoutes.Count -ge 2) {
        Add-Check 'Controllers' 'INFO' `
            ("Detected VID/PID routes: {0}. Setup must assign two different routes." -f
                ($controllerRoutes -join ', '))
    } else {
        Add-Check 'Controllers' 'NEEDS_ACTION' `
            'Connect two controllers with different VID/PID routes before configuration.'
    }
} catch {
    $controllerQueryError = $_.Exception.Message
    Add-Check 'Controllers' 'BLOCKED' `
        "Controller presence could not be queried: $controllerQueryError"
}

$nodePath = Get-CommandPath @('node.exe', 'node')
$pythonPath = Get-CommandPath @('python.exe', 'python')
$mongoService = Get-Service -Name 'MongoDB' -ErrorAction SilentlyContinue
Add-Check 'Node' $(if ($nodePath) { 'PASS' } else { 'NEEDS_ACTION' }) `
    $(if ($nodePath) { $nodePath } else { 'Node.js was not found on PATH.' })
Add-Check 'Python' $(if ($pythonPath) { 'PASS' } else { 'NEEDS_ACTION' }) `
    $(if ($pythonPath) { $pythonPath } else { 'Python was not found on PATH.' })
Add-Check 'MongoDB' $(if ($null -ne $mongoService) { 'INFO' } else { 'NEEDS_ACTION' }) `
    $(if ($null -ne $mongoService) {
        "Installed service state: $($mongoService.Status). A player kit still needs a managed loopback-only policy."
    } else { 'MongoDB Windows service was not found.' })

$profile = $null
$staticProfileReady = $true
try {
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf) -or
        -not (Test-Path -LiteralPath $builderPath -PathType Leaf)) {
        throw 'B19 manifest or launch-plan builder is missing.'
    }
    $profile = Import-PowerShellDataFile -LiteralPath $manifestPath
    if ($profile.SchemaVersion -ne 2 -or $profile.Name -cne 'B19') {
        throw 'B19 manifest schema/name mismatch.'
    }
    foreach ($sideName in 'Daddy', 'Cj') {
        $side = $profile.$sideName
        $templatePath = Join-Path $profileRoot ([string]$side.Template)
        if (-not (Test-Path -LiteralPath $templatePath -PathType Leaf) -or
            (Get-FileHash -Algorithm SHA256 -LiteralPath $templatePath).Hash -cne
                [string]$side.TemplateSha256) {
            throw "$sideName immutable launch template is missing or changed."
        }
    }
    foreach ($patchEntry in @($profile.FrozenProfileCoopPatches)) {
        $patchPath = Join-Path (Join-Path $profileRoot 'patches') `
            ([string]$patchEntry.FileName)
        if (-not (Test-Path -LiteralPath $patchPath -PathType Leaf) -or
            (Get-FileHash -Algorithm SHA256 -LiteralPath $patchPath).Hash -cne
                [string]$patchEntry.Sha256) {
            throw "Frozen-profile co-op patch is missing or changed: $($patchEntry.FileName)"
        }
    }
    Add-Check 'B19StaticProfile' 'PASS' `
        'Pinned launch templates and three frozen-profile co-op patch assets are intact.'
} catch {
    $staticProfileReady = $false
    Add-Check 'B19StaticProfile' 'BLOCKED' $_.Exception.Message
}

$configReady = $false
$daddyPlan = $null
$cjPlan = $null
if (Test-Path -LiteralPath $ConfigPath -PathType Leaf) {
    try {
        $daddyPlan = & $builderPath -Side Daddy -ConfigPath $ConfigPath `
            -ProfileRoot $profileRoot -SkipFileChecks
        $cjPlan = & $builderPath -Side Cj -ConfigPath $ConfigPath `
            -ProfileRoot $profileRoot -SkipFileChecks
        if ($null -eq $cpuPlan) {
            throw 'Current CPU topology could not be validated.'
        }
        $cpuPairs = [ordered]@{
            DaddyCpuMask = [string]$daddyPlan.Affinity
            CjCpuMask = [string]$cjPlan.Affinity
            XwsCpuMask = [string]$daddyPlan.XwsCpuMask
            FeslCpuMask = [string]$daddyPlan.FeslCpuMask
            ReservedCpuMask = [string]$daddyPlan.ReservedCpuMask
            TopologySignature = [string]$daddyPlan.CpuTopologySignature
            Policy = [string]$daddyPlan.CpuAllocationPolicy
        }
        foreach ($property in $cpuPairs.Keys) {
            if ([string]$cpuPairs[$property] -cne [string]$cpuPlan.$property) {
                throw "Portable CPU contract differs from this machine: $property=$($cpuPairs[$property]) expected=$($cpuPlan.$property)"
            }
        }
        $configReady = $true
        Add-Check 'PortableConfig' 'PASS' `
            ("Schema validates; Daddy/CJ plan hashes {0}/{1}." -f
                $daddyPlan.CommandLineSha256.Substring(0, 12),
                $cjPlan.CommandLineSha256.Substring(0, 12))
        if ([string]::IsNullOrWhiteSpace($GamePath)) {
            $GamePath = [string]$daddyPlan.GamePath
        }
    } catch {
        Add-Check 'PortableConfig' 'BLOCKED' $_.Exception.Message
    }
} else {
    Add-Check 'PortableConfig' 'NEEDS_ACTION' `
        "No local portable config exists. Start from aot-coop.portable.example.psd1; do not copy identities from this PC."
}

if ($configReady) {
    if (-not [string]::IsNullOrWhiteSpace($controllerQueryError)) {
        Add-Check 'ConfiguredControllers' 'BLOCKED' `
            "Configured routes could not be checked: $controllerQueryError"
    } else {
        $configuredRoutes = @(
            @{
                Side = 'Daddy'
                Route = [string]$daddyPlan.Controller
            },
            @{
                Side = 'CJ'
                Route = [string]$cjPlan.Controller
            })
        $missingRoutes = @($configuredRoutes | Where-Object {
            $_.Route -notin $controllerRoutes
        })
        if ($missingRoutes.Count -eq 0) {
            Add-Check 'ConfiguredControllers' 'PASS' `
                'Both configured VID/PID routes are present.'
        } else {
            Add-Check 'ConfiguredControllers' 'NEEDS_ACTION' `
                ("Wake or reconnect configured route(s): {0}." -f
                    (($missingRoutes | ForEach-Object {
                        "$($_.Side)=$($_.Route)"
                    }) -join ', '))
        }
    }
}

if (-not [string]::IsNullOrWhiteSpace($GamePath)) {
    try {
        $resolvedGamePath = [IO.Path]::GetFullPath($GamePath)
        if (-not (Test-Path -LiteralPath $resolvedGamePath -PathType Leaf)) {
            throw 'Selected game image does not exist.'
        }
        $gameInfo = Get-Item -LiteralPath $resolvedGamePath
        if ($null -eq $profile -or
            $gameInfo.Length -ne [int64]$profile.SupportedGame.IsoBytes) {
            throw "Selected game image size is unsupported: $($gameInfo.Length) bytes."
        }
        if ($VerifyGameHash) {
            $hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $resolvedGamePath).Hash
            if ($hash -cne [string]$profile.SupportedGame.IsoSha256) {
                throw "Selected game image hash is unsupported: $hash"
            }
            Add-Check 'GameImage' 'PASS' 'Supported base-disc size and SHA-256 match.'
        } else {
            Add-Check 'GameImage' 'INFO' `
                'Supported size matches; SHA-256 was not read. Use -VerifyGameHash once during setup.'
        }
    } catch {
        Add-Check 'GameImage' 'BLOCKED' $_.Exception.Message
    }
} else {
    Add-Check 'GameImage' 'NEEDS_ACTION' `
        'Select a legally obtained base-disc image; the game is never bundled.'
}

$knownBlockers = @(
    'Build the distributable Xenia executable from an exact clean source commit and repeat runtime acceptance.'
    'Generate two fresh rig identities through Xenia; never copy current xconfig/profile files.'
    "Create and live-validate Daddy's nonempty middle-slot CONTINUE save while keeping CJ's right slot 2 verified empty."
    'Implement dynamic monitor placement for hardware unlike the reference PC.'
    'Choose a project license and resolve the optional upstream visual-patch redistribution/ablation decision.'
    'Pass native join, physical-pad gameplay, death/reload, and a longer soak on a different clean Windows PC.'
)
foreach ($blocker in $knownBlockers) {
    Add-Check 'PlayerKitGate' 'BLOCKED' $blocker
}

$result = [pscustomobject][ordered]@{
    SchemaVersion = 1
    Mode = 'STATUS_ONLY'
    Writes = 0
    Launches = 0
    StaticFoundationReady = $staticProfileReady
    PortableConfigValid = $configReady
    PlayerKitReady = $false
    Status = 'FOUNDATION_ONLY_NEEDS_PROFILE_SAVE_AND_FRESH_MACHINE_ACCEPTANCE'
    ControllerRoutes = $controllerRoutes
    CpuPlan = $cpuPlan
    Checks = @($checks)
    NextAction = "Implement fresh rig/profile bootstrap, then create Daddy's middle save, preserve CJ's empty right slot, and run controlled acceptance."
}

if ($AsJson) {
    $result | ConvertTo-Json -Depth 6
} else {
    Write-Host 'AoT same-PC portable setup status'
    foreach ($check in $checks) {
        Write-Host ("[{0}] {1}: {2}" -f $check.State, $check.Name,
            $check.Detail)
    }
    Write-Host ''
    Write-Host ("STATUS {0} writes=0 launches=0" -f $result.Status)
    Write-Output $result
}
