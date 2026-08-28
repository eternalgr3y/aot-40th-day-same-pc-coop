[CmdletBinding()]
param([switch]$SourceOnly)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$launcher = Join-Path $root 'Start-AOT-Coop.ps1'
$doubleClickLauncher = Join-Path $root 'PLAY-AOT-COOP.cmd'
$localConfig = Join-Path $root 'aot-coop.local.psd1'
$portableConfig = Join-Path $root 'aot-coop.portable.psd1'
$exampleConfig = if ($SourceOnly) {
    Join-Path $root 'aot-coop.portable.example.psd1'
} else {
    Join-Path $root 'aot-coop.example.psd1'
}
$source = Get-Content -Raw -LiteralPath $launcher

function Assert-SourceOrder {
    param([string]$Earlier, [string]$Later, [string]$Label)
    $first = $source.IndexOf($Earlier, [StringComparison]::Ordinal)
    $second = $source.IndexOf($Later, [StringComparison]::Ordinal)
    if ($first -lt 0 -or $second -lt 0 -or $first -ge $second) {
        throw "$Label order failed: earlier=$first later=$second"
    }
}

function Get-MutationSnapshot {
    $runCount = @(Get-ChildItem -LiteralPath (Join-Path $root '_runs') `
        -Directory -ErrorAction SilentlyContinue).Count
    $backupCount = @(Get-ChildItem -LiteralPath (Join-Path $root '_backups') `
        -Directory -ErrorAction SilentlyContinue).Count
    $state = Join-Path $root 'aot-coop.last-run.json'
    [pscustomobject]@{
        RunCount = $runCount
        BackupCount = $backupCount
        StateExists = Test-Path -LiteralPath $state -PathType Leaf
        StateHash = if (Test-Path -LiteralPath $state -PathType Leaf) {
            (Get-FileHash -Algorithm SHA256 -LiteralPath $state).Hash
        } else { '' }
        XeniaPids = @(Get-Process -Name xenia_canary_netplay `
            -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Id)
        SessionListeners = @((Get-NetTCPConnection -State Listen `
            -ErrorAction SilentlyContinue |
            Where-Object LocalPort -In 13505, 18131, 18275, 36000 |
            ForEach-Object { "$($_.LocalPort):$($_.OwningProcess)" } |
            Sort-Object))
    }
}

function Assert-SameSnapshot {
    param([object]$Before, [object]$After, [string]$Label)
    foreach ($property in 'RunCount', 'BackupCount', 'StateExists', 'StateHash') {
        if ($Before.$property -cne $After.$property) {
            throw "$Label changed $property from $($Before.$property) to $($After.$property)"
        }
    }
    if ((@($Before.XeniaPids) -join ',') -cne (@($After.XeniaPids) -join ',') -or
        (@($Before.SessionListeners) -join ',') -cne
            (@($After.SessionListeners) -join ',')) {
        throw "$Label changed live process/listener state"
    }
}

$requiredArtifacts = @($launcher, $doubleClickLauncher, $exampleConfig)
if (-not $SourceOnly) { $requiredArtifacts += $localConfig }
foreach ($file in $requiredArtifacts) {
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) {
        throw "missing launcher artifact: $file"
    }
}

$doubleClickSource = Get-Content -Raw -LiteralPath $doubleClickLauncher
foreach ($required in 'Start-AOT-Coop.ps1', '-InspectOnly',
                      '-RequireControllers', '-ExecutionPolicy Bypass',
                      'AOT_INSPECT_MODE', 'aot-coop.portable.psd1',
                      '-LaunchEngine PortablePlan') {
    if (-not $doubleClickSource.Contains($required)) {
        throw "double-click launcher lacks required contract: $required"
    }
}
foreach ($forbidden in 'inject.txt', '_pair_now.sh', '_play_hero.ps1',
                       'Stop-Process', 'taskkill') {
    if ($doubleClickSource -match [regex]::Escape($forbidden)) {
        throw "double-click launcher contains forbidden operation: $forbidden"
    }
}

