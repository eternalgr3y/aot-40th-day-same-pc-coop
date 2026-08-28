[CmdletBinding()]
param(
    [string]$ConfigPath = '',
    [switch]$InspectOnly,
    [switch]$RequireControllers,
    [switch]$RuntimeAcceptanceCandidate,
    [ValidateSet('Auto', 'Legacy', 'PortablePlan')]
    [string]$LaunchEngine = 'Auto'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module Microsoft.PowerShell.Utility -ErrorAction Stop
$portablePlanBuilder = Join-Path $PSScriptRoot `
    'tools\runtime\New-AotPortableLaunchPlan.ps1'
$hardwareModulePath = Join-Path $PSScriptRoot `
    'tools\runtime\AotPortableHardware.psm1'
Import-Module $hardwareModulePath -Force -ErrorAction Stop

if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    $portableDefault = Join-Path $PSScriptRoot 'aot-coop.portable.psd1'
    $legacyDefault = Join-Path $PSScriptRoot 'aot-coop.local.psd1'
    $ConfigPath = switch ($LaunchEngine) {
        'Legacy' { $legacyDefault; break }
        'PortablePlan' {
            if (Test-Path -LiteralPath $portableDefault -PathType Leaf) {
                $portableDefault
            } else {
                # The direct executor can also consume the frozen schema-1
                # configuration after its plan is independently reconstructed.
                $legacyDefault
            }
            break
        }
        default {
            # Preserve the accepted no-argument path until PortablePlan has its
            # own controlled runtime acceptance. Merely creating a preview
            # config must never change what a double-click launches.
            $legacyDefault
            break
        }
    }
}

$titleId = '454108D8'
$expectedXeniaSha256 = 'B19F51D4D6C3730C6D7D998B4A0D75C0A5A2D911260829C47C6728E3AD464B06'
$expectedXwsMainSha256 = '10D4C6B7C99EC423D875E69195D378EA304077A489001C5F286B797BA00CF63E'
$expectedFeslSha256 = 'B9711B60EE3B28EE75E0EFBE1DF304EA46087F3ED7AD99DF97AF93C85867747E'
$expectedClearSessionsSha256 = '4C96DCE9C8CA0012E7FE17EDD7E522F4448EBC227E45E304CB3AE907117681B1'
$expectedDaddyLineSha256 = '2C604E2C124AE9485E716AC615F64EF6B9760CA52D160FAB15A09D1A09744BC6'
$expectedCjLineSha256 = '72C1B51FBFFACEAFF9940EE24FFECE831DDB1868E10A344584258704E6DC4CFB'
$cjJoinSaveSlot = 2
$runtimeProfilePath = Join-Path $PSScriptRoot 'profiles\b19\profile.psd1'
if (-not (Test-Path -LiteralPath $runtimeProfilePath -PathType Leaf)) {
    throw "B19 runtime profile is missing: $runtimeProfilePath"
}
$runtimeProfile = Import-PowerShellDataFile -LiteralPath $runtimeProfilePath
$acceptedRuntimeXeniaSha256 = @(
    $runtimeProfile.AcceptedRuntimeXeniaSha256 | ForEach-Object {
        ([string]$_).ToUpperInvariant()
    })
if ($acceptedRuntimeXeniaSha256.Count -eq 0 -or
    @($acceptedRuntimeXeniaSha256 | Where-Object {
        $_ -notmatch '^[0-9A-F]{64}$'
    }).Count -ne 0 -or
    $expectedXeniaSha256 -notin $acceptedRuntimeXeniaSha256) {
    throw 'B19 runtime profile has no valid accepted executable hash set.'
}
$candidateRuntimeXeniaSha256 = ''
if ($RuntimeAcceptanceCandidate) {
    if (-not $runtimeProfile.ContainsKey('PortableRuntimeCandidate') -or
        -not $runtimeProfile.PortableRuntimeCandidate.ContainsKey(
            'SourceBuiltXeniaSha256')) {
        throw 'B19 runtime profile has no declared source-built acceptance candidate.'
    }
    $candidateRuntimeXeniaSha256 = ([string]$runtimeProfile.PortableRuntimeCandidate.SourceBuiltXeniaSha256).ToUpperInvariant()
    if ($candidateRuntimeXeniaSha256 -notmatch '^[0-9A-F]{64}$') {
        throw 'B19 runtime profile has an invalid source-built acceptance candidate hash.'
    }
}
$sessionPorts = @(13505, 18131, 18275, 36000)
$mongoPort = 27017
$runDirectory = $null
$runStatePath = $null
$xwsProcess = $null
$feslProcess = $null
$daddyPid = 0
$cjPid = 0
$rigLaunched = $false
$leaveBackendsRunning = $false
$environmentSnapshot = @{}
$environmentSaved = $false
$daddyPortablePlan = $null
$cjPortablePlan = $null
$effectiveLaunchSource = ''
$activeXeniaSha256 = $expectedXeniaSha256

function Get-Sha256 {
    param([Parameter(Mandatory = $true)][string]$Path)
    return (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash
}

function Get-TextSha256 {
    param([Parameter(Mandatory = $true)][string]$Text)
    $algorithm = [Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString(
            $algorithm.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text)))) -replace '-', ''
    } finally {
        $algorithm.Dispose()
    }
}

function Get-FullPath {
    param([Parameter(Mandatory = $true)][string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path) -or $Path -match '<[^>]+>') {
        throw "Unconfigured path: $Path"
    }
    return [IO.Path]::GetFullPath($Path).TrimEnd('\')
}

function Assert-CjJoinSlotStorageEmpty {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Config,
        [Parameter(Mandatory = $true)][ValidateRange(2, 2)][int]$Slot)

    $titleRoot = Join-Path $Config.Cj.RigDir (
        'content\{0}\{1}' -f
        ([string]$Config.Cj.ProfileXuid).ToUpperInvariant(), $titleId)
    $container = Join-Path $titleRoot (
        '00000001\default_checkpoint_{0}.sav' -f $Slot)
    $header = Join-Path $titleRoot (
        'Headers\00000001\default_checkpoint_{0}.sav.header' -f $Slot)
    if ((Test-Path -LiteralPath $container) -or
        (Test-Path -LiteralPath $header)) {
        throw ("CJ join slot $Slot is occupied. Preserve it; this alpha " +
            'requires a separately backed-up CJ profile with slot 2 empty. ' +
            'No other slot or overwrite is accepted.')
    }
}

function ConvertTo-QuotedWindowsArgument {
    param([Parameter(Mandatory = $true)][string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value) -or $Value -match '["\r\n]') {
        throw 'A process path is empty or contains an unsupported quote/newline.'
    }
    return '"' + $Value + '"'
}

function Assert-File {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Required file is missing: $Path"
    }
}

function Normalize-Mask {
    param([Parameter(Mandatory = $true)][string]$Mask)
    $value = $Mask.Trim() -replace '^(?i:0x)', ''
    if ($value -notmatch '^[0-9A-Fa-f]{1,16}$') {
        throw "Invalid CPU mask: $Mask"
    }
    $number = [Convert]::ToUInt64($value, 16)
    if ($number -eq 0) { throw 'CPU masks must be nonzero.' }
    $width = if ($number -le [uint32]::MaxValue) { 8 } else { 16 }
    return [pscustomobject]@{
        Text = $number.ToString("X$width")
        Value = $number
    }
}

function ConvertTo-AffinityInt64 {
    param([Parameter(Mandatory = $true)][string]$Mask)
    $value = [Convert]::ToUInt64(($Mask -replace '^(?i:0x)', ''), 16)
    return [BitConverter]::ToInt64([BitConverter]::GetBytes($value), 0)
}

