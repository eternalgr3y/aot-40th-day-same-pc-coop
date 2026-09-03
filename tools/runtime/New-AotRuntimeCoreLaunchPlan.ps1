[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('Daddy', 'Cj')]
    [string]$Side,

    [string]$ConfigPath = '',
    [string]$ProfileRoot = '',
    [switch]$SyntheticFixture,
    [switch]$AsJson
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module Microsoft.PowerShell.Utility -ErrorAction Stop

$workspaceRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$productionProfileRoot = [IO.Path]::GetFullPath((Join-Path $workspaceRoot `
    'profiles\b19-runtime-core-acceptance')).TrimEnd('\')
$profileRootWasExplicit = -not [string]::IsNullOrWhiteSpace($ProfileRoot)
if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    $ConfigPath = Join-Path $workspaceRoot 'aot-coop.runtime-core.acceptance.psd1'
} elseif (-not [IO.Path]::IsPathRooted($ConfigPath)) {
    $ConfigPath = Join-Path $workspaceRoot $ConfigPath
}
if ([string]::IsNullOrWhiteSpace($ProfileRoot)) {
    $ProfileRoot = $productionProfileRoot
} elseif (-not [IO.Path]::IsPathRooted($ProfileRoot)) {
    $ProfileRoot = Join-Path $workspaceRoot $ProfileRoot
}
$ConfigPath = [IO.Path]::GetFullPath($ConfigPath)
$ProfileRoot = [IO.Path]::GetFullPath($ProfileRoot).TrimEnd('\')
$tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
if ($SyntheticFixture) {
    if (-not $profileRootWasExplicit -or
        -not (($ProfileRoot + '\').StartsWith(
            $tempRoot + '\', [StringComparison]::OrdinalIgnoreCase))) {
        throw 'SyntheticFixture requires an explicit ProfileRoot under the system temp directory.'
    }
} elseif (-not [string]::Equals($ProfileRoot, $productionProfileRoot,
        [StringComparison]::OrdinalIgnoreCase)) {
    throw 'ProfileRoot overrides are reserved for synthetic tests; production planning uses the reviewed profile.'
}

function Get-TextSha256 {
    param([Parameter(Mandatory = $true)][string]$Text)
    $algorithm = [Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString($algorithm.ComputeHash(
            [Text.Encoding]::UTF8.GetBytes($Text)))) -replace '-', ''
    } finally {
        $algorithm.Dispose()
    }
}

function Get-FileSha256 {
    param([Parameter(Mandatory = $true)][string]$Path)
    return (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash
}

function Get-NormalizedTextFileSha256 {
    param([Parameter(Mandatory = $true)][string]$Path)
    $text = (Get-Content -Raw -LiteralPath $Path).Replace("`r`n", "`n").Replace("`r", "`n")
    return Get-TextSha256 -Text $text
}

function Assert-ExactKeys {
    param(
        [Parameter(Mandatory = $true)][Collections.IDictionary]$Table,
        [Parameter(Mandatory = $true)][string[]]$Expected,
        [Parameter(Mandatory = $true)][string]$Label
    )
    $actual = @($Table.Keys | ForEach-Object { [string]$_ })
    $unknown = @($actual | Where-Object { $_ -notin $Expected })
    $missing = @($Expected | Where-Object { $_ -notin $actual })
    if ($unknown.Count -ne 0 -or $missing.Count -ne 0) {
        throw (('{0} keys differ from the acceptance schema: missing=[{1}] ' +
            'unknown=[{2}]') -f $Label, ($missing -join ','),
            ($unknown -join ','))
    }
}

function Assert-PlainValue {
    param(
        [Parameter(Mandatory = $true)][string]$Value,
        [Parameter(Mandatory = $true)][string]$Label
    )
    if ([string]::IsNullOrWhiteSpace($Value) -or
        $Value -match '<[^>]+>|[\r\n"]|\{\{') {
        throw "$Label is empty, unconfigured, or contains unsafe text."
    }
}

function Resolve-ConfigPath {
    param(
        [Parameter(Mandatory = $true)][string]$Value,
        [Parameter(Mandatory = $true)][string]$BasePath,
        [Parameter(Mandatory = $true)][string]$Label
    )
    Assert-PlainValue -Value $Value -Label $Label
    $fullPath = if ([IO.Path]::IsPathRooted($Value)) {
        [IO.Path]::GetFullPath($Value)
    } else {
        [IO.Path]::GetFullPath((Join-Path $BasePath $Value))
    }
    if ($fullPath.TrimEnd('\') -ceq
        ([IO.Path]::GetPathRoot($fullPath)).TrimEnd('\')) {
        throw "$Label may not be a volume root."
    }
    return $fullPath.TrimEnd('\')
}

function Normalize-CpuMask {
    param(
        [Parameter(Mandatory = $true)][string]$Value,
        [Parameter(Mandatory = $true)][string]$Label,
        [switch]$AllowZero
    )
    $textValue = $Value.Trim() -replace '^(?i:0x)', ''
    if ($textValue -notmatch '^[0-9A-Fa-f]{1,16}$') {
        throw "$Label must be a hexadecimal processor mask up to 64 bits."
    }
    $number = [Convert]::ToUInt64($textValue, 16)
    if (-not $AllowZero -and $number -eq 0) {
        throw "$Label must be nonzero."
    }
    $width = if ($number -le [uint32]::MaxValue) { 8 } else { 16 }
    return [pscustomobject]@{
        Text = $number.ToString("X$width")
        Value = $number
    }
}

function ConvertTo-WindowsArgument {
    param([Parameter(Mandatory = $true)][string]$Value)
    if ($Value.Contains('"')) {
        throw 'Acceptance-plan arguments may not contain a literal double quote.'
    }
    if ($Value -notmatch '\s') { return $Value }
    return '"' + $Value + '"'
}

function Get-NormalizedConfig {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Acceptance config is missing: $Path"
    }
    $config = Import-PowerShellDataFile -LiteralPath $Path
    if ($null -eq $config -or -not ($config -is [Collections.IDictionary]) -or
        [int]$config.SchemaVersion -ne 2) {
        throw 'The runtime-core acceptance planner requires config SchemaVersion 2.'
    }
    Assert-ExactKeys -Table $config -Label 'Acceptance config' -Expected @(
        'SchemaVersion', 'InstallRoot', 'GamePath', 'XeniaFileName',
        'ApiAddress', 'XwsRoot', 'NodeExe', 'PythonExe', 'FeslSeconds',
        'XwsCpuMask', 'FeslCpuMask', 'CpuAllocationPolicy',
        'CpuTopologySignature', 'ReservedCpuMask', 'SaveSlot', 'Daddy', 'Cj')

    $configDirectory = Split-Path -Parent $Path
    $installRoot = Resolve-ConfigPath -Value ([string]$config.InstallRoot) `
        -BasePath $configDirectory -Label 'InstallRoot'
    $gamePath = Resolve-ConfigPath -Value ([string]$config.GamePath) `
        -BasePath $installRoot -Label 'GamePath'
    $xwsRoot = Resolve-ConfigPath -Value ([string]$config.XwsRoot) `
        -BasePath $installRoot -Label 'XwsRoot'
    $nodeExe = Resolve-ConfigPath -Value ([string]$config.NodeExe) `
        -BasePath $installRoot -Label 'NodeExe'
    $pythonExe = Resolve-ConfigPath -Value ([string]$config.PythonExe) `
        -BasePath $installRoot -Label 'PythonExe'

    $xeniaFileName = [string]$config.XeniaFileName
    Assert-PlainValue -Value $xeniaFileName -Label 'XeniaFileName'
    if ([IO.Path]::GetFileName($xeniaFileName) -cne $xeniaFileName -or
        $xeniaFileName -notmatch '(?i)^xenia[A-Za-z0-9._-]{0,95}\.exe$') {
        throw 'XeniaFileName must be a plain xenia*.exe file name.'
    }
    $apiAddress = [string]$config.ApiAddress
    if ($apiAddress -cne 'http://127.0.0.1:36000/') {
        throw 'Runtime-core acceptance requires ApiAddress=http://127.0.0.1:36000/.'
    }
    if ([int]$config.SaveSlot -ne 1) {
        throw 'Runtime-core acceptance preserves the B19 Daddy SaveSlot=1 gate.'
    }
    if ([int]$config.FeslSeconds -lt 600 -or
        [int]$config.FeslSeconds -gt 86400) {
        throw 'FeslSeconds must be from 600 through 86400.'
    }
    if ([string]$config.CpuAllocationPolicy -cne 'WholeCoreTierSplitV1') {
        throw 'CpuAllocationPolicy must be WholeCoreTierSplitV1.'
    }
    $topologySignature = ([string]$config.CpuTopologySignature).ToUpperInvariant()
    if ($topologySignature -notmatch '^[0-9A-F]{64}$') {
        throw 'CpuTopologySignature must be the 64-hex setup signature.'
    }

    $xwsMask = Normalize-CpuMask -Value ([string]$config.XwsCpuMask) `
        -Label 'XwsCpuMask'
    $feslMask = Normalize-CpuMask -Value ([string]$config.FeslCpuMask) `
        -Label 'FeslCpuMask'
    $reservedMask = Normalize-CpuMask -Value ([string]$config.ReservedCpuMask) `
        -Label 'ReservedCpuMask' -AllowZero

    $normalizedSides = [ordered]@{}
    foreach ($sideName in 'Daddy', 'Cj') {
        $sideValue = $config[$sideName]
        if ($null -eq $sideValue -or
            -not ($sideValue -is [Collections.IDictionary])) {
            throw "$sideName config must be a data-file hashtable."
        }
        Assert-ExactKeys -Table $sideValue -Label "$sideName config" -Expected @(
            'RigDir', 'ProfileXuid', 'OnlineXuid', 'MacAddress',
            'HostAddress', 'Controller', 'CpuMask', 'InvertRightX')
        if (-not ($sideValue.InvertRightX -is [bool])) {
            throw "$sideName.InvertRightX must be a Boolean `$true or `$false."
        }
        $rigDir = Resolve-ConfigPath -Value ([string]$sideValue.RigDir) `
            -BasePath $installRoot -Label "$sideName.RigDir"
        $xuid = ([string]$sideValue.ProfileXuid).ToUpperInvariant()
        $onlineXuid = ([string]$sideValue.OnlineXuid).ToUpperInvariant()
        $macAddress = ([string]$sideValue.MacAddress).ToUpperInvariant()
        $hostAddress = [string]$sideValue.HostAddress
        $controller = ([string]$sideValue.Controller).ToUpperInvariant()
        if ($xuid -notmatch '^E000[0-9A-F]{12}$') {
            throw "$sideName.ProfileXuid must be a persisted E000 plus 12-hex offline XUID."
        }
        if ($onlineXuid -notmatch '^0009[0-9A-F]{12}$') {
            throw "$sideName.OnlineXuid must be a persisted 0009 plus 12-hex XUID."
        }
        if ($macAddress -notmatch '^7C1E52[0-9A-F]{6}$') {
            throw "$sideName.MacAddress must be a fresh Xenia 7C1E52 plus 6-hex MAC."
        }
        if ($xuid.Substring(8, 8) -cne $macAddress.Substring(4, 8)) {
            throw "$sideName offline XUID and Xenia MAC suffixes do not match."
        }
        $lastThree = $macAddress.Substring(6, 6)
        $derivedHostAddress = '127.{0}.{1}.{2}' -f
            [Convert]::ToByte($lastThree.Substring(0, 2), 16),
            [Convert]::ToByte($lastThree.Substring(2, 2), 16),
            [Convert]::ToByte($lastThree.Substring(4, 2), 16)
        if ($hostAddress -cne $derivedHostAddress -or
            $hostAddress -in '127.0.0.0', '127.0.0.1') {
            throw "$sideName.HostAddress must equal its safe MAC-derived address: $derivedHostAddress"
        }
        if ($controller -notmatch '^0X[0-9A-F]{4}/0X[0-9A-F]{4}$') {
            throw "$sideName.Controller must use 0xVVVV/0xPPPP form."
        }
        $controller = $controller.Replace('0X', '0x')
        $cpuMask = Normalize-CpuMask -Value ([string]$sideValue.CpuMask) `
            -Label "$sideName.CpuMask"
        $playerPort = 36001 +
            ([Convert]::ToUInt64($macAddress, 16) -band 0x3FF)
        $normalizedSides[$sideName] = [pscustomobject]@{
            RigDir = $rigDir
            ProfileXuid = $xuid
            OnlineXuid = $onlineXuid
            MacAddress = $macAddress
            HostAddress = $hostAddress
            PlayerPort = $playerPort
            Controller = $controller
            CpuMask = $cpuMask.Text
            CpuMaskValue = $cpuMask.Value
            InvertRightX = [bool]$sideValue.InvertRightX
        }
    }

    $daddy = $normalizedSides.Daddy
    $cj = $normalizedSides.Cj
    if ($daddy.RigDir -ieq $cj.RigDir) {
        throw 'Daddy and CJ must use distinct rig directories.'
    }
    if ($daddy.ProfileXuid -ceq $cj.ProfileXuid -or
        $daddy.OnlineXuid -ceq $cj.OnlineXuid -or
        $daddy.MacAddress -ceq $cj.MacAddress -or
        $daddy.HostAddress -ceq $cj.HostAddress) {
        throw 'Daddy and CJ persisted identities and host addresses must be distinct.'
    }
    if ($daddy.Controller -ceq $cj.Controller) {
        throw 'Runtime-core physical-pad acceptance requires distinct SDL VID/PID routes.'
    }
    if ([int]$daddy.PlayerPort -eq [int]$cj.PlayerPort) {
        throw 'Daddy and CJ MAC addresses collide on the synthetic player port.'
    }
    if (($daddy.CpuMaskValue -band $cj.CpuMaskValue) -ne 0) {
        throw 'Daddy and CJ CPU masks overlap.'
    }
    $rigRoot = [IO.Path]::GetFullPath((Join-Path $installRoot 'rigs')).TrimEnd('\')
    foreach ($sideName in 'Daddy', 'Cj') {
        $parent = [IO.Path]::GetDirectoryName(
            [string]$normalizedSides[$sideName].RigDir).TrimEnd('\')
        if (-not [string]::Equals($parent, $rigRoot,
                [StringComparison]::OrdinalIgnoreCase)) {
            throw "$sideName.RigDir must be a direct child of InstallRoot\rigs."
        }
    }
    $gameMask = $daddy.CpuMaskValue -bor $cj.CpuMaskValue
    if (($gameMask -band $xwsMask.Value) -ne 0 -or
        ($gameMask -band $feslMask.Value) -ne 0) {
        throw 'Backend CPU masks must not overlap either Xenia CPU mask.'
    }
    if (($feslMask.Value -band $xwsMask.Value) -ne $feslMask.Value) {
        throw 'FeslCpuMask must be a subset of XwsCpuMask.'
    }
    if ((($gameMask -bor $xwsMask.Value) -band $reservedMask.Value) -ne 0) {
        throw 'ReservedCpuMask must not overlap either rig or service masks.'
    }

    return [pscustomobject]@{
        InstallRoot = $installRoot
        GamePath = $gamePath
        XeniaFileName = $xeniaFileName
        ApiAddress = $apiAddress
        XwsRoot = $xwsRoot
        NodeExe = $nodeExe
        PythonExe = $pythonExe
        FeslSeconds = [int]$config.FeslSeconds
        XwsCpuMask = $xwsMask.Text
        FeslCpuMask = $feslMask.Text
        CpuAllocationPolicy = [string]$config.CpuAllocationPolicy
        CpuTopologySignature = $topologySignature
        ReservedCpuMask = $reservedMask.Text
        SaveSlot = [int]$config.SaveSlot
        Daddy = $daddy
        Cj = $cj
    }
}

function Assert-CanonicalPatch {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][Collections.IDictionary]$Expected
    )
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Required acceptance patch is missing: $Path"
    }
    if ((Get-FileSha256 -Path $Path) -cne [string]$Expected.Sha256) {
        throw "Acceptance patch hash mismatch: $($Expected.FileName)"
    }
    $patchText = Get-Content -Raw -LiteralPath $Path
    if ([regex]::Matches($patchText,
            '(?m)^\s*is_enabled\s*=\s*true\s*$').Count -ne 1 -or
        $patchText -notmatch '(?m)^\s*title_id\s*=\s*"454108D8"\s*$' -or
        $patchText -notmatch [regex]::Escape('"7C5F016EA6A81E95"') -or
        $patchText -notmatch [regex]::Escape([string]$Expected.PatchName) -or
        $patchText -notmatch [regex]::Escape("[[patch.$($Expected.Type)]]") -or
        $patchText -notmatch ("(?im)^\s*address\s*=\s*{0}\s*$" -f
            [regex]::Escape([string]$Expected.Address)) -or
        $patchText -notmatch ("(?im)^\s*value\s*=\s*{0}\s*$" -f
            [regex]::Escape([string]$Expected.Value))) {
        throw "Acceptance patch semantics mismatch: $($Expected.FileName)"
    }
}

$profilePath = Join-Path $ProfileRoot 'profile.psd1'
if (-not (Test-Path -LiteralPath $profilePath -PathType Leaf)) {
    throw "Runtime-core acceptance profile is missing: $profilePath"
}
$expectedProductionProfileSha256 =
    '87987BECC70800C3D7CA3434E7BE15365A8E3053185E04121AE38525BFA5E891'
$profileSha256 = Get-NormalizedTextFileSha256 -Path $profilePath
if (-not $SyntheticFixture -and
    $profileSha256 -cne $expectedProductionProfileSha256) {
    throw "Reviewed runtime-core profile hash mismatch: $profileSha256"
}
$profile = Import-PowerShellDataFile -LiteralPath $profilePath
if ($null -eq $profile -or
    -not ($profile -is [Collections.IDictionary])) {
    throw 'Runtime-core profile must be a data-file hashtable.'
}
Assert-ExactKeys -Table $profile -Label 'Runtime-core profile' -Expected @(
    'SchemaVersion', 'Name', 'ArtifactClass', 'PlayerKitReady',
    'RuntimeTested', 'LaunchCapable', 'SourceCommit', 'SourceTree',
    'XeniaBytes', 'XeniaSha256', 'TitleId', 'MediaId', 'TitleModuleHash',
    'SupportedGame', 'AllowedAotOptions', 'RequiredPatches',
    'PendingRuntimeGates', 'RequiredSa2AcceptanceMarkers', 'Daddy', 'Cj')
if ([int]$profile.SchemaVersion -ne 1 -or
    [string]$profile.Name -cne 'B19-Runtime-Core-Acceptance' -or
    [string]$profile.ArtifactClass -cne
        'OFFLINE_ACCEPTANCE_PLAN_NOT_PLAYER_KIT' -or
    [bool]$profile.PlayerKitReady -or [bool]$profile.RuntimeTested -or
    [bool]$profile.LaunchCapable) {
    throw 'Runtime-core profile is malformed or overstates acceptance readiness.'
}
if ([string]$profile.SourceCommit -cne
        'b8c0c49520e841a97309e7c742570c0a8769c4f6' -or
    [string]$profile.SourceTree -cne
        '1194169c7723b1bbf314105c5255a7ea2e2e7c97') {
    throw 'Runtime-core profile lost its reviewed source commit/tree pin.'
}
if ([int64]$profile.XeniaBytes -le 0 -or
    [string]$profile.XeniaSha256 -notmatch '^[0-9A-F]{64}$' -or
    [string]$profile.TitleId -cne '454108D8' -or
    [string]$profile.MediaId -cne '44388CF4' -or
    [string]$profile.TitleModuleHash -cne '7C5F016EA6A81E95') {
    throw 'Runtime-core profile has invalid executable or title identity pins.'
}

$allowedAotOptions = @(
    'aot_runtime_peer_ipv4',
    'aot_runtime_sa2',
    'aot_runtime_leg_destination_repair',
    'aot_runtime_xport_control_load_repair')
$manifestAotOptions = @($profile.AllowedAotOptions | ForEach-Object {
    [string]$_
})
if ($manifestAotOptions.Count -ne $allowedAotOptions.Count -or
    @($manifestAotOptions | Where-Object {
        $_ -notin $allowedAotOptions
    }).Count -ne 0 -or
    @($allowedAotOptions | Where-Object {
        $_ -notin $manifestAotOptions
    }).Count -ne 0) {
    throw 'Runtime-core profile AoT option allowlist must contain exactly four reviewed switches.'
}

$expectedPatches = @(
    @{
        FileName = '454108D8 - coop-bind-6000.patch.toml'
        Sha256 = 'BCD3F9A62106424908DA3AD8B543D1A482D4C4561DCCBF26D8EBE99A8CFBE295'
        PatchName = 'Coop - bind real UDP :6000 (same-PC loopback shim)'
        Type = 'be32'; Address = '0x82322AF8'; Value = '0x4800003C'
    },
    @{
        FileName = '454108D8 - coop-cod-unaddressed.patch.toml'
        Sha256 = 'F5CC6083791194E48106E4DE7D6D31C061BAFB43FA90EE935A56698398BC5036'
        PatchName = 'Coop - force unaddressed COd framing (same-PC handshake shim)'
        Type = 'be32'; Address = '0x8239D6C0'; Value = '0x39600000'
    },
    @{
        FileName = '454108D8 - coop-hold-connecting-v2.patch.toml'
        Sha256 = 'F01126934D5CE6E7DBC9D3C51D3F119DA7C50684B83AF838B4C3C8ED22497440'
        PatchName = 'Coop - HOLD at CONNECTING v2 (branch-scoped give-up no-op)'
        Type = 'be32'; Address = '0x82C86A48'; Value = '0x480001C8'
    })
$manifestPatches = @($profile.RequiredPatches)
if ($manifestPatches.Count -ne 3) {
    throw 'Runtime-core profile must declare exactly three canonical guest patches.'
}

$expectedRuntimeGates = @(
    'ZERO_LIVE_XENIA_PROCESSES_BEFORE_STAGING',
    'VERIFIED_SAVE_BACKUP_COMPLETED_BEFORE_ACCEPTANCE_RUN_PREP',
    'ISOLATED_RIG_ROOTS_CREATED_WITHOUT_OVERWRITE',
    'DADDY_SLOT_1_OCCUPIED_AND_CJ_SLOT_2_VERIFIED_EMPTY',
    'LIVE_CPU_TOPOLOGY_MATCHES_DECLARED_SIGNATURE',
    'RIG_XCONFIG_IDENTITIES_MATCH_DECLARED_VALUES',
    'TWO_PHYSICAL_PADS_PRESENT_AND_ISOLATED',
    'XWS_WHOAMI_IS_NONZERO_AND_BACKEND_IS_HEALTHY_BEFORE_JOIN',
    'SA2_BOTH_SIDES_EMIT_EXACTLY_ONE_MANAGER_ARM_MARKER',
    'SA2_ONE_SIDE_PROVES_GENERATION_BOUND_PREPARE_ARM_CONSUME_ACK_CHAIN',
    'EXTERNAL_TIMEOUT_AND_CLEANUP_ARE_ENFORCED',
    'NATIVE_JOIN_REACHES_ONE_SHARED_SESSION',
    'PHYSICAL_PAD_GAMEPLAY_IS_STABLE_FOR_THREE_MINUTES',
    'DEATH_CHECKPOINT_RELOAD_COMPLETES_WITHOUT_BACKEND_DISCONNECT')
$expectedSa2AcceptanceMarkers = @(
    @{
        Stage = 1
        Event = 'PRECONNECT_XSA1_PREPARED_FOR_GUEST'
        Format = '[AOT-RUNTIME-SA2][ACCEPT] seq=<seq> generation=<generation> stage=1 event=PRECONNECT_XSA1_PREPARED_FOR_GUEST'
    },
    @{
        Stage = 2
        Event = 'XNETCONNECT_MANAGER_ARMED'
        Format = '[AOT-RUNTIME-SA2][ACCEPT] seq=<seq> generation=<generation> stage=2 event=XNETCONNECT_MANAGER_ARMED'
    },
    @{
        Stage = 3
        Event = 'POSTCONNECT_XSA1_RETRANSMIT_CONSUMED_ACK_SENT'
        Format = '[AOT-RUNTIME-SA2][ACCEPT] seq=<seq> generation=<generation> stage=3 event=POSTCONNECT_XSA1_RETRANSMIT_CONSUMED_ACK_SENT'
    })
$manifestRuntimeGates = @($profile.PendingRuntimeGates | ForEach-Object {
    [string]$_
})
if ($manifestRuntimeGates.Count -ne $expectedRuntimeGates.Count -or
    @(Compare-Object -ReferenceObject $expectedRuntimeGates `
        -DifferenceObject $manifestRuntimeGates -SyncWindow 0).Count -ne 0) {
    throw 'Runtime-core profile lost its exact pending runtime-gate contract.'
}
$manifestSa2AcceptanceMarkers = @($profile.RequiredSa2AcceptanceMarkers)
if ($manifestSa2AcceptanceMarkers.Count -ne
    $expectedSa2AcceptanceMarkers.Count) {
    throw 'Runtime-core profile must declare exactly three ordered SA2 acceptance markers.'
}
for ($index = 0; $index -lt $expectedSa2AcceptanceMarkers.Count; $index++) {
    $declared = $manifestSa2AcceptanceMarkers[$index]
    $expected = $expectedSa2AcceptanceMarkers[$index]
    if ($null -eq $declared -or
        -not ($declared -is [Collections.IDictionary])) {
        throw "Runtime-core SA2 acceptance marker $index must be a data-file hashtable."
    }
    Assert-ExactKeys -Table $declared -Label "SA2 acceptance marker $index" `
        -Expected @('Stage', 'Event', 'Format')
    foreach ($key in 'Stage', 'Event', 'Format') {
        if ([string]$declared[$key] -cne [string]$expected[$key]) {
            throw "Runtime-core SA2 acceptance marker mismatch at entry $index field $key."
        }
    }
}
for ($index = 0; $index -lt $expectedPatches.Count; $index++) {
    $expected = $expectedPatches[$index]
    $declared = $manifestPatches[$index]
    foreach ($key in 'FileName', 'Sha256', 'PatchName', 'Type', 'Address', 'Value') {
        if (-not $declared.ContainsKey($key) -or
            [string]$declared[$key] -cne [string]$expected[$key]) {
            throw "Runtime-core patch manifest mismatch at entry $index field $key."
        }
    }
}

$profilePatchDirectory = Join-Path $ProfileRoot 'patches'
$profilePatchFiles = @(Get-ChildItem -LiteralPath $profilePatchDirectory `
    -Filter '*.patch.toml' -File -ErrorAction Stop)
if ($profilePatchFiles.Count -ne 3) {
    throw 'Runtime-core profile patch directory must contain exactly three patch TOMLs.'
}
foreach ($patch in $expectedPatches) {
    Assert-CanonicalPatch -Path (Join-Path $profilePatchDirectory `
        ([string]$patch.FileName)) -Expected $patch
}

$config = Get-NormalizedConfig -Path $ConfigPath
$sideConfig = $config.$Side
$peerConfig = if ($Side -ceq 'Daddy') { $config.Cj } else { $config.Daddy }
$sideProfile = $profile.$Side
if ($null -eq $sideProfile -or
    -not ($sideProfile -is [Collections.IDictionary])) {
    throw "Runtime-core profile lacks its $Side template declaration."
}
$templatePath = Join-Path $ProfileRoot ([string]$sideProfile.Template)
if (-not (Test-Path -LiteralPath $templatePath -PathType Leaf)) {
    throw "$Side runtime-core argument template is missing: $templatePath"
}
$templateSha256 = Get-FileSha256 -Path $templatePath
if ($templateSha256 -cne [string]$sideProfile.TemplateSha256) {
    throw "$Side runtime-core argument template hash mismatch: $templateSha256"
}
$template = (Get-Content -Raw -LiteralPath $templatePath).TrimEnd("`r", "`n")
$templateTokens = @([regex]::Matches($template, '(?:"[^"]*"|\S+)') |
    ForEach-Object { $_.Value })

$rightXArg = if ($sideConfig.InvertRightX) {
    '--hid_sdl_invert_right_x=true'
} else { '' }
$replacements = [ordered]@{
    '{{CONTROLLER_ARG}}' = "--hid_sdl_allowed_devices=$($sideConfig.Controller)"
    '{{RIGHT_X_ARG}}' = $rightXArg
    '{{PROFILE_XUID_ARG}}' = "--logged_profile_slot_0_xuid=$($sideConfig.ProfileXuid)"
    '{{API_ARG}}' = "--api_address=$($config.ApiAddress)"
    '{{PEER_IPV4_ARG}}' = "--aot_runtime_peer_ipv4=$($peerConfig.HostAddress)"
    '{{GAME_ARG}}' = ConvertTo-WindowsArgument -Value $config.GamePath
}
foreach ($replacement in $replacements.GetEnumerator()) {
    $count = @($templateTokens | Where-Object {
        $_ -ceq [string]$replacement.Key
    }).Count
    if ($count -ne 1) {
        throw "$Side template requires exactly one $($replacement.Key); found $count."
    }
}
$resolvedTokens = [Collections.Generic.List[string]]::new()
foreach ($templateToken in $templateTokens) {
    if ($replacements.Contains($templateToken)) {
        $replacementValue = [string]$replacements[$templateToken]
        if (-not [string]::IsNullOrEmpty($replacementValue)) {
            $resolvedTokens.Add($replacementValue)
        }
    } else {
        $resolvedTokens.Add($templateToken)
    }
}
$argumentList = $resolvedTokens -join ' '
if ($argumentList -match '\{\{[^}]+\}\}') {
    throw "$Side runtime-core plan retained an unresolved placeholder."
}
$normalizedTokens = @($resolvedTokens | ForEach-Object {
    if ($_.Length -ge 2 -and $_[0] -eq '"' -and
        $_[$_.Length - 1] -eq '"') {
        $_.Substring(1, $_.Length - 2)
    } else { $_ }
})
$optionTokens = @($normalizedTokens | Where-Object { $_ -match '^--[^=]+=' })
$positionalTokens = @($normalizedTokens | Where-Object { $_ -notmatch '^--[^=]+=' })
$optionNames = @($optionTokens | ForEach-Object {
    [regex]::Match($_, '^--(?<name>[^=]+)=').Groups['name'].Value
})
$duplicateOptionNames = @($optionNames | Group-Object |
    Where-Object { $_.Count -gt 1 })
if ($duplicateOptionNames.Count -ne 0) {
    throw "$Side runtime-core plan contains duplicate option names."
}
$aotOptionNames = @($optionNames | Where-Object { $_ -like 'aot_*' })
$unsupportedAotOptions = @($aotOptionNames | Where-Object {
    $_ -notin $allowedAotOptions
})
$missingAotOptions = @($allowedAotOptions | Where-Object {
    $_ -notin $aotOptionNames
})
if ($unsupportedAotOptions.Count -ne 0) {
    throw "$Side runtime-core plan contains unsupported AoT option(s): $($unsupportedAotOptions -join ',')"
}
if ($missingAotOptions.Count -ne 0 -or $aotOptionNames.Count -ne 4) {
    throw "$Side runtime-core plan is missing reviewed AoT option(s): $($missingAotOptions -join ',')"
}
$expectedOptionNames = @(
    'portable', 'hid', 'hid_sdl_allowed_devices',
    'logged_profile_slot_0_xuid', 'network_mode', 'upnp',
    'network_synthetic_loopback', 'api_address') + $allowedAotOptions + @(
    'apply_patches', 'auto_check_updates', 'log_level')
if ($sideConfig.InvertRightX) {
    $expectedOptionNames += 'hid_sdl_invert_right_x'
}
$unexpectedOptions = @($optionNames | Where-Object {
    $_ -notin $expectedOptionNames
})
$missingOptions = @($expectedOptionNames | Where-Object {
    $_ -notin $optionNames
})
if ($unexpectedOptions.Count -ne 0 -or $missingOptions.Count -ne 0 -or
    $optionNames.Count -ne $expectedOptionNames.Count) {
    throw (('{0} runtime-core plan changed its minimal option set: missing=[{1}] ' +
        'unexpected=[{2}]') -f $Side, ($missingOptions -join ','),
        ($unexpectedOptions -join ','))
}
if ($positionalTokens.Count -ne 1 -or
    $positionalTokens[0] -cne $config.GamePath) {
    throw "$Side runtime-core plan must have exactly one positional game path."
}

$expectedArgumentCount = [int]$sideProfile.BaseArgumentCount +
    [int][bool]$sideConfig.InvertRightX
$expectedOptionCount = [int]$sideProfile.BaseOptionCount +
    [int][bool]$sideConfig.InvertRightX
if ($resolvedTokens.Count -ne $expectedArgumentCount -or
    $optionTokens.Count -ne $expectedOptionCount) {
    throw ("$Side runtime-core plan structure mismatch: arguments={0}, options={1}" -f
        $resolvedTokens.Count, $optionTokens.Count)
}

$xeniaPath = Join-Path $sideConfig.RigDir $config.XeniaFileName
foreach ($requiredFile in $xeniaPath, $config.GamePath) {
    if (-not (Test-Path -LiteralPath $requiredFile -PathType Leaf)) {
        throw "Runtime-core acceptance input is missing: $requiredFile"
    }
}
$actualXeniaSha256 = Get-FileSha256 -Path $xeniaPath
$xeniaInfo = Get-Item -LiteralPath $xeniaPath
if ($xeniaInfo.Length -ne [int64]$profile.XeniaBytes) {
    throw 'The runtime-core candidate executable size does not match the acceptance profile.'
}
if ($actualXeniaSha256 -cne [string]$profile.XeniaSha256) {
    throw "$Side Xenia executable does not match the runtime-core candidate pin: $actualXeniaSha256"
}
$gameInfo = Get-Item -LiteralPath $config.GamePath
if ($gameInfo.Length -ne [int64]$profile.SupportedGame.IsoBytes) {
    throw 'The user-supplied game image size does not match the acceptance profile.'
}
$actualGameSha256 = Get-FileSha256 -Path $config.GamePath
if ($actualGameSha256 -cne [string]$profile.SupportedGame.IsoSha256) {
    throw 'The user-supplied game image hash does not match the acceptance profile.'
}

$rigPatchDirectory = Join-Path $sideConfig.RigDir 'patches'
$rigPatchFiles = @(Get-ChildItem -LiteralPath $rigPatchDirectory `
    -Filter '*.patch.toml' -File -ErrorAction Stop)
if ($rigPatchFiles.Count -ne 3) {
    throw "$Side rig patch directory must contain exactly three patch TOMLs."
}
$expectedPatchNames = @($expectedPatches | ForEach-Object {
    [string]$_.FileName
})
$unexpectedRigPatches = @($rigPatchFiles | Where-Object {
    $_.Name -notin $expectedPatchNames
})
if ($unexpectedRigPatches.Count -ne 0) {
    throw "$Side rig contains an unreviewed fourth patch: $($unexpectedRigPatches.Name -join ',')"
}
foreach ($patch in $expectedPatches) {
    Assert-CanonicalPatch -Path (Join-Path $rigPatchDirectory `
        ([string]$patch.FileName)) -Expected $patch
}

$argumentListSha256 = Get-TextSha256 -Text $argumentList
$result = [pscustomobject][ordered]@{
    SchemaVersion = 1
    Profile = 'B19-Runtime-Core-Acceptance'
    Side = $Side
    LaunchCapable = $false
    LaunchCapability = 'NONE_OFFLINE_PLAN_ONLY'
    RuntimeProof = if ($SyntheticFixture) {
        'SYNTHETIC FIXTURE - NO CANDIDATE RUNTIME PROOF'
    } else {
        'SOURCE-BUILT CANDIDATE - RUNTIME ACCEPTANCE PENDING'
    }
    ProfileTrust = if ($SyntheticFixture) {
        'UNTRUSTED_SYNTHETIC_TEST_ONLY'
    } else {
        'PRODUCTION_REVIEWED_PROFILE'
    }
    ProductionPinVerified = -not [bool]$SyntheticFixture
    ProfileSha256 = $profileSha256
    SourceCommit = [string]$profile.SourceCommit
    SourceTree = [string]$profile.SourceTree
    XeniaBytes = [int64]$xeniaInfo.Length
    XeniaSha256 = $actualXeniaSha256
    WorkingDirectory = $sideConfig.RigDir
    FilePath = $xeniaPath
    Affinity = $sideConfig.CpuMask
    Priority = 'High'
    ArgumentList = $argumentList
    ArgumentTokens = @($resolvedTokens)
    ArgumentListSha256 = $argumentListSha256
    TemplateSha256 = $templateSha256
    ArgumentCount = $resolvedTokens.Count
    OptionCount = $optionTokens.Count
    PatchCount = $expectedPatches.Count
    RuntimeGateStatus = 'PENDING_NOT_EXECUTED'
    PendingRuntimeGates = @($expectedRuntimeGates)
    RuntimeGateCount = $expectedRuntimeGates.Count
    Sa2AcceptanceMarkerStatus = 'PENDING_NOT_EXECUTED'
    RequiredSa2AcceptanceMarkers = @(
        $expectedSa2AcceptanceMarkers | ForEach-Object {
            [pscustomobject][ordered]@{
                Stage = [int]$_.Stage
                Event = [string]$_.Event
                Format = [string]$_.Format
            }
        })
    Sa2AcceptanceMarkerCount = $expectedSa2AcceptanceMarkers.Count
    GamePath = $config.GamePath
    GameSha256 = $actualGameSha256
    GameHashVerified = $true
    SaveSlot = $config.SaveSlot
    InstallRoot = $config.InstallRoot
    CpuAllocationPolicy = $config.CpuAllocationPolicy
    CpuTopologySignature = $config.CpuTopologySignature
    ReservedCpuMask = $config.ReservedCpuMask
    ProfileXuid = $sideConfig.ProfileXuid
    OnlineXuid = $sideConfig.OnlineXuid
    MacAddress = $sideConfig.MacAddress
    OwnHostAddress = $sideConfig.HostAddress
    PeerHostAddress = $peerConfig.HostAddress
    PlayerPort = $sideConfig.PlayerPort
    Controller = $sideConfig.Controller
    InvertRightX = $sideConfig.InvertRightX
}

if ($AsJson) {
    $result | ConvertTo-Json -Depth 6
} else {
    Write-Output $result
}