if ($SourceOnly) {
    $publicIgnoreTemplate = Join-Path $root 'release\public-source.gitignore'
    if (-not (Test-Path -LiteralPath $publicIgnoreTemplate -PathType Leaf)) {
        throw 'public source ignore template is missing'
    }
    $publicIgnore = Get-Content -Raw -LiteralPath $publicIgnoreTemplate
    if ($publicIgnore -notmatch '(?m)^/aot-coop\.local\.psd1\r?$' -or
        $publicIgnore -notmatch '(?m)^/aot-coop\.portable\.psd1\r?$') {
        throw 'public source ignore template exposes machine-local config'
    }
} else {
    & git -C $root check-ignore --quiet -- 'aot-coop.local.psd1'
    if ($LASTEXITCODE -ne 0) { throw 'machine-local config is not ignored' }
}

$example = Get-Content -Raw -LiteralPath $exampleConfig
if ($example -notmatch '<absolute path to python\.exe>' -or
    $example -notmatch '<(?:16 hex profile XUID|fresh local E000 plus 12 hex digits)' -or
    $example -match '(?i)C:[\\/]Users[\\/]|E000[0-9A-F]{12}|(?<![0-9A-F])[0-9A-F]{12}(?![0-9A-F])') {
    throw 'example config is not a sanitized placeholder template'
}

foreach ($required in @(
    'Import-Module Microsoft.PowerShell.Utility -ErrorAction Stop',
    "`$expectedXeniaSha256 = 'B19F51D4D6C3730C6D7D998B4A0D75C0A5A2D911260829C47C6728E3AD464B06'",
    "`$expectedDaddyLineSha256 = '2C604E2C124AE9485E716AC615F64EF6B9760CA52D160FAB15A09D1A09744BC6'",
    "`$expectedCjLineSha256 = '72C1B51FBFFACEAFF9940EE24FFECE831DDB1868E10A344584258704E6DC4CFB'",
    "AOT_NATIVE_TRANSPORT_MINIMAL_PROBE = 'true'",
    "AOT_LEAN_PLAY_PROFILE = 'true'",
    "AOT_PHYSICAL_PADS = 'true'",
    "AOT_COMPLETE_RETAIL_MATCH = 'false'",
    "AOT_HOST_CPU_MASK = `$Config.Daddy.CpuMask",
    "AOT_CJ_CPU_MASK = `$Config.Cj.CpuMask",
    "AOT_HOST_ALLOWED_SAVE_SLOT = [string]`$Config.SaveSlot",
    "AOT_CJ_ALLOWED_SAVE_SLOT = [string]`$script:cjJoinSaveSlot",
    "New-AotPortableLaunchPlan.ps1",
    "AotPortableHardware.psm1",
    "classify_screen.ps1",
    "confirm_cj_empty_slot.ps1",
    "dump_aot_ui.ps1",
    "tools\runtime\aot_top_level_window.ps1",
    "Start-AotRigFromPlan",
    "ConvertTo-QuotedWindowsArgument `$feslScript",
    "ConvertTo-QuotedWindowsArgument `$feslLog",
    "launch_source={7}",
    "-RequireFrozenFingerprint",
    "frozen_profile_coop_patches=3",
    "XWS_BIND_ADDRESS = '127.0.0.1'",
    "XWS_ALLOW_NON_LOOPBACK = 'false'")) {
    if (-not $source.Contains($required)) { throw "launcher lacks required contract: $required" }
}
foreach ($slotContract in @(
    'Assert-CjJoinSlotStorageEmpty -Config $config -Slot $cjJoinSaveSlot',
    'WHITE: select the RIGHT save slot marked EMPTY',
    "-Label 'CJ empty right slot'",
    'Invoke-InteractiveGateProcess -Script $cjEmptySlotGate',
    'Wait-CjArmedJoin -TargetPid $cjPid',
    '$verifiedSaveSlotReady = $saveUiReady -and $rightSlotClassified',
    'WHITE: slot 2 is ARMED. Do not move it; press A exactly once now.',
    'The launcher continuously watches the slot and exact Daddy session')) {
    if (-not $source.Contains($slotContract)) {
        throw "launcher lacks asymmetric save-slot contract: $slotContract"
    }
}
foreach ($staleSlotContract in @(
    'WHITE: use the same existing MIDDLE checkpoint save.',
    "-Label 'CJ middle-slot Continue'")) {
    if ($source.Contains($staleSlotContract)) {
        throw "launcher retains unsafe CJ occupied-slot flow: $staleSlotContract"
    }
}
foreach ($candidateContract in
         'PortableRuntimeCandidate.SourceBuiltXeniaSha256',
         'declared source-built acceptance candidate',
         'RuntimeAcceptanceCandidate = [bool]$RuntimeAcceptanceCandidate') {
    if (-not $source.Contains($candidateContract)) {
        throw "launcher lacks candidate acceptance contract: $candidateContract"
    }
}