function Import-AotConfig {
    param([Parameter(Mandatory = $true)][string]$Path)

    Assert-File $Path
    $value = Import-PowerShellDataFile -LiteralPath $Path
    if ($value.SchemaVersion -notin @(1, 2)) {
        throw "Unsupported config SchemaVersion: $($value.SchemaVersion)"
    }
    if ([int]$value.SchemaVersion -eq 2) {
        if ($LaunchEngine -eq 'Legacy') {
            throw 'SchemaVersion 2 cannot use the historical launcher chain.'
        }
        $daddyParameters = @{
            Side = 'Daddy'
            ConfigPath = $Path
        }
        if ($RuntimeAcceptanceCandidate) {
            $daddyParameters.RuntimeAcceptanceCandidate = $true
        }
        if (-not $InspectOnly) { $daddyParameters.VerifyGameHash = $true }
        $script:daddyPortablePlan = & $portablePlanBuilder @daddyParameters
        $cjParameters = @{
            Side = 'Cj'
            ConfigPath = $Path
        }
        if ($RuntimeAcceptanceCandidate) {
            $cjParameters.RuntimeAcceptanceCandidate = $true
        }
        $script:cjPortablePlan = & $portablePlanBuilder @cjParameters
        $scriptRoot = [IO.Path]::GetFullPath($PSScriptRoot).TrimEnd('\')
        if (-not [string]::Equals(
                [string]$script:daddyPortablePlan.InstallRoot, $scriptRoot,
                [StringComparison]::OrdinalIgnoreCase) -or
            -not [string]::Equals(
                [string]$script:cjPortablePlan.InstallRoot, $scriptRoot,
                [StringComparison]::OrdinalIgnoreCase)) {
            throw "InstallRoot must match this portable alpha checkout: $scriptRoot"
        }
        foreach ($property in 'GamePath', 'XwsRoot', 'NodeExe', 'PythonExe',
                              'XwsCpuMask', 'FeslCpuMask', 'FeslSeconds',
                              'CpuAllocationPolicy', 'CpuTopologySignature',
                              'ReservedCpuMask') {
            if ([string]$script:daddyPortablePlan.$property -cne
                [string]$script:cjPortablePlan.$property) {
                throw "Portable plans disagree on shared property $property."
            }
        }
        $topology = Get-AotCpuTopology
        $allocation = Get-AotCpuAllocationPlan -Topology $topology `
            -ReservedCpuMask $script:daddyPortablePlan.ReservedCpuMask
        $actualCpuContract = [ordered]@{
            Policy = [string]$script:daddyPortablePlan.CpuAllocationPolicy
            TopologySignature = [string]$script:daddyPortablePlan.CpuTopologySignature
            ReservedCpuMask = [string]$script:daddyPortablePlan.ReservedCpuMask
            DaddyCpuMask = [string]$script:daddyPortablePlan.Affinity
            CjCpuMask = [string]$script:cjPortablePlan.Affinity
            XwsCpuMask = [string]$script:daddyPortablePlan.XwsCpuMask
            FeslCpuMask = [string]$script:daddyPortablePlan.FeslCpuMask
        }
        foreach ($property in $actualCpuContract.Keys) {
            if ([string]$actualCpuContract[$property] -cne
                [string]$allocation.$property) {
                throw "Portable CPU topology contract drifted: $property=$($actualCpuContract[$property]) expected=$($allocation.$property)"
            }
        }
        $script:effectiveLaunchSource = 'portable-plan'
        return @{
            SchemaVersion = 2
            WorkspaceRoot = $scriptRoot
            XwsRoot = [string]$script:daddyPortablePlan.XwsRoot
            NodeExe = [string]$script:daddyPortablePlan.NodeExe
            PythonExe = [string]$script:daddyPortablePlan.PythonExe
            GamePath = [string]$script:daddyPortablePlan.GamePath
            SaveSlot = [int]$script:daddyPortablePlan.SaveSlot
            FeslSeconds = [int]$script:daddyPortablePlan.FeslSeconds
            XwsCpuMask = [string]$script:daddyPortablePlan.XwsCpuMask
            FeslCpuMask = [string]$script:daddyPortablePlan.FeslCpuMask
            BackupRoot = Join-Path $scriptRoot '_backups'
            Daddy = @{
                RigDir = [string]$script:daddyPortablePlan.WorkingDirectory
                ProfileXuid = [string]$script:daddyPortablePlan.ProfileXuid
                OnlineXuid = [string]$script:daddyPortablePlan.OnlineXuid
                HostAddress = [string]$script:daddyPortablePlan.HostAddress
                MacAddress = [string]$script:daddyPortablePlan.MacAddress
                Controller = [string]$script:daddyPortablePlan.Controller
                CpuMask = [string]$script:daddyPortablePlan.Affinity
            }
            Cj = @{
                RigDir = [string]$script:cjPortablePlan.WorkingDirectory
                ProfileXuid = [string]$script:cjPortablePlan.ProfileXuid
                OnlineXuid = [string]$script:cjPortablePlan.OnlineXuid
                HostAddress = [string]$script:cjPortablePlan.HostAddress
                MacAddress = [string]$script:cjPortablePlan.MacAddress
                Controller = [string]$script:cjPortablePlan.Controller
                CpuMask = [string]$script:cjPortablePlan.Affinity
            }
        }
    }

    foreach ($key in 'WorkspaceRoot', 'XwsRoot', 'NodeExe', 'PythonExe',
                     'GamePath', 'Daddy', 'Cj', 'XwsCpuMask',
                     'FeslCpuMask', 'FeslSeconds', 'SaveSlot') {
        if (-not $value.ContainsKey($key)) { throw "Config is missing $key" }
    }
    foreach ($side in 'Daddy', 'Cj') {
        foreach ($key in 'RigDir', 'ProfileXuid', 'OnlineXuid', 'Controller',
                         'CpuMask') {
            if (-not $value[$side].ContainsKey($key)) {
                throw "Config is missing $side.$key"
            }
        }
    }
    foreach ($key in 'HostAddress', 'MacAddress') {
        if (-not $value.Daddy.ContainsKey($key)) {
            throw "Config is missing Daddy.$key"
        }
    }

    $value.WorkspaceRoot = Get-FullPath $value.WorkspaceRoot
    $value.XwsRoot = Get-FullPath $value.XwsRoot
    $value.NodeExe = Get-FullPath $value.NodeExe
    $value.PythonExe = Get-FullPath $value.PythonExe
    $value.GamePath = Get-FullPath $value.GamePath
    $value.Daddy.RigDir = Get-FullPath $value.Daddy.RigDir
    $value.Cj.RigDir = Get-FullPath $value.Cj.RigDir

    $scriptRoot = [IO.Path]::GetFullPath($PSScriptRoot).TrimEnd('\')
    if (-not [string]::Equals($value.WorkspaceRoot, $scriptRoot,
            [StringComparison]::OrdinalIgnoreCase)) {
        throw "WorkspaceRoot must match this alpha checkout: $scriptRoot"
    }
    if (-not [string]::Equals($value.Daddy.RigDir,
            (Join-Path $scriptRoot 'my_xbox'),
            [StringComparison]::OrdinalIgnoreCase) -or
        -not [string]::Equals($value.Cj.RigDir,
            (Join-Path $scriptRoot 'cjs_xbox'),
            [StringComparison]::OrdinalIgnoreCase)) {
        throw 'The first alpha supports only the my_xbox/cjs_xbox rig layout.'
    }
    if ([int]$value.SaveSlot -ne 1) {
        throw 'The B19 alpha host permits only the existing middle checkpoint slot (SaveSlot=1).'
    }
    if ([int]$value.FeslSeconds -lt 600 -or [int]$value.FeslSeconds -gt 86400) {
        throw 'FeslSeconds must be from 600 through 86400.'
    }
    if ($value.Daddy.ProfileXuid -notmatch '^[0-9A-Fa-f]{16}$' -or
        $value.Cj.ProfileXuid -notmatch '^[0-9A-Fa-f]{16}$' -or
        $value.Daddy.OnlineXuid -notmatch '^[0-9A-Fa-f]{16}$' -or
        $value.Cj.OnlineXuid -notmatch '^[0-9A-Fa-f]{16}$' -or
        $value.Daddy.MacAddress -notmatch '^[0-9A-Fa-f]{12}$' -or
        $value.Daddy.HostAddress -notmatch '^127(?:\.\d{1,3}){3}$') {
        throw 'Configured profile/session identities do not match the required hex/loopback shapes.'
    }
    if ($value.Daddy.Controller -cne '0x045E/0x028E' -or
        $value.Cj.Controller -cne '0x045E/0x0B13') {
        throw 'This B19 profile expects the wired 045E/028E pad and Bluetooth 045E/0B13 pad.'
    }

    $daddyMask = Normalize-Mask $value.Daddy.CpuMask
    $cjMask = Normalize-Mask $value.Cj.CpuMask
    $xwsMask = Normalize-Mask $value.XwsCpuMask
    $feslMask = Normalize-Mask $value.FeslCpuMask
    if (($daddyMask.Value -band $cjMask.Value) -ne 0) {
        throw 'Daddy and CJ CPU masks overlap.'
    }
    if ($daddyMask.Text -cne '001F00FF' -or $cjMask.Text -cne '07C0FF00' -or
        $xwsMask.Text -cne '08200000' -or $feslMask.Text -cne '00200000') {
        throw 'CPU masks differ from the frozen B19 physical-pad profile.'
    }
    $value.Daddy.CpuMask = $daddyMask.Text
    $value.Cj.CpuMask = $cjMask.Text
    $value.XwsCpuMask = $xwsMask.Text
    $value.FeslCpuMask = $feslMask.Text
    $value.BackupRoot = Join-Path $value.WorkspaceRoot '_backups'
    $script:effectiveLaunchSource = if ($LaunchEngine -eq 'PortablePlan') {
        'portable-plan'
    } else { 'legacy-schema1' }
    return $value
}

function Assert-ColdMachineState {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Config,
        [Parameter(Mandatory = $true)][string[]]$XeniaPaths)

    $plannedNames = @($XeniaPaths | ForEach-Object {
        [IO.Path]::GetFileName($_)
    })
    $xenia = @(Get-CimInstance -ClassName Win32_Process -ErrorAction Stop |
        Where-Object {
            $_.Name -like 'xenia*.exe' -or $_.Name -in $plannedNames
        })
    if ($xenia.Count -ne 0) {
        throw "Cold-launch gate: $($xenia.Count) Xenia process(es) are already live."
    }
    $listeners = @(Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue |
        Where-Object { [int]$_.LocalPort -in $sessionPorts })
    if ($listeners.Count -ne 0) {
        $summary = $listeners | Sort-Object LocalPort |
            ForEach-Object { "$($_.LocalAddress):$($_.LocalPort)/pid=$($_.OwningProcess)" }
        throw "Cold-launch gate: session backend listener(s) already exist: $($summary -join ', ')"
    }

    $mongoListeners = @(Get-NetTCPConnection -State Listen -LocalPort $mongoPort `
        -ErrorAction Stop)
    if ($mongoListeners.Count -ne 1 -or
        $mongoListeners[0].LocalAddress -notin @('127.0.0.1', '::1')) {
        throw 'Expected exactly one loopback-only MongoDB listener on TCP 27017.'
    }
    $mongo = Get-Process -Id $mongoListeners[0].OwningProcess -ErrorAction Stop
    if ($mongo.ProcessName -cne 'mongod') {
        throw "TCP 27017 is owned by $($mongo.ProcessName), not mongod."
    }

    foreach ($side in 'Daddy', 'Cj') {
        $inject = Join-Path $Config[$side].RigDir 'inject.txt'
        Assert-File $inject
        if ((Get-Content -Raw -LiteralPath $inject).Trim() -cne 'NONE') {
            throw "$side inject.txt must already contain exactly NONE; the alpha never writes it."
        }
    }
}

function Test-ControllerPresent {
    param([Parameter(Mandatory = $true)][string]$VidPid)
    try {
        return Test-AotControllerRoutePresent -Route $VidPid
    } catch {
        Write-Warning "Controller presence could not be queried: $($_.Exception.Message)"
        return $false
    }
}

function Save-ProcessEnvironment {
    $interestingNames = @(
        'FESL_LOG', 'XWS_BIND_ADDRESS', 'XWS_ALLOW_NON_LOOPBACK',
        'XWS_CONNECTION_DIAGNOSTICS', 'AOT_JOIN_NOTIFY', 'AOT_HOST_PENT',
        'AOT_HOST_EGEG', 'AOT_HOST_SELF_UID_EGRQ', 'AOT_ACK_HOST_EGRS',
        'AOT_HOST_SELF_EGRQ', 'AOT_EGRQ_PLAIN_XUID',
        'AOT_EGRQ_PLAIN_INT_ADDR')
    foreach ($entry in [Environment]::GetEnvironmentVariables('Process').GetEnumerator()) {
        $name = [string]$entry.Key
        if ($name.StartsWith('AOT_', [StringComparison]::OrdinalIgnoreCase) -or
            $interestingNames -contains $name) {
            $script:environmentSnapshot[$name] = [string]$entry.Value
        }
    }
}

function Remove-ProcessEnvironmentVariable {
    param([Parameter(Mandatory = $true)][string]$Name)

    # On current PowerShell/.NET, SetEnvironmentVariable(..., $null, Process)
    # can leave an empty variable in the live process block. The Env: provider
    # preserves the distinction required to return an in-process caller to its
    # exact pre-launch state.
    Remove-Item -LiteralPath ("Env:\" + $Name) -ErrorAction SilentlyContinue
}

function Set-FrozenProfileEnvironment {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Config,
        [Parameter(Mandatory = $true)][string]$FeslLog)

    foreach ($entry in @([Environment]::GetEnvironmentVariables('Process').Keys)) {
        $name = [string]$entry
        if ($name.StartsWith('AOT_', [StringComparison]::OrdinalIgnoreCase)) {
            Remove-ProcessEnvironmentVariable -Name $name
        }
    }
    $profile = [ordered]@{
        AOT_RETAIL_PAIR = 'true'
        AOT_RETAIL_NATIVE_HOST = 'true'
        AOT_NATIVE_POSTJOIN_PROBE = 'true'
        AOT_NATIVE_POSTJOIN_REPAIR = 'true'
        AOT_NATIVE_RETRY_REPUBLISH = 'true'
        AOT_READY_ROSTER_PROBE = 'true'
        AOT_READY_PHASE_WRITE_WATCH = 'false'
        AOT_NATIVE_TRANSPORT_MINIMAL_PROBE = 'true'
        AOT_LEAN_PLAY_PROFILE = 'true'
        AOT_XLIVE_POST_DIAGNOSTICS = 'true'
        AOT_PHYSICAL_PADS = 'true'
        AOT_PRESERVE_FOREGROUND = 'false'
        AOT_DEATH_RESTART_PROBE = 'true'
        AOT_COMPLETE_RETAIL_MATCH = 'false'
        AOT_EXPECTED_EXECUTABLE_SHA256 = $script:activeXeniaSha256
        AOT_HOST_CPU_MASK = $Config.Daddy.CpuMask
        AOT_CJ_CPU_MASK = $Config.Cj.CpuMask
        # Checkpoint resume is role-asymmetric. Daddy loads the configured
        # occupied checkpoint; CJ selects the verified-empty right slot so the
        # title browses/joins instead of dispatching PHost.
        AOT_HOST_ALLOWED_SAVE_SLOT = [string]$Config.SaveSlot
        AOT_CJ_ALLOWED_SAVE_SLOT = [string]$script:cjJoinSaveSlot
        AOT_JOIN_NOTIFY = '1'
        AOT_HOST_PENT = '0'
        AOT_HOST_EGEG = '0'
        AOT_HOST_SELF_UID_EGRQ = '0'
        AOT_ACK_HOST_EGRS = '1'
        AOT_HOST_SELF_EGRQ = '1'
        AOT_EGRQ_PLAIN_XUID = '1'
        AOT_EGRQ_PLAIN_INT_ADDR = '0'
        FESL_LOG = $FeslLog
        XWS_BIND_ADDRESS = '127.0.0.1'
        XWS_ALLOW_NON_LOOPBACK = 'false'
        XWS_CONNECTION_DIAGNOSTICS = 'true'
    }
    foreach ($entry in $profile.GetEnumerator()) {
        [Environment]::SetEnvironmentVariable($entry.Key, $entry.Value, 'Process')
    }
    return $profile
}

function Restore-ProcessEnvironment {
    $names = @([Environment]::GetEnvironmentVariables('Process').Keys |
        ForEach-Object { [string]$_ } |
        Where-Object {
            $_.StartsWith('AOT_', [StringComparison]::OrdinalIgnoreCase) -or
            $_ -in @('FESL_LOG', 'XWS_BIND_ADDRESS', 'XWS_ALLOW_NON_LOOPBACK',
                     'XWS_CONNECTION_DIAGNOSTICS')
        })
    foreach ($name in $names) {
        Remove-ProcessEnvironmentVariable -Name $name
    }
    foreach ($entry in $script:environmentSnapshot.GetEnumerator()) {
        [Environment]::SetEnvironmentVariable(
            [string]$entry.Key, [string]$entry.Value, 'Process')
    }
}

function Assert-LaunchLine {
    param(
        [Parameter(Mandatory = $true)][ValidateSet('Daddy', 'Cj')][string]$Side,
        [Parameter(Mandatory = $true)][string]$Line,
        [Parameter(Mandatory = $true)][hashtable]$Config)

    $sideConfig = $Config[$Side]
    $expectedLineHash = if ($Side -eq 'Daddy') {
        $expectedDaddyLineSha256
    } else {
        $expectedCjLineSha256
    }
    $actualLineHash = Get-TextSha256 $Line
    if ($actualLineHash -cne $expectedLineHash) {
        throw "$Side launch-line fingerprint changed: $actualLineHash"
    }
    if ($Line -notmatch ('^start "" /affinity ' + $sideConfig.CpuMask +
            ' /high "xenia_canary_netplay\.exe" ')) {
        throw "$Side launch line has the wrong executable or CPU mask."
    }
    foreach ($token in @(
        "--logged_profile_slot_0_xuid=$($sideConfig.ProfileXuid)",
        "--hid_sdl_allowed_devices=$($sideConfig.Controller)",
        '--aot_xport_probe=true',
        '--aot_death_restart_probe=true',
        '--aot_native_postjoin_probe=true',
        '--aot_ready_roster_probe=true',
        '--aot_hero_sync=false',
        '--aot_sp_join=false',
        '--aot_sp_force_listen=false',
        '--aot_net_travel=false')) {
        if ([regex]::Matches($Line,
                '(?<!\S)' + [regex]::Escape($token) + '(?=\s|$)').Count -ne 1) {
            throw "$Side launch contract requires exactly one $token"
        }
    }
    if ($Side -eq 'Daddy') {
        foreach ($token in '--hid_sdl_invert_right_x=true',
                           '--aot_native_postjoin_repair=true',
                           '--aot_native_retry_republish=true') {
            if ([regex]::Matches($Line,
                    '(?<!\S)' + [regex]::Escape($token) + '(?=\s|$)').Count -ne 1) {
                throw "Daddy launch contract requires exactly one $token"
            }
        }
    } elseif ($Line -match '(?<!\S)--hid_sdl_invert_right_x=') {
        throw 'CJ must not inherit Daddy right-X inversion.'
    }
    if ($Line -match '(?i)82c8a0ac|--aot_(?:sp_join|sp_force_listen|hero_sync|net_travel)=true') {
        throw "$Side launch line contains a forbidden fallback or unsafe death-wait PC."
    }
    $injectPath = Join-Path $sideConfig.RigDir 'inject.txt'
    if ($Line -notmatch ('(?<!\S)--aot_inject_keys=' +
            [regex]::Escape($injectPath) + '(?=\s|$)')) {
        throw "$Side launch line does not point at its own inert inject.txt."
    }
    if (-not $Line.EndsWith(('"{0}"' -f $Config.GamePath),
            [StringComparison]::OrdinalIgnoreCase)) {
        throw "$Side launch line does not target the configured game image."
    }
    return $actualLineHash
}

function Set-VerifiedProcessContract {
    param(
        [Parameter(Mandatory = $true)][Diagnostics.Process]$Process,
        [Parameter(Mandatory = $true)][int64]$Affinity,
        [Parameter(Mandatory = $true)][Diagnostics.ProcessPriorityClass]$Priority,
        [Parameter(Mandatory = $true)][string]$Label)
    $Process.ProcessorAffinity = [IntPtr]$Affinity
    $Process.PriorityClass = $Priority
    $Process.Refresh()
    if ($Process.HasExited -or $Process.ProcessorAffinity.ToInt64() -ne $Affinity -or
        $Process.PriorityClass -ne $Priority) {
        throw "$Label process contract did not read back exactly."
    }
}

function Start-AotRigFromPlan {
    param(
        [Parameter(Mandatory = $true)][object]$Plan,
        [Parameter(Mandatory = $true)]
        [ValidateSet('Daddy', 'Cj')][string]$Side)

    if ([string]$Plan.Profile -cne 'B19' -or
        [string]$Plan.Side -cne $Side -or
        [string]$Plan.Priority -cne 'High') {
        throw "$Side portable plan lost its bounded runtime contract."
    }
    foreach ($path in [string]$Plan.FilePath,
                      [string]$Plan.WorkingDirectory) {
        if ([string]::IsNullOrWhiteSpace($path)) {
            throw "$Side portable plan contains an empty process path."
        }
    }
    $process = Start-Process -PassThru -FilePath ([string]$Plan.FilePath) `
        -ArgumentList ([string]$Plan.ArgumentList) `
        -WorkingDirectory ([string]$Plan.WorkingDirectory)

    # From this point onward a rig exists. Any failure must leave the entire
    # pair/backend state untouched for inspection instead of cleaning around it.
    $script:rigLaunched = $true
    if ($Side -eq 'Daddy') {
        $script:daddyPid = $process.Id
    } else {
        $script:cjPid = $process.Id
    }

    $targetAffinity = ConvertTo-AffinityInt64 ([string]$Plan.Affinity)
    $process.ProcessorAffinity = [IntPtr]$targetAffinity
    $process.PriorityClass = [Diagnostics.ProcessPriorityClass]::High

    # Xenia resets inherited affinity during EnableAffinityConfiguration.
    # Reassert through the fresh initialization marker, then require a stable
    # four-second readback window exactly as the historical B19 launcher does.
    $initMarkerSeen = $false
    $logPath = Join-Path ([string]$Plan.WorkingDirectory) 'xenia.log'
    $freshAfter = $process.StartTime.ToUniversalTime().AddSeconds(-2)
    $initDeadline = [DateTime]::UtcNow.AddSeconds(20)
    do {
        Start-Sleep -Milliseconds 250
        $process.Refresh()
        if ($process.HasExited) {
            throw "$Side exited while applying portable CPU affinity."
        }
        if ($process.ProcessorAffinity.ToInt64() -ne $targetAffinity) {
            $process.ProcessorAffinity = [IntPtr]$targetAffinity
        }
        if ($process.PriorityClass -ne
            [Diagnostics.ProcessPriorityClass]::High) {
            $process.PriorityClass = [Diagnostics.ProcessPriorityClass]::High
        }
        if (Test-Path -LiteralPath $logPath -PathType Leaf) {
            $logInfo = Get-Item -LiteralPath $logPath
            if ($logInfo.LastWriteTimeUtc -ge $freshAfter) {
                $initMarkerSeen = $null -ne (
                    Get-Content -LiteralPath $logPath -TotalCount 900 |
                    Select-String -SimpleMatch 'Setup: Initializing Memory...' |
                    Select-Object -First 1)
            }
        }
    } while (-not $initMarkerSeen -and
        [DateTime]::UtcNow -lt $initDeadline)

    $stableDeadline = [DateTime]::UtcNow.AddSeconds(4)
    do {
        Start-Sleep -Milliseconds 250
        $process.Refresh()
        if ($process.HasExited) {
            throw "$Side exited during portable CPU-affinity verification."
        }
        if ($process.ProcessorAffinity.ToInt64() -ne $targetAffinity) {
            $process.ProcessorAffinity = [IntPtr]$targetAffinity
        }
        if ($process.PriorityClass -ne
            [Diagnostics.ProcessPriorityClass]::High) {
            $process.PriorityClass = [Diagnostics.ProcessPriorityClass]::High
        }
    } while ([DateTime]::UtcNow -lt $stableDeadline)
    $process.Refresh()
    if ($process.ProcessorAffinity.ToInt64() -ne $targetAffinity -or
        $process.PriorityClass -ne [Diagnostics.ProcessPriorityClass]::High) {
        throw "$Side portable process contract did not remain stable."
    }
    Write-Host ("portable-plan {0} launched pid={1} affinity=0x{2} high initMarker={3}" -f
        $Side, $process.Id, ([string]$Plan.Affinity), $initMarkerSeen)
    return $process
}

function Wait-ForOwnedListeners {
    param(
        [Parameter(Mandatory = $true)][int]$ProcessId,
        [Parameter(Mandatory = $true)][int[]]$Ports,
        [ValidateRange(1, 90)][int]$TimeoutSeconds = 30)
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        $process = Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
        if ($null -eq $process) { throw "Process $ProcessId exited before its listeners were ready." }
        $listeners = @(Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue |
            Where-Object { $_.OwningProcess -eq $ProcessId -and
                [int]$_.LocalPort -in $Ports })
        $foundPorts = @($listeners | Select-Object -ExpandProperty LocalPort -Unique)
        if ($foundPorts.Count -eq $Ports.Count) {
            if (@($listeners | Where-Object LocalAddress -NotIn @('127.0.0.1', '::1')).Count -ne 0) {
                throw "Process $ProcessId exposed a non-loopback listener."
            }
            return
        }
        Start-Sleep -Milliseconds 250
    } while ([DateTime]::UtcNow -lt $deadline)
    throw "Process $ProcessId did not acquire ports $($Ports -join ',')."
}