foreach ($forbidden in '_pair_now.sh', 'drive_inject.sh', 'Stop-Process -Name',
                       'Set-Content.*inject\.txt',
                       '-ArgumentList @\(''-u'', \$feslScript') {
    if ($source -match $forbidden) { throw "launcher contains forbidden operation: $forbidden" }
}

Assert-SourceOrder '$backupOutput = @(& $backupScript' `
    '$xwsProcess = Start-Process' 'backup before backend start'
Assert-SourceOrder '$backupOutput = @(& $backupScript' `
    '$clearOutput = @(& $config.NodeExe $clearSessions' 'backup before session clear'
Assert-SourceOrder '$daddyLaunchOutput = @(& $heroLauncher -Rig my_xbox)' `
    '$cjLaunchOutput = @(& $heroLauncher -Rig cjs_xbox)' 'Daddy before CJ'
Assert-SourceOrder "Write-RunState -Stage 'DaddyLobbyReady'" `
    '$cjLaunchOutput = @(& $heroLauncher -Rig cjs_xbox)' 'Daddy lobby gate before CJ'
Assert-SourceOrder '$daddyPortablePlan = & $portablePlanBuilder' `
    "if (`$InspectOnly)" 'portable plan match before InspectOnly success'
Assert-SourceOrder 'Assert-CjJoinSlotStorageEmpty -Config $config -Slot $cjJoinSaveSlot' `
    "Write-RunState -Stage 'CjLaunched'" 'empty storage preflight before CJ launch'
Assert-SourceOrder 'Invoke-InteractiveGateProcess -Script $cjEmptySlotGate' `
    'Wait-CjArmedJoin -TargetPid $cjPid' 'stable slot gate before armed join monitor'
Assert-SourceOrder 'Wait-CjArmedJoin -TargetPid $cjPid' `
    'Assert-FeslPairState $feslLog' 'exact session monitor before final pair assertions'

$armedStart = $source.IndexOf(
    'WHITE: slot 2 is ARMED. Do not move it; press A exactly once now.',
    [StringComparison]::Ordinal)
$armedEnd = $source.IndexOf('Assert-FeslPairState $feslLog', $armedStart,
    [StringComparison]::Ordinal)
if ($armedStart -lt 0 -or $armedEnd -le $armedStart -or
    $source.Substring($armedStart, $armedEnd - $armedStart) -match 'Read-Host') {
    throw 'launcher reopens an unmonitored user-input gap after arming CJ slot 2'
}

if ($source -notmatch '(?s)if \(-not \$rigLaunched\).*?Stop-OwnedBackendsBeforeRig' -or
    $source -notmatch "A rig was launched; both rigs and backends are being left untouched") {
    throw 'failure policy does not preserve a launched rig while cleaning only pre-rig backends'
}

$legacyLaunchBlock = [regex]::Match($source,
    '(?s)else \{\s*# Cross the preservation boundary.*?\$daddyLaunchOutput = @\(& \$heroLauncher -Rig my_xbox\)').Value
if ([string]::IsNullOrWhiteSpace($legacyLaunchBlock) -or
    $legacyLaunchBlock.IndexOf('$rigLaunched = $true',
        [StringComparison]::Ordinal) -gt
    $legacyLaunchBlock.IndexOf('$daddyLaunchOutput = @(& $heroLauncher',
        [StringComparison]::Ordinal)) {
    throw 'legacy launcher does not cross the preservation boundary before external invocation'
}
if ($source -notmatch '(?s)finally \{\s*if \(\$environmentSaved\).*?Restore-ProcessEnvironment') {
    throw 'environment restore is not guarded by a completed snapshot'
}
if ($doubleClickSource -notmatch
    '(?s)else if defined AOT_INSPECT_MODE.*?Read-only co-op check passed') {
    throw 'wrapper does not distinguish mutable portable launch from inspect mode'
}

if ($SourceOnly) {
    Write-Host 'PASS: Start-AOT-Coop source keeps the asymmetric slot gate retryable and binds CJ A to exact-session monitoring'
    return
}

$before = Get-MutationSnapshot
$windowsPowerShell = Join-Path $env:SystemRoot `
    'System32\WindowsPowerShell\v1.0\powershell.exe'
if (-not (Test-Path -LiteralPath $windowsPowerShell -PathType Leaf)) {
    throw "Windows PowerShell is missing: $windowsPowerShell"
}

$output = @(& $windowsPowerShell -NoProfile -ExecutionPolicy Bypass `
    -File $launcher -InspectOnly 2>&1 |
    ForEach-Object { "$_" })
$code = $LASTEXITCODE
$after = Get-MutationSnapshot
if ($code -ne 0 -or ($output -join ' ') -notmatch
    '^ALLOW inspect_only .*schema=1 launch_source=legacy-schema1 .*writes=0 launches=0$') {
    throw "InspectOnly failed: exit=$code output=$($output -join ' ')"
}
Assert-SameSnapshot $before $after 'InspectOnly'

$beforePortable = Get-MutationSnapshot
$portableOutput = @(& $windowsPowerShell -NoProfile -ExecutionPolicy Bypass `
    -File $launcher -InspectOnly -LaunchEngine PortablePlan `
    -ConfigPath $localConfig 2>&1 |
    ForEach-Object { "$_" })
$portableCode = $LASTEXITCODE
$afterPortable = Get-MutationSnapshot
if ($portableCode -ne 0 -or ($portableOutput -join ' ') -notmatch
    '^ALLOW inspect_only .*schema=1 launch_source=portable-plan .*writes=0 launches=0$') {
    throw "portable-plan InspectOnly failed: exit=$portableCode output=$($portableOutput -join ' ')"
}
Assert-SameSnapshot $beforePortable $afterPortable 'portable-plan InspectOnly'

# Invoke a valid preview in this process to prove the launcher's finally block
# restores overwritten values and removes profile variables that were absent.
$environmentProbeNames = @('AOT_RETAIL_PAIR', 'AOT_HOST_EGEG')
$environmentProbeOriginal = @{}
foreach ($name in $environmentProbeNames) {
    $environmentProbeOriginal[$name] =
        [Environment]::GetEnvironmentVariable($name, 'Process')
}
try {
    [Environment]::SetEnvironmentVariable(
        'AOT_RETAIL_PAIR', 'preserve-me', 'Process')
    Remove-Item -LiteralPath 'Env:\AOT_HOST_EGEG' -ErrorAction SilentlyContinue
    $validInProcessOutput = @(& $launcher -InspectOnly `
        -LaunchEngine PortablePlan -ConfigPath $localConfig 2>&1 |
        ForEach-Object { "$_" })
    if (($validInProcessOutput -join ' ') -notmatch
        '^ALLOW inspect_only .*writes=0 launches=0$') {
        throw "valid in-process InspectOnly failed: $($validInProcessOutput -join ' ')"
    }
    $restoredRetailPair = [Environment]::GetEnvironmentVariable(
        'AOT_RETAIL_PAIR', 'Process')
    $restoredHostEgeg = [Environment]::GetEnvironmentVariable(
        'AOT_HOST_EGEG', 'Process')
    if ($restoredRetailPair -cne 'preserve-me' -or
        $null -ne $restoredHostEgeg) {
        throw ("valid InspectOnly did not restore the caller process " +
            "environment: AOT_RETAIL_PAIR='$restoredRetailPair' " +
            "AOT_HOST_EGEG='$restoredHostEgeg'")
    }
} finally {
    foreach ($name in $environmentProbeNames) {
        if ($null -eq $environmentProbeOriginal[$name]) {
            Remove-Item -LiteralPath ("Env:\" + $name) `
                -ErrorAction SilentlyContinue
        } else {
            [Environment]::SetEnvironmentVariable(
                $name, $environmentProbeOriginal[$name], 'Process')
        }
    }
}

$portableFunction = [regex]::Match($source,
    '(?s)function Start-AotRigFromPlan \{.*?\n\}').Value
foreach ($requiredPortableField in 'Plan.FilePath', 'Plan.WorkingDirectory',
                                   'Plan.ArgumentList', 'Plan.Affinity') {
    if (-not $portableFunction.Contains($requiredPortableField)) {
        throw "portable executor does not consume $requiredPortableField"
    }
}
if ($portableFunction.Contains('Plan.CommandLine') -or
    $portableFunction -match '_play_hero|cmd\.exe|Invoke-Expression') {
    throw 'portable executor parses a rendered command or reaches the historical chain'
}
$processStart = $portableFunction.IndexOf('$process = Start-Process',
    [StringComparison]::Ordinal)
$rigOwnership = $portableFunction.IndexOf('$script:rigLaunched = $true',
    [StringComparison]::Ordinal)
$affinityWrite = $portableFunction.IndexOf('$process.ProcessorAffinity =',
    [StringComparison]::Ordinal)
if ($processStart -lt 0 -or $rigOwnership -le $processStart -or
    $affinityWrite -le $rigOwnership) {
    throw 'portable executor does not mark ownership immediately after process creation'
}

$invalid = Join-Path ([IO.Path]::GetTempPath()) (
    'aot_coop_invalid_{0}.psd1' -f [Guid]::NewGuid().ToString('N'))
try {
    [IO.File]::WriteAllText($invalid, "@{ SchemaVersion = 999 }`n",
        [Text.UTF8Encoding]::new($false))
    $beforeInvalid = Get-MutationSnapshot
    $savedErrorPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $invalidOutput = @(& $windowsPowerShell -NoProfile `
            -ExecutionPolicy Bypass -File $launcher -ConfigPath $invalid `
            -InspectOnly 2>&1 | ForEach-Object { "$_" })
        $invalidCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $savedErrorPreference
    }
    $afterInvalid = Get-MutationSnapshot
    if ($invalidCode -eq 0 -or ($invalidOutput -join ' ') -notmatch
        'Unsupported config SchemaVersion') {
        throw "invalid config was not rejected: exit=$invalidCode output=$($invalidOutput -join ' ')"
    }
    Assert-SameSnapshot $beforeInvalid $afterInvalid 'invalid config'

    $previousSentinel = [Environment]::GetEnvironmentVariable(
        'AOT_TEST_ENV_RESTORE', 'Process')
    [Environment]::SetEnvironmentVariable(
        'AOT_TEST_ENV_RESTORE', 'preserve-me', 'Process')
    try {
        $inProcessRejected = $false
        try {
            & $launcher -ConfigPath $invalid -InspectOnly | Out-Null
        } catch {
            $inProcessRejected = $_.Exception.Message -match
                'Unsupported config SchemaVersion'
        }
        if (-not $inProcessRejected -or
            [Environment]::GetEnvironmentVariable(
                'AOT_TEST_ENV_RESTORE', 'Process') -cne 'preserve-me') {
            throw 'early config rejection mutated the caller process environment'
        }
    } finally {
        [Environment]::SetEnvironmentVariable(
            'AOT_TEST_ENV_RESTORE', $previousSentinel, 'Process')
    }
} finally {
    Remove-Item -LiteralPath $invalid -Force -ErrorAction SilentlyContinue
}