function Invoke-GateProcess {
    param(
        [Parameter(Mandatory = $true)][string]$Script,
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [Parameter(Mandatory = $true)][string]$Label)
    $probe = Invoke-GateProbe -Script $Script -Arguments $Arguments
    if ($probe.Code -ne 0 -or $probe.Text -notmatch '^ALLOW\b') {
        throw "$Label gate rejected state: exit=$($probe.Code) output=$($probe.Text)"
    }
    Write-Host $probe.Text
    return $probe.Text
}

function Invoke-GateProbe {
    param(
        [Parameter(Mandatory = $true)][string]$Script,
        [Parameter(Mandatory = $true)][string[]]$Arguments)
    $output = @(& powershell.exe -NoProfile -NonInteractive `
        -ExecutionPolicy Bypass -File $Script @Arguments 2>&1 |
        ForEach-Object { "$_" })
    $code = $LASTEXITCODE
    $text = ($output -join ' ').Trim()
    return [pscustomobject]@{
        Code = $code
        Text = $text
    }
}

function Invoke-InteractiveGateProcess {
    param(
        [Parameter(Mandatory = $true)][string]$Script,
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [Parameter(Mandatory = $true)][string]$Label,
        [Parameter(Mandatory = $true)][string]$RetryPrompt)
    while ($true) {
        $probe = Invoke-GateProbe -Script $Script -Arguments $Arguments
        if ($probe.Code -eq 0 -and $probe.Text -match '^ALLOW\b') {
            Write-Host $probe.Text
            return $probe.Text
        }
        if ($probe.Code -eq 10 -and $probe.Text -match '^HOLD\b') {
            Write-Warning "$Label is not ready yet: $($probe.Text)"
            Read-Host $RetryPrompt | Out-Null
            continue
        }
        throw "$Label gate rejected state: exit=$($probe.Code) output=$($probe.Text)"
    }
}

function Get-ClassifierState {
    param(
        [Parameter(Mandatory = $true)][string]$Classifier,
        [Parameter(Mandatory = $true)][int]$TargetPid)
    $output = @(& powershell.exe -NoProfile -NonInteractive `
        -ExecutionPolicy Bypass -File $Classifier -ProcId $TargetPid 2>&1 |
        ForEach-Object { "$_" })
    if ($LASTEXITCODE -ne 0) {
        throw "CJ classifier failed while monitoring armed join: $($output -join ' ')"
    }
    $text = ($output -join ' ').Trim()
    $state = ($text -split '\s+', 2)[0]
    return [pscustomobject]@{ State = $state; Text = $text }
}

function Wait-CjArmedJoin {
    param(
        [Parameter(Mandatory = $true)][int]$TargetPid,
        [Parameter(Mandatory = $true)][string]$SessionGate,
        [Parameter(Mandatory = $true)][string[]]$SettledArguments,
        [Parameter(Mandatory = $true)][string]$Classifier,
        [Parameter(Mandatory = $true)][string]$UiInspector,
        [Parameter(Mandatory = $true)][hashtable]$Config,
        [Parameter(Mandatory = $true)][ValidateRange(2, 2)][int]$Slot,
        [Parameter(Mandatory = $true)][string]$FeslLog,
        [Parameter(Mandatory = $true)][string]$CjLog,
        [ValidateRange(15, 300)][int]$TimeoutSeconds = 120)

    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    $nonSlotSamples = 0
    $saveReadySamples = 0
    $ambiguousSaveSamples = 0
    $transitionObserved = $false
    $armed = $true
    while ($true) {
        if ($null -eq (Get-Process -Id $TargetPid -ErrorAction SilentlyContinue)) {
            throw "CJ process $TargetPid exited while its slot-2 join was armed."
        }

        $settled = Invoke-GateProbe -Script $SessionGate `
            -Arguments $SettledArguments
        if ($settled.Code -eq 0 -and $settled.Text -match '^ALLOW\b') {
            Write-Host $settled.Text
            return $true
        }
        if ($settled.Text -match 'expected-one-daddy-session_count=(?<count>\d+)' -and
            [int]$Matches['count'] -gt 1) {
            throw 'CJ created or exposed a second XWS session instead of joining Daddy.'
        }

        if (Test-Path -LiteralPath $FeslLog -PathType Leaf) {
            $feslTail = (Get-Content -LiteralPath $FeslLog -Tail 240) -join "`n"
            if ($feslTail -match 'GAME CREATED.*name=CJ ') {
                throw 'CJ entered the retail self-host path instead of joining Daddy.'
            }
        }
        if (Test-Path -LiteralPath $CjLog -PathType Leaf) {
            $cjTail = (Get-Content -LiteralPath $CjLog -Tail 400) -join "`n"
            if ($cjTail -match 'CreateSession flags=.*HOSTbit=true') {
                throw 'CJ set the Xenia session HOST bit instead of joining Daddy.'
            }
        }

        Assert-CjJoinSlotStorageEmpty -Config $Config -Slot $Slot
        $classification = Get-ClassifierState -Classifier $Classifier `
            -TargetPid $TargetPid
        $saveUiReady = $false
        try {
            $ui = @(& $UiInspector -TargetPid $TargetPid)
        } catch {
            # The save UI is expected to disappear while the title commits the
            # join. A racing guest-memory snapshot is non-ready evidence, not a
            # reason to tear down an otherwise monitored transition.
            $ui = @()
        }
        $managers = @($ui | Where-Object { $_.Kind -eq 'Manager' })
        $scenes = @($ui | Where-Object {
            $_.Kind -eq 'Scene' -and $_.Name -ceq 'AO3Screens.F13_Save'
        })
        $saveUiReady = $managers.Count -eq 1 -and
            $scenes.Count -eq 1 -and
            $managers[0].StableSnapshot -eq $true -and
            [int64]$managers[0].CaptureConsume -eq 1 -and
            [int64]$scenes[0].Open -eq 1 -and
            [int64]$scenes[0].InputEligible -eq 1 -and
            $scenes[0].Captured -eq $true
        $confidenceMatch = [regex]::Match($classification.Text,
            '(?i)(?:^|\s)confidence=(?<value>\d+(?:\.\d+)?)\b')
        $confidence = 0.0
        $rightSlotClassified = $classification.State -eq 'SAVE_SLOT_2' -and
            $classification.Text -match '(?i)(?:^|[; ])slot=2(?:;|\s|$)' -and
            $classification.Text -notmatch '(?i)\b(?:CONTINUE|OVERWRITE)\b' -and
            $confidenceMatch.Success -and
            [double]::TryParse($confidenceMatch.Groups['value'].Value,
                [Globalization.NumberStyles]::Float,
                [Globalization.CultureInfo]::InvariantCulture,
                [ref]$confidence) -and $confidence -ge 0.90
        $verifiedSaveSlotReady = $saveUiReady -and $rightSlotClassified

        if ($classification.State -match
            '^(?:TITLE|MAIN_MENU|STYLE_.*|SAVE_SLOT_[01]|SAVE_OPTIONS_.*|SAVE_OVERWRITE_WARNING|CHARACTER_SELECT)$') {
            throw "CJ left the armed empty slot through an unsafe state: $($classification.Text)"
        }
        if ($classification.State -match '^(?:CONNECTION_LOST|NOPROC)$') {
            throw "CJ join failed while armed: $($classification.Text)"
        }

        if ($verifiedSaveSlotReady) {
            $saveReadySamples++
            $nonSlotSamples = 0
            $ambiguousSaveSamples = 0
            if (($transitionObserved -or -not $armed) -and
                $saveReadySamples -ge 2) {
                $transitionObserved = $false
                $armed = $true
                $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
                Write-Host 'WHITE returned to verified empty slot 2. It is re-armed; press A exactly once now.' `
                    -ForegroundColor Yellow
            }
        } elseif ($saveUiReady) {
            $saveReadySamples = 0
            $nonSlotSamples = 0
            $ambiguousSaveSamples++
            if ($ambiguousSaveSamples -ge 2 -and $armed) {
                $armed = $false
                Write-Host 'WHITE slot identity is temporarily ambiguous. Do not press A; monitoring continues.' `
                    -ForegroundColor Yellow
            }
        } else {
            $saveReadySamples = 0
            $ambiguousSaveSamples = 0
            $nonSlotSamples++
            if ($nonSlotSamples -ge 2 -and -not $transitionObserved) {
                $transitionObserved = $true
                $armed = $false
                Write-Host 'WHITE slot commit observed; waiting for the exact Daddy session.'
            }
        }
        Start-Sleep -Milliseconds 500
        if ([DateTime]::UtcNow -ge $deadline) {
            if ($transitionObserved) {
                throw 'CJ left the armed slot but did not settle into Daddy session before timeout.'
            }
            if ($armed -and $saveReadySamples -ge 2) {
                Write-Host 'WHITE is still on verified empty slot 2. Press A exactly once; monitoring remains active.' `
                    -ForegroundColor Yellow
            } else {
                $armed = $false
                Write-Host 'WHITE slot proof is incomplete. Do not press A; monitoring remains active until slot 2 is re-proved.' `
                    -ForegroundColor Yellow
            }
            $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
        }
    }
}

function Assert-FeslProfile {
    param([Parameter(Mandatory = $true)][string]$LogPath)
    $deadline = [DateTime]::UtcNow.AddSeconds(10)
    do {
        $text = if (Test-Path -LiteralPath $LogPath) {
            Get-Content -Raw -LiteralPath $LogPath
        } else { '' }
        $required = @(
            'JOIN_NOTIFY(EGRQ/EGRS)=True HOST_PENT=False HOST_EGEG=False',
            'HOST_SELF_UID_EGRQ=False',
            'ACK_HOST_EGRS=True',
            'HOST_SELF_EGRQ=True',
            'EGRQ_PLAIN_XUID=True',
            'EGRQ_PLAIN_INT_ADDR=False',
            'FESL server up on 127.0.0.1:[18131, 18275, 13505]')
        $missing = @($required | Where-Object { -not $text.Contains($_) })
        if ($missing.Count -eq 0) { return }
        Start-Sleep -Milliseconds 250
    } while ([DateTime]::UtcNow -lt $deadline)
    throw "FESL profile banner mismatch; missing: $($missing -join '; ')"
}

function Assert-FeslPairState {
    param([Parameter(Mandatory = $true)][string]$LogPath)
    $text = Get-Content -Raw -LiteralPath $LogPath
    if ([regex]::Matches($text, 'GAME CREATED').Count -ne 1 -or
        $text -notmatch 'GAME CREATED gid=\d+ name=daddy endpoint=.*:1000 map=Checkpoint\?LoadSaveGame' -or
        $text -notmatch 'HOST entered its own game' -or
        [regex]::Matches($text, 'CJ ENTERED').Count -ne 1 -or
        $text -match '(?m)\bECNL\b|GAME CREATED[^\r\n]*name=CJ') {
        throw 'FESL did not preserve the one-Daddy/one-CJ pairing contract.'
    }
}

function Assert-NativeJoinMarkers {
    param(
        [Parameter(Mandatory = $true)][string]$DaddyLog,
        [Parameter(Mandatory = $true)][string]$CjLog)
    $daddy = Get-Content -Raw -LiteralPath $DaddyLog
    $cj = Get-Content -Raw -LiteralPath $CjLog
    foreach ($pattern in '\[AOT-RXHELLO\]', '\[AOT-CCON\]') {
        if ($daddy -notmatch $pattern) { throw "Daddy log lacks $pattern" }
    }
    foreach ($pattern in 'CreateSession flags=.*HOSTbit=false',
                         '\[AOT-TXHELLO\]', '\[AOT-CCON\]') {
        if ($cj -notmatch $pattern) { throw "CJ log lacks $pattern" }
    }
}

function Assert-XSessionStarted {
    param([Parameter(Mandatory = $true)][string]$LogPath,
          [Parameter(Mandatory = $true)][string]$Side)
    $count = [regex]::Matches((Get-Content -Raw -LiteralPath $LogPath),
        '(?m)\bXSessionStart\b').Count
    if ($count -lt 1) { throw "$Side has no fresh XSessionStart marker." }
}

function Write-RunState {
    param([Parameter(Mandatory = $true)][string]$Stage,
          [string]$ErrorText = '')
    if ([string]::IsNullOrWhiteSpace($script:runStatePath)) { return }
    $state = [pscustomobject][ordered]@{
        SchemaVersion = 2
        ConfigSchemaVersion = [int]$script:config.SchemaVersion
        LaunchSource = $script:effectiveLaunchSource
        UpdatedAt = (Get-Date).ToString('o')
        Stage = $Stage
        Error = $ErrorText
        RunDirectory = $script:runDirectory
        XwsPid = if ($null -ne $script:xwsProcess) { $script:xwsProcess.Id } else { 0 }
        FeslPid = if ($null -ne $script:feslProcess) { $script:feslProcess.Id } else { 0 }
        DaddyPid = $script:daddyPid
        CjPid = $script:cjPid
        XeniaSHA256 = $script:activeXeniaSha256
        XwsMainSHA256 = $expectedXwsMainSha256
        FeslSHA256 = $expectedFeslSha256
        ClearSessionsSHA256 = $expectedClearSessionsSha256
        DaddyLaunchLineSHA256 = if ($null -ne $script:daddyPortablePlan) {
            [string]$script:daddyPortablePlan.CommandLineSha256
        } else { $expectedDaddyLineSha256 }
        CjLaunchLineSHA256 = if ($null -ne $script:cjPortablePlan) {
            [string]$script:cjPortablePlan.CommandLineSha256
        } else { $expectedCjLineSha256 }
        PortableRuntimeProof = if ($RuntimeAcceptanceCandidate) {
            'SOURCE-BUILT CANDIDATE - RUNTIME ACCEPTANCE PENDING'
        } else {
            'NOT RUNTIME-TESTED AS A PORTABLE LAUNCHER'
        }
        RuntimeAcceptanceCandidate = [bool]$RuntimeAcceptanceCandidate
        CleanupPolicy = if ($script:rigLaunched) {
            'Leave both rigs and backends running for inspection.'
        } else {
            'Stop only backend PIDs created by this invocation.'
        }
    }
    $json = ($state | ConvertTo-Json -Depth 5) + "`n"
    $temporary = $script:runStatePath + '.tmp'
    [IO.File]::WriteAllText($temporary, $json, [Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $temporary -Destination $script:runStatePath -Force
    [IO.File]::WriteAllText((Join-Path $PSScriptRoot 'aot-coop.last-run.json'),
        $json, [Text.UTF8Encoding]::new($false))
}

function Stop-OwnedBackendsBeforeRig {
    foreach ($entry in @(
        @{ Process = $script:feslProcess; Token = 'tools\runtime\fesl_server.py' },
        @{ Process = $script:xwsProcess; Token = 'dist/main.js' })) {
        $process = $entry.Process
        if ($null -eq $process) { continue }
        $live = Get-CimInstance Win32_Process -Filter "ProcessId=$($process.Id)" `
            -ErrorAction SilentlyContinue
        if ($null -eq $live) { continue }
        if ([string]$live.CommandLine -notlike "*$($entry.Token)*") {
            Write-Warning "Refusing to stop PID $($process.Id): identity changed."
            continue
        }
        Stop-Process -Id $process.Id -ErrorAction SilentlyContinue
    }
}

try {
    $config = Import-AotConfig $ConfigPath
    $daddyExe = if ([int]$config.SchemaVersion -eq 2) {
        [string]$daddyPortablePlan.FilePath
    } else {
        Join-Path $config.Daddy.RigDir 'xenia_canary_netplay.exe'
    }
    $cjExe = if ([int]$config.SchemaVersion -eq 2) {
        [string]$cjPortablePlan.FilePath
    } else {
        Join-Path $config.Cj.RigDir 'xenia_canary_netplay.exe'
    }
    $xwsMain = Join-Path $config.XwsRoot 'dist\main.js'
    $clearSessions = Join-Path $config.XwsRoot 'clear_aot_sessions.js'
    $feslScript = Join-Path $config.WorkspaceRoot 'tools\runtime\fesl_server.py'
    $backupScript = Join-Path $config.WorkspaceRoot 'tools\runtime\backup_retail_acceptance_saves.ps1'
    $sessionGate = Join-Path $config.WorkspaceRoot 'tools\runtime\test_xws_session_gate.ps1'
    $continueGate = Join-Path $config.WorkspaceRoot 'tools\runtime\confirm_daddy_continue.ps1'
    $cjEmptySlotGate = Join-Path $config.WorkspaceRoot 'tools\runtime\confirm_cj_empty_slot.ps1'
    $serviceGate = Join-Path $config.WorkspaceRoot 'tools\runtime\test_service_contract.ps1'
    $screenClassifier = Join-Path $config.WorkspaceRoot 'classify_screen.ps1'
    $uiInspector = Join-Path $config.WorkspaceRoot 'dump_aot_ui.ps1'
    $windowHelper = Join-Path $config.WorkspaceRoot `
        'tools\runtime\aot_top_level_window.ps1'
    $heroLauncher = Join-Path $config.WorkspaceRoot '_play_hero.ps1'
    $requiredFiles = @($daddyExe, $cjExe, $xwsMain, $clearSessions,
        $feslScript, $backupScript, $sessionGate, $continueGate,
        $cjEmptySlotGate, $serviceGate,
        $screenClassifier, $uiInspector, $windowHelper,
        $portablePlanBuilder, $hardwareModulePath, $config.NodeExe,
        $config.PythonExe, $config.GamePath)
    if ($effectiveLaunchSource -eq 'legacy-schema1') {
        $requiredFiles += $heroLauncher
    }
    foreach ($file in $requiredFiles) {
        Assert-File $file
    }
    $daddyXeniaSha256 = Get-Sha256 $daddyExe
    $cjXeniaSha256 = Get-Sha256 $cjExe
    $runtimeHashAccepted = if ($RuntimeAcceptanceCandidate) {
        $daddyXeniaSha256 -ceq $candidateRuntimeXeniaSha256
    } else {
        $daddyXeniaSha256 -in $acceptedRuntimeXeniaSha256
    }
    if ($daddyXeniaSha256 -cne $cjXeniaSha256 -or
        -not $runtimeHashAccepted) {
        $modeLabel = if ($RuntimeAcceptanceCandidate) {
            'declared source-built acceptance candidate'
        } else {
            'runtime-accepted B19 executable'
        }
        throw ("Both rig executables must match the $modeLabel SHA-256; " +
            "Daddy=$daddyXeniaSha256 CJ=$cjXeniaSha256")
    }
    $activeXeniaSha256 = $daddyXeniaSha256
    if ((Get-Sha256 $xwsMain) -cne $expectedXwsMainSha256) {
        throw 'XWS dist/main.js is not the locally tested loopback-only alpha build.'
    }
    if ((Get-Sha256 $feslScript) -cne $expectedFeslSha256) {
        throw 'FESL service does not match the pinned portable-runtime candidate.'
    }
    if ((Get-Sha256 $clearSessions) -cne $expectedClearSessionsSha256) {
        throw 'The AoT-only XWS session reset helper changed.'
    }

    Assert-ColdMachineState -Config $config `
        -XeniaPaths @($daddyExe, $cjExe)
    Assert-CjJoinSlotStorageEmpty -Config $config -Slot $cjJoinSaveSlot
    $controllers = [ordered]@{
        Daddy = Test-ControllerPresent $config.Daddy.Controller
        Cj = Test-ControllerPresent $config.Cj.Controller
    }
    if ((-not $InspectOnly -or $RequireControllers) -and
        (-not $controllers.Daddy -or -not $controllers.Cj)) {
        throw "Both configured controllers must be awake and present: Daddy=$($controllers.Daddy) CJ=$($controllers.Cj)"
    }

    Save-ProcessEnvironment
    $environmentSaved = $true
    $inspectFeslLog = Join-Path $config.WorkspaceRoot '_runs\inspect-only-fesl.txt'
    $profile = Set-FrozenProfileEnvironment -Config $config -FeslLog $inspectFeslLog
    if ([int]$config.SchemaVersion -eq 1) {
        $daddyLine = (& $heroLauncher -Rig my_xbox -InspectOnly) -join ''
        $cjLine = (& $heroLauncher -Rig cjs_xbox -InspectOnly) -join ''
        $daddyLineHash = Assert-LaunchLine -Side Daddy -Line $daddyLine -Config $config
        $cjLineHash = Assert-LaunchLine -Side Cj -Line $cjLine -Config $config
        $daddyPortablePlan = & $portablePlanBuilder -Side Daddy `
            -ConfigPath $ConfigPath -RequireFrozenFingerprint `
            -RuntimeAcceptanceCandidate:$RuntimeAcceptanceCandidate
        $cjPortablePlan = & $portablePlanBuilder -Side Cj `
            -ConfigPath $ConfigPath -RequireFrozenFingerprint `
            -RuntimeAcceptanceCandidate:$RuntimeAcceptanceCandidate
        if ($daddyPortablePlan.CommandLine -cne $daddyLine -or
            $cjPortablePlan.CommandLine -cne $cjLine) {
            throw 'Sanitized B19 plans do not exactly match the historical launch lines.'
        }
    } else {
        $daddyLineHash = [string]$daddyPortablePlan.CommandLineSha256
        $cjLineHash = [string]$cjPortablePlan.CommandLineSha256
    }
    if ($daddyPortablePlan.FrozenProfilePatchCount -ne 3 -or
        $cjPortablePlan.FrozenProfilePatchCount -ne 3) {
        throw 'Portable B19 plans did not verify all three frozen-profile co-op patches.'
    }

    if ($InspectOnly) {
        Write-Output (("ALLOW inspect_only xenia_sha256={0} xws_sha256={1} " +
            "daddy_line_sha256={2} cj_line_sha256={3} mongo=preserved " +
            "controllers[daddy={4},cj={5}] portable_plan=matched " +
            "frozen_profile_coop_patches=3 schema={6} launch_source={7} " +
            "runtime_candidate={8} runtime_proof=not-tested " +
            "writes=0 launches=0") -f
            $activeXeniaSha256, $expectedXwsMainSha256,
            $daddyLineHash, $cjLineHash, $controllers.Daddy, $controllers.Cj,
            $config.SchemaVersion, $effectiveLaunchSource,
            ([int][bool]$RuntimeAcceptanceCandidate))
        return
    }

    $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $backupName = "aot_alpha_${stamp}_pre"
    $backupOutput = @(& $backupScript -Name $backupName `
        -DaddyProfileXuid $config.Daddy.ProfileXuid `
        -CjProfileXuid $config.Cj.ProfileXuid `
        -DaddyRigDir $config.Daddy.RigDir -CjRigDir $config.Cj.RigDir `
        -BackupRoot $config.BackupRoot `
        -XeniaFileName ([IO.Path]::GetFileName($daddyExe)))
    if (($backupOutput -join ' ') -notmatch '^PASS save_backup .*files=14 verified=1') {
        throw "Save backup did not pass: $($backupOutput -join ' ')"
    }
    Write-Host ($backupOutput -join ' ')

    $runName = "aot_alpha_$stamp"
    $runDirectory = Join-Path (Join-Path $config.WorkspaceRoot '_runs') $runName
    if (Test-Path -LiteralPath $runDirectory) {
        throw "Run directory already exists: $runDirectory"
    }
    [void][IO.Directory]::CreateDirectory($runDirectory)
    $runStatePath = Join-Path $runDirectory 'run_state.json'
    $feslLog = Join-Path $runDirectory 'fesl.txt'
    $profile = Set-FrozenProfileEnvironment -Config $config -FeslLog $feslLog
    Write-RunState -Stage 'BackedUp'

    $xwsProcess = Start-Process -PassThru -WindowStyle Hidden `
        -FilePath $config.NodeExe -WorkingDirectory $config.XwsRoot `
        -ArgumentList @('dist/main.js') `
        -RedirectStandardOutput (Join-Path $runDirectory 'xws_stdout.txt') `
        -RedirectStandardError (Join-Path $runDirectory 'xws_stderr.txt')
    Start-Sleep -Milliseconds 500
    Set-VerifiedProcessContract -Process $xwsProcess `
        -Affinity (ConvertTo-AffinityInt64 $config.XwsCpuMask) `
        -Priority Normal -Label XWS
    Wait-ForOwnedListeners -ProcessId $xwsProcess.Id -Ports @(36000) -TimeoutSeconds 60

    $feslArgumentList = @(
        '-u'
        (ConvertTo-QuotedWindowsArgument $feslScript)
        '--bind-address'
        '127.0.0.1'
        '--memcheck'
        'c0'
        '--seconds'
        [string]$config.FeslSeconds
        '--log'
        (ConvertTo-QuotedWindowsArgument $feslLog)
    ) -join ' '
    $feslProcess = Start-Process -PassThru -WindowStyle Hidden `
        -FilePath $config.PythonExe -WorkingDirectory $config.WorkspaceRoot `
        -ArgumentList $feslArgumentList `
        -RedirectStandardOutput (Join-Path $runDirectory 'fesl_stdout.txt') `
        -RedirectStandardError (Join-Path $runDirectory 'fesl_stderr.txt')
    Start-Sleep -Milliseconds 500
    Set-VerifiedProcessContract -Process $feslProcess `
        -Affinity (ConvertTo-AffinityInt64 $config.FeslCpuMask) `
        -Priority High -Label FESL
    Wait-ForOwnedListeners -ProcessId $feslProcess.Id `
        -Ports @(18131, 18275, 13505) -TimeoutSeconds 20
    Assert-FeslProfile $feslLog

    $serviceArgs = @('-Stage', 'PreDaddyLaunch', '-ExpectedFeslLogPath', $feslLog,
        '-ExpectedNodePath', $config.NodeExe,
        '-ExpectedFeslScriptPath', $feslScript,
        '-ExpectedXwsAffinity', $config.XwsCpuMask,
        '-ExpectedFeslAffinity', $config.FeslCpuMask)
    Invoke-GateProcess -Script $serviceGate -Arguments $serviceArgs `
        -Label 'service contract' | Out-Null

    $clearText = Get-Content -Raw -LiteralPath $clearSessions
    if ($clearText -notmatch "const\s+AOT_TITLE_ID\s*=\s*'454108D8'\s*;" -or
        $clearText -notmatch
            'deleteMany\(\{\s*titleId:\s*AOT_TITLE_ID\s*\}\)' -or
        $clearText -match 'deleteMany\(\s*\{\s*\}\s*\)') {
        throw 'clear_aot_sessions.js is not narrowly scoped to title 454108D8.'
    }
    $clearOutput = @(& $config.NodeExe $clearSessions 2>&1)
    if ($LASTEXITCODE -ne 0 -or ($clearOutput -join ' ') -notmatch
        'deleted 454108D8 sessions:\s*\d+') {
        throw "AoT session clear failed: $($clearOutput -join ' ')"
    }
    $emptyArgs = @('-Mode', 'Empty')
    Invoke-GateProcess -Script $sessionGate -Arguments $emptyArgs `
        -Label 'empty session' | Out-Null
    Write-RunState -Stage 'BackendsReady'

    if ($effectiveLaunchSource -eq 'portable-plan') {
        $daddyProcess = Start-AotRigFromPlan -Plan $daddyPortablePlan `
            -Side Daddy
        $daddyPid = $daddyProcess.Id
    } else {
        # Cross the preservation boundary before invoking the external legacy
        # launcher. It can create Xenia and then throw or emit malformed output;
        # from here on, cleanup must never tear down its backends around a
        # potentially live rig.
        $rigLaunched = $true
        $daddyLaunchOutput = @(& $heroLauncher -Rig my_xbox)
        if (($daddyLaunchOutput -join ' ') -notmatch 'launched pid=(\d+)') {
            throw "Daddy launcher did not report a PID: $($daddyLaunchOutput -join ' ')"
        }
        $daddyPid = [int]$Matches[1]
        $rigLaunched = $true
        Write-Host ($daddyLaunchOutput -join ' ')
    }
    Write-RunState -Stage 'DaddyLaunched'

    Read-Host @'
BLACK: use the existing MIDDLE checkpoint save only.
Stop when the slot's option reads CONTINUE, then press Enter here.
Do not choose an empty slot and do not accept OVERWRITE
'@ | Out-Null
    Invoke-InteractiveGateProcess -Script $continueGate `
        -Arguments @('-TargetPid', [string]$daddyPid) `
        -Label 'Daddy middle-slot Continue' `
        -RetryPrompt 'BLACK: leave middle CONTINUE selected, then press Enter to recheck' | Out-Null
    Read-Host 'BLACK: enter ONLINE LOBBY. Once Daddy is waiting in the lobby, press Enter here' | Out-Null
    $daddyGateArgs = @('-Mode', 'DaddyJoin',
        '-ExpectedDaddyHost', $config.Daddy.HostAddress,
        '-ExpectedDaddyMac', $config.Daddy.MacAddress,
        '-ExpectedDaddyXuid', $config.Daddy.OnlineXuid)
    Invoke-GateProcess -Script $sessionGate -Arguments $daddyGateArgs `
        -Label 'Daddy lobby' | Out-Null
    $feslText = Get-Content -Raw -LiteralPath $feslLog
    if ([regex]::Matches($feslText, 'GAME CREATED').Count -ne 1 -or
        $feslText -notmatch 'GAME CREATED gid=\d+ name=daddy .*map=Checkpoint\?LoadSaveGame' -or
        $feslText -notmatch 'HOST entered its own game') {
        throw 'Daddy FESL advertisement/self-entry gate failed.'
    }
    Write-RunState -Stage 'DaddyLobbyReady'

    if ($effectiveLaunchSource -eq 'portable-plan') {
        $cjProcess = Start-AotRigFromPlan -Plan $cjPortablePlan -Side Cj
        $cjPid = $cjProcess.Id
    } else {
        $cjLaunchOutput = @(& $heroLauncher -Rig cjs_xbox)
        if (($cjLaunchOutput -join ' ') -notmatch 'launched pid=(\d+)') {
            throw "CJ launcher did not report a PID: $($cjLaunchOutput -join ' ')"
        }
        $cjPid = [int]$Matches[1]
        Write-Host ($cjLaunchOutput -join ' ')
    }
    Write-RunState -Stage 'CjLaunched'

    Read-Host @'
WHITE: select the RIGHT save slot marked EMPTY, then press Enter here.
Do not press A yet. Do not use CONTINUE and never accept OVERWRITE
'@ | Out-Null
    $cjEmptySlotArgs = @('-TargetPid', [string]$cjPid,
        '-RigDir', $config.Cj.RigDir,
        '-ProfileXuid', $config.Cj.ProfileXuid,
        '-TitleId', $titleId,
        '-Slot', [string]$cjJoinSaveSlot)
    Invoke-InteractiveGateProcess -Script $cjEmptySlotGate `
        -Arguments $cjEmptySlotArgs -Label 'CJ empty right slot' `
        -RetryPrompt 'WHITE: leave the empty RIGHT slot selected, then press Enter to recheck' | Out-Null
    $settledArgs = @('-Mode', 'DaddySettled', '-Samples', '3',
        '-ExpectedDaddyHost', $config.Daddy.HostAddress,
        '-ExpectedDaddyMac', $config.Daddy.MacAddress,
        '-ExpectedDaddyXuid', $config.Daddy.OnlineXuid)
    Write-Host 'WHITE: slot 2 is ARMED. Do not move it; press A exactly once now.' `
        -ForegroundColor Yellow
    Write-Host 'The launcher continuously watches the slot and exact Daddy session; no terminal Enter is needed.'
    Wait-CjArmedJoin -TargetPid $cjPid `
        -SessionGate $sessionGate -SettledArguments $settledArgs `
        -Classifier $screenClassifier -UiInspector $uiInspector `
        -Config $config -Slot $cjJoinSaveSlot -FeslLog $feslLog `
        -CjLog (Join-Path $config.Cj.RigDir 'xenia.log') | Out-Null
    Assert-FeslPairState $feslLog
    Assert-NativeJoinMarkers `
        -DaddyLog (Join-Path $config.Daddy.RigDir 'xenia.log') `
        -CjLog (Join-Path $config.Cj.RigDir 'xenia.log')
    Write-RunState -Stage 'Connected'

    Write-Host ''
    Write-Host 'CONNECTED. The launcher will not press anything for you.' -ForegroundColor Green
    Write-Host '1. Press A on WHITE.'
    Write-Host '2. Press A on BLACK.'
    Write-Host '3. Press A on BLACK to Start.'
    Read-Host 'After shared gameplay has loaded, press Enter here for the final gate' | Out-Null

    Assert-XSessionStarted -LogPath (Join-Path $config.Daddy.RigDir 'xenia.log') -Side Daddy
    Assert-XSessionStarted -LogPath (Join-Path $config.Cj.RigDir 'xenia.log') -Side CJ
    $gameplayArgs = @('-Mode', 'DaddyGameplay', '-Samples', '3',
        '-ExpectedDaddyHost', $config.Daddy.HostAddress,
        '-ExpectedDaddyMac', $config.Daddy.MacAddress,
        '-ExpectedDaddyXuid', $config.Daddy.OnlineXuid)
    Invoke-GateProcess -Script $sessionGate -Arguments $gameplayArgs `
        -Label 'gameplay session' | Out-Null
    Write-RunState -Stage 'GameplaySessionReady'
    $leaveBackendsRunning = $true

    Write-Host ''
    Write-Host 'AOT CO-OP IS RUNNING. Games and local backends were deliberately left live.' -ForegroundColor Green
    Write-Host "Evidence directory: $runDirectory"
    Write-Host 'The current B19 profile passed one user-driven co-op death/checkpoint reload. Repeated-cycle and long-soak coverage remain future validation.'
} catch {
    $message = $_.Exception.Message
    if ($null -ne $runStatePath) {
        try { Write-RunState -Stage 'Failed' -ErrorText $message } catch {}
    }
    if (-not $rigLaunched) {
        Stop-OwnedBackendsBeforeRig
    } else {
        Write-Warning 'A rig was launched; both rigs and backends are being left untouched for inspection.'
    }
    throw
} finally {
    if ($environmentSaved) {
        Restore-ProcessEnvironment
    }
}