# A preview config must not silently replace the accepted no-argument path,
# and Legacy must remain forceable even when that preview file exists.
$createdPortablePreview = $false
try {
    if (-not (Test-Path -LiteralPath $portableConfig -PathType Leaf)) {
        [IO.File]::WriteAllText($portableConfig,
            "@{ SchemaVersion = 999 }`n", [Text.UTF8Encoding]::new($false))
        $createdPortablePreview = $true
    }
    foreach ($mode in 'Auto', 'Legacy') {
        $modeArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File',
            $launcher, '-InspectOnly')
        if ($mode -eq 'Legacy') { $modeArgs += @('-LaunchEngine', 'Legacy') }
        $modeOutput = @(& $windowsPowerShell @modeArgs 2>&1 |
            ForEach-Object { "$_" })
        if ($LASTEXITCODE -ne 0 -or ($modeOutput -join ' ') -notmatch
            'schema=1 launch_source=legacy-schema1') {
            throw "$mode did not preserve the schema-1 fallback: $($modeOutput -join ' ')"
        }
    }
} finally {
    if ($createdPortablePreview -and
        (Test-Path -LiteralPath $portableConfig -PathType Leaf)) {
        Remove-Item -LiteralPath $portableConfig -Force
    }
}

Write-Host 'PASS: Start-AOT-Coop is fail-closed, zero-write in InspectOnly, Daddy-first, backup-first, physical-pad-only, and free of input automation'
