[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module Microsoft.PowerShell.Utility -ErrorAction Stop

$root = Split-Path -Parent $PSScriptRoot
$builder = Join-Path $root 'tools\runtime\New-AotPortableLaunchPlan.ps1'
$profileRoot = Join-Path $root 'profiles\b19'
$profilePath = Join-Path $profileRoot 'profile.psd1'
$portableExample = Join-Path $root 'aot-coop.portable.example.psd1'
$localConfigPath = Join-Path $root 'aot-coop.local.psd1'

foreach ($path in $builder, $profilePath, $portableExample) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "portable launch-plan input is missing: $path"
    }
}

function Assert-Equal {
    param([object]$Actual, [object]$Expected, [string]$Label)
    if ([string]$Actual -cne [string]$Expected) {
        throw "$Label mismatch: actual=[$Actual] expected=[$Expected]"
    }
}

function Escape-DataString {
    param([string]$Value)
    return $Value.Replace("'", "''")
}

function Write-PortableConfig {
    param(
        [string]$Path,
        [string]$InstallRoot,
        [string]$GamePath = 'Game Files\Army of Two.iso',
        [string]$XeniaFileName = 'xenia_canary_netplay.exe',
        [string]$ApiAddress = 'http://127.0.0.1:36000/',
        [string]$DaddyRig = 'rigs\daddy side',
        [string]$CjRig = 'rigs\cj side',
        [string]$DaddyXuid = 'E000A1A152111111',
        [string]$CjXuid = 'E000B2B252222222',
        [string]$DaddyOnlineXuid = '0009000000000001',
        [string]$CjOnlineXuid = '0009000000000002',
        [string]$DaddyMac = '7C1E52111111',
        [string]$CjMac = '7C1E52222222',
        [string]$DaddyHost = '127.17.17.17',
        [string]$CjHost = '127.34.34.34',
        [string]$DaddyController = '0x1234/0x0001',
        [string]$CjController = '0x1234/0x0002',
        [string]$DaddyMask = '00000003',
        [string]$CjMask = '0000000C',
        [string]$XwsMask = '00000030',
        [string]$FeslMask = '00000010',
        [string]$ReservedMask = '00000000',
        [string]$TopologySignature = 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
        [int]$FeslSeconds = 86400,
        [bool]$DaddyInvert = $false,
        [bool]$CjInvert = $true,
        [int]$SaveSlot = 1,
        [string]$ExtraTopLevel = ''
    )
    $daddyInvertText = if ($DaddyInvert) { '$true' } else { '$false' }
    $cjInvertText = if ($CjInvert) { '$true' } else { '$false' }
    $text = @"
@{
    SchemaVersion = 2
    InstallRoot = '$(Escape-DataString $InstallRoot)'
    GamePath = '$(Escape-DataString $GamePath)'
    XeniaFileName = '$XeniaFileName'
    ApiAddress = '$(Escape-DataString $ApiAddress)'
    XwsRoot = 'services\xws'
    NodeExe = 'tools\node.exe'
    PythonExe = 'tools\python.exe'
    XwsCpuMask = '$XwsMask'
    FeslCpuMask = '$FeslMask'
    FeslSeconds = $FeslSeconds
    CpuAllocationPolicy = 'WholeCoreTierSplitV1'
    CpuTopologySignature = '$TopologySignature'
    ReservedCpuMask = '$ReservedMask'
    SaveSlot = $SaveSlot
    $ExtraTopLevel
    Daddy = @{
        RigDir = '$(Escape-DataString $DaddyRig)'
        ProfileXuid = '$DaddyXuid'
        OnlineXuid = '$DaddyOnlineXuid'
        MacAddress = '$DaddyMac'
        HostAddress = '$DaddyHost'
        Controller = '$DaddyController'
        CpuMask = '$DaddyMask'
        InvertRightX = $daddyInvertText
    }
    Cj = @{
        RigDir = '$(Escape-DataString $CjRig)'
        ProfileXuid = '$CjXuid'
        OnlineXuid = '$CjOnlineXuid'
        MacAddress = '$CjMac'
        HostAddress = '$CjHost'
        Controller = '$CjController'
        CpuMask = '$CjMask'
        InvertRightX = $cjInvertText
    }
}
"@
    [IO.File]::WriteAllText($Path, $text, [Text.UTF8Encoding]::new($false))
}

function Assert-Rejected {
    param([string]$ConfigPath, [string]$Pattern, [string]$Label)
    $message = ''
    try {
        & $builder -Side Daddy -ConfigPath $ConfigPath -ProfileRoot $profileRoot `
            -SkipFileChecks | Out-Null
    } catch {
        $message = $_.Exception.Message
    }
    if ([string]::IsNullOrEmpty($message) -or $message -notmatch $Pattern) {
        throw "$Label was not rejected as expected: $message"
    }
}

$profile = Import-PowerShellDataFile -LiteralPath $profilePath
$builderSource = Get-Content -Raw -LiteralPath $builder
foreach ($requiredGate in 'inject.txt must contain exactly NONE',
                          'enabled patch set is unsafe',
                          'FrozenRigSha256',
                          'source-built acceptance candidate') {
    if (-not $builderSource.Contains($requiredGate)) {
        throw "portable builder lacks required launch gate: $requiredGate"
    }
}
$localGoldenStatus = 'skipped_no_private_config'
if (Test-Path -LiteralPath $localConfigPath -PathType Leaf) {
    $daddy = & $builder -Side Daddy -ConfigPath $localConfigPath `
        -ProfileRoot $profileRoot -RequireFrozenFingerprint
    $cj = & $builder -Side Cj -ConfigPath $localConfigPath `
        -ProfileRoot $profileRoot -RequireFrozenFingerprint

    Assert-Equal $daddy.CommandLineSha256 `
        '2C604E2C124AE9485E716AC615F64EF6B9760CA52D160FAB15A09D1A09744BC6' `
        'Daddy frozen command hash'
    Assert-Equal $cj.CommandLineSha256 `
        '72C1B51FBFFACEAFF9940EE24FFECE831DDB1868E10A344584258704E6DC4CFB' `
        'CJ frozen command hash'
    Assert-Equal $daddy.TokenCount 230 'Daddy argument count'
    Assert-Equal $cj.TokenCount 230 'CJ argument count'
    Assert-Equal $daddy.OptionCount 229 'Daddy option count'
    Assert-Equal $cj.OptionCount 229 'CJ option count'
    Assert-Equal $daddy.BreakPcCount 605 'Daddy break-PC count'
    Assert-Equal $cj.BreakPcCount 626 'CJ break-PC count'
    Assert-Equal $daddy.FrozenProfilePatchCount 3 `
        'frozen-profile co-op patch count'
    $localGoldenStatus = 'passed'
}

foreach ($patchEntry in @($profile.FrozenProfileCoopPatches)) {
    $path = Join-Path (Join-Path $profileRoot 'patches') $patchEntry.FileName
    Assert-Equal (Get-FileHash -Algorithm SHA256 -LiteralPath $path).Hash `
        $patchEntry.Sha256 "canonical patch $($patchEntry.FileName)"
}
if (Test-Path -LiteralPath (Join-Path $profileRoot 'patches\454108D8 - Army of Two The 40th Day.patch.toml')) {
    throw 'license-unresolved visual patch must not be bundled in the portable profile'
}

$sanitizedText = @(
    Get-Content -Raw -LiteralPath $portableExample
    Get-Content -Raw -LiteralPath (Join-Path $profileRoot 'daddy.launch.template.txt')
    Get-Content -Raw -LiteralPath (Join-Path $profileRoot 'cj.launch.template.txt')
) -join "`n"
if (Test-Path -LiteralPath $localConfigPath -PathType Leaf) {
    $local = Import-PowerShellDataFile -LiteralPath $localConfigPath
    $privateValues = @(
        [string]$local.WorkspaceRoot,
        [string]$local.GamePath,
        [string]$local.Daddy.RigDir,
        [string]$local.Cj.RigDir,
        [string]$local.Daddy.ProfileXuid,
        [string]$local.Cj.ProfileXuid
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    foreach ($privateValue in $privateValues) {
        if ($sanitizedText.Contains($privateValue)) {
            throw 'portable profile retained a machine-local path or identity'
        }
    }
}
$legacyWorkspace = 'C:' + '\xenia-coop'
foreach ($forbidden in @($legacyWorkspace, [string]$env:USERPROFILE,
                         '_play_hero.ps1', '_play_my_ferry.bat',
                         '_play_cj_ferry.bat')) {
    if ($sanitizedText -match [regex]::Escape($forbidden)) {
        throw "portable profile retained forbidden source: $forbidden"
    }
}

$tempBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
$tempRoot = Join-Path $tempBase ('AoT portable plan {0}' -f
    [Guid]::NewGuid().ToString('N'))
if (-not ([IO.Path]::GetFullPath($tempRoot) + '\').StartsWith(
        $tempBase, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'temporary test directory escaped the system temp directory'
}
New-Item -ItemType Directory -Path $tempRoot | Out-Null
$configPath = Join-Path $tempRoot 'portable config.psd1'
try {
    Write-PortableConfig -Path $configPath -InstallRoot $tempRoot
    $portableDaddy1 = & $builder -Side Daddy -ConfigPath $configPath `
        -ProfileRoot $profileRoot -SkipFileChecks
    $portableDaddy2 = & $builder -Side Daddy -ConfigPath $configPath `
        -ProfileRoot $profileRoot -SkipFileChecks
    $portableCj = & $builder -Side Cj -ConfigPath $configPath `
        -ProfileRoot $profileRoot -SkipFileChecks

    Assert-Equal $portableDaddy1.CommandLineSha256 `
        $portableDaddy2.CommandLineSha256 'portable determinism'
    Assert-Equal $portableDaddy1.OptionCount 228 `
        'Daddy portable false right-X option count'
    Assert-Equal $portableCj.OptionCount 230 `
        'CJ portable true right-X option count'
    if ($portableDaddy1.CommandLine -notmatch
        '"[^"\r\n]*Game Files\\Army of Two\.iso"' -or
        $portableDaddy1.CommandLine -notmatch
        '"--aot_inject_keys=[^"\r\n]*daddy side\\inject\.txt"') {
        throw 'portable plan did not quote path-bearing arguments safely'
    }
    if ($portableDaddy1.CommandLine -match 'E000B2B252222222' -and
        $portableDaddy1.CommandLine -notmatch
        '--aot_peer_offline_xuid=0xE000B2B252222222') {
        throw 'portable plan leaked the peer XUID outside its typed token'
    }
    if ($portableDaddy1.RuntimeProof -cne
        'NOT RUNTIME-TESTED AS A PORTABLE LAUNCHER') {
        throw 'portable plan lost its runtime-proof disclaimer'
    }

    Write-PortableConfig -Path $configPath -InstallRoot $tempRoot `
        -XeniaFileName 'xenia_canary_aot.exe'
    $renamedXeniaPlan = & $builder -Side Daddy -ConfigPath $configPath `
        -ProfileRoot $profileRoot -SkipFileChecks
    Assert-Equal ([IO.Path]::GetFileName($renamedXeniaPlan.FilePath)) `
        'xenia_canary_aot.exe' 'renamed portable executable path'
    if ($renamedXeniaPlan.CommandLine -notmatch
        '^start "" /affinity [0-9A-F]+ /high "xenia_canary_aot\.exe" ') {
        throw 'portable plan did not render the configured Xenia file name'
    }

    Write-PortableConfig -Path $configPath -InstallRoot $tempRoot `
        -XeniaFileName 'not-xenia.exe'
    Assert-Rejected -ConfigPath $configPath `
        -Pattern 'plain xenia\*\.exe file name' `
        -Label 'non-Xenia executable name'
    Write-PortableConfig -Path $configPath -InstallRoot $tempRoot

    # Simulate a genuinely fresh netplay rig. The fork creates/reads the
    # netplay-specific config filename; no legacy xenia-canary.config.toml is
    # present to mask a stale-file bug.
    $fixtureProfileRoot = Join-Path $tempRoot 'fixture-profile'
    Copy-Item -LiteralPath $profileRoot -Destination $fixtureProfileRoot `
        -Recurse
    $fakeXeniaBytes = [Text.Encoding]::ASCII.GetBytes('portable-xenia-fixture')
    $fakeXeniaHashAlgorithm = [Security.Cryptography.SHA256]::Create()
    try {
        $fakeXeniaHash = ([BitConverter]::ToString(
            $fakeXeniaHashAlgorithm.ComputeHash($fakeXeniaBytes))) -replace '-', ''
    } finally {
        $fakeXeniaHashAlgorithm.Dispose()
    }
    $fixtureManifestPath = Join-Path $fixtureProfileRoot 'profile.psd1'
    $fixtureManifest = Get-Content -Raw -LiteralPath $fixtureManifestPath
    $acceptedMarker = 'AcceptedRuntimeXeniaSha256 = @('
    $acceptedStart = $fixtureManifest.IndexOf(
        $acceptedMarker, [StringComparison]::Ordinal)
    $acceptedEnd = if ($acceptedStart -ge 0) {
        $fixtureManifest.IndexOf(')', $acceptedStart,
            [StringComparison]::Ordinal)
    } else { -1 }
    if ($acceptedStart -lt 0 -or $acceptedEnd -le $acceptedStart) {
        throw 'fixture profile lacks an accepted-runtime hash list'
    }
    $acceptedEnd++
    $acceptedBlock = $fixtureManifest.Substring(
        $acceptedStart, $acceptedEnd - $acceptedStart)
    $rewrittenAcceptedBlock = $acceptedBlock.Replace(
        [string]$profile.XeniaSha256, $fakeXeniaHash)
    if ($rewrittenAcceptedBlock -ceq $acceptedBlock) {
        throw 'fixture accepted-runtime hash was not rewritten'
    }
    $fixtureManifest = $fixtureManifest.Substring(0, $acceptedStart) +
        $rewrittenAcceptedBlock + $fixtureManifest.Substring($acceptedEnd)
    [IO.File]::WriteAllText($fixtureManifestPath, $fixtureManifest,
        [Text.UTF8Encoding]::new($false))
    $rewrittenProfile = Import-PowerShellDataFile -LiteralPath $fixtureManifestPath
    if ($rewrittenProfile.XeniaSha256 -cne $profile.XeniaSha256 -or
        $fakeXeniaHash -notin @($rewrittenProfile.AcceptedRuntimeXeniaSha256)) {
        throw 'fixture did not isolate runtime acceptance to the accepted hash list'
    }
    $fixtureGame = Join-Path $tempRoot 'Game Files\Army of Two.iso'
    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($fixtureGame))
    [IO.File]::WriteAllText($fixtureGame, 'game-fixture',
        [Text.UTF8Encoding]::new($false))
    foreach ($rigRelative in 'rigs\daddy side', 'rigs\cj side') {
        $rigPath = Join-Path $tempRoot $rigRelative
        $patchDirectory = Join-Path $rigPath 'patches'
        [void][IO.Directory]::CreateDirectory($patchDirectory)
        [IO.File]::WriteAllBytes(
            (Join-Path $rigPath 'xenia_canary_netplay.exe'), $fakeXeniaBytes)
        [IO.File]::WriteAllText((Join-Path $rigPath 'inject.txt'), "NONE`n",
            [Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText(
            (Join-Path $rigPath 'xenia-canary-netplay.config.toml'),
            "apply_patches = true`n", [Text.UTF8Encoding]::new($false))
        if (Test-Path -LiteralPath (Join-Path $rigPath `
                'xenia-canary.config.toml')) {
            throw 'fresh fixture unexpectedly contains the legacy config filename'
        }
        foreach ($patchEntry in @($profile.FrozenProfileCoopPatches)) {
            Copy-Item -LiteralPath (Join-Path $fixtureProfileRoot `
                "patches\$($patchEntry.FileName)") -Destination $patchDirectory
        }
    }
    $freshPlan = & $builder -Side Daddy -ConfigPath $configPath `
        -ProfileRoot $fixtureProfileRoot
    Assert-Equal $freshPlan.FrozenProfilePatchCount 3 `
        'fresh netplay-config fixture patch count'

    $candidateProfileRoot = Join-Path $tempRoot 'candidate-profile'
    Copy-Item -LiteralPath $profileRoot -Destination $candidateProfileRoot `
        -Recurse
    $candidateManifestPath = Join-Path $candidateProfileRoot 'profile.psd1'
    $candidateManifest = Get-Content -Raw -LiteralPath $candidateManifestPath
    $declaredCandidate = [string]$profile.PortableRuntimeCandidate.SourceBuiltXeniaSha256
    $candidateManifest = $candidateManifest.Replace(
        $declaredCandidate, $fakeXeniaHash)
    if ($candidateManifest -notmatch [regex]::Escape($fakeXeniaHash)) {
        throw 'candidate fixture hash was not rewritten'
    }
    [IO.File]::WriteAllText($candidateManifestPath, $candidateManifest,
        [Text.UTF8Encoding]::new($false))

    $candidateRejectedWithoutSwitch = $false
    try {
        & $builder -Side Daddy -ConfigPath $configPath `
            -ProfileRoot $candidateProfileRoot | Out-Null
    } catch {
        $candidateRejectedWithoutSwitch = $_.Exception.Message -match
            'not runtime-accepted'
    }
    if (-not $candidateRejectedWithoutSwitch) {
        throw 'source-built candidate bypassed the explicit acceptance switch'
    }
    $candidatePlan = & $builder -Side Daddy -ConfigPath $configPath `
        -ProfileRoot $candidateProfileRoot -RuntimeAcceptanceCandidate
    if (-not $candidatePlan.RuntimeAcceptanceCandidate -or
        $candidatePlan.XeniaSha256 -cne $fakeXeniaHash -or
        $candidatePlan.RuntimeProof -cne
            'SOURCE-BUILT CANDIDATE - RUNTIME ACCEPTANCE PENDING') {
        throw 'source-built candidate plan lost its pending-acceptance contract'
    }

    $wrongVisualPatch = Join-Path $tempRoot `
        "rigs\daddy side\patches\$($profile.FrozenVisualPatch.FileName)"
    [IO.File]::WriteAllText($wrongVisualPatch, @"
title_name = "Army of Two: The 40th Day"
title_id = "454108D8"

[[patch]]
    name = "Unlock FPS"
    is_enabled = true
"@, [Text.UTF8Encoding]::new($false))
    $visualPatchMessage = ''
    try {
        & $builder -Side Daddy -ConfigPath $configPath `
            -ProfileRoot $fixtureProfileRoot | Out-Null
    } catch {
        $visualPatchMessage = $_.Exception.Message
    }
    if ($visualPatchMessage -notmatch
        'enabled visual patch does not match the frozen B19 manifest') {
        throw "changed same-name visual patch was not rejected: $visualPatchMessage"
    }
    Remove-Item -LiteralPath $wrongVisualPatch -Force

    Write-PortableConfig -Path $configPath -InstallRoot $tempRoot `
        -DaddyMask '00000003' -CjMask '00000002'
    Assert-Rejected -ConfigPath $configPath -Pattern 'CPU masks overlap' `
        -Label 'overlapping CPU masks'

    Write-PortableConfig -Path $configPath -InstallRoot $tempRoot `
        -XwsMask '00000031'
    Assert-Rejected -ConfigPath $configPath -Pattern 'Backend CPU masks' `
        -Label 'backend and Xenia CPU overlap'

    Write-PortableConfig -Path $configPath -InstallRoot $tempRoot `
        -XwsMask '00000020' -FeslMask '00000010'
    Assert-Rejected -ConfigPath $configPath -Pattern 'subset of XwsCpuMask' `
        -Label 'FESL outside reserved service mask'

    Write-PortableConfig -Path $configPath -InstallRoot $tempRoot `
        -ReservedMask '00000010'
    Assert-Rejected -ConfigPath $configPath -Pattern 'ReservedCpuMask must not overlap' `
        -Label 'reserved and service CPU overlap'

    Write-PortableConfig -Path $configPath -InstallRoot $tempRoot `
        -CjController '0x1234/0x0001'
    Assert-Rejected -ConfigPath $configPath -Pattern 'distinct VID/PID' `
        -Label 'duplicate controller route'

    Write-PortableConfig -Path $configPath -InstallRoot $tempRoot `
        -CjRig 'rigs\daddy side'
    Assert-Rejected -ConfigPath $configPath -Pattern 'distinct rig directories' `
        -Label 'duplicate rig directory'

    Write-PortableConfig -Path $configPath -InstallRoot $tempRoot `
        -CjRig 'portable-cj'
    Assert-Rejected -ConfigPath $configPath -Pattern 'direct child of InstallRoot' `
        -Label 'rig outside managed rigs root'

    Write-PortableConfig -Path $configPath -InstallRoot $tempRoot `
        -ApiAddress 'http://0.0.0.0:36000/'
    Assert-Rejected -ConfigPath $configPath -Pattern 'requires ApiAddress' `
        -Label 'non-loopback API'

    Write-PortableConfig -Path $configPath -InstallRoot $tempRoot `
        -ApiAddress 'http://127.0.0.1:36001/'
    Assert-Rejected -ConfigPath $configPath -Pattern 'requires ApiAddress' `
        -Label 'wrong loopback API port'

    Write-PortableConfig -Path $configPath -InstallRoot $tempRoot
    $quotedBoolean = (Get-Content -Raw -LiteralPath $configPath).Replace(
        'InvertRightX = $false', "InvertRightX = 'false'")
    [IO.File]::WriteAllText($configPath, $quotedBoolean,
        [Text.UTF8Encoding]::new($false))
    Assert-Rejected -ConfigPath $configPath -Pattern 'must be a Boolean' `
        -Label 'quoted false right-X setting'

    Write-PortableConfig -Path $configPath -InstallRoot $tempRoot `
        -DaddyXuid 'NOT_AN_XUID'
    Assert-Rejected -ConfigPath $configPath -Pattern 'offline XUID' `
        -Label 'invalid offline XUID'

    Write-PortableConfig -Path $configPath -InstallRoot $tempRoot `
        -DaddyMac '7C1E52ABCDEF'
    Assert-Rejected -ConfigPath $configPath -Pattern 'suffixes do not match' `
        -Label 'offline XUID and MAC mismatch'

    Write-PortableConfig -Path $configPath -InstallRoot $tempRoot `
        -CjOnlineXuid '0009000000000001'
    Assert-Rejected -ConfigPath $configPath -Pattern 'distinct persisted online' `
        -Label 'duplicate online XUID'

    # These identities are distinct but share the same low ten MAC bits, which
    # would otherwise derive the same synthetic loopback UDP player port.
    Write-PortableConfig -Path $configPath -InstallRoot $tempRoot `
        -CjXuid 'E000B2B252211111' -CjMac '7C1E52211111' `
        -CjHost '127.33.17.17'
    Assert-Rejected -ConfigPath $configPath -Pattern 'collide on synthetic UDP' `
        -Label 'synthetic player-port collision'

    Write-PortableConfig -Path $configPath -InstallRoot $tempRoot -SaveSlot 0
    Assert-Rejected -ConfigPath $configPath -Pattern 'Daddy host SaveSlot=1' `
        -Label 'empty save slot'

    Write-PortableConfig -Path $configPath -InstallRoot $tempRoot `
        -ExtraTopLevel "Unexpected = 'value'"
    Assert-Rejected -ConfigPath $configPath -Pattern 'unknown=\[Unexpected\]' `
        -Label 'unknown config key'

    Write-PortableConfig -Path $configPath `
        -InstallRoot ([IO.Path]::GetPathRoot($tempRoot))
    Assert-Rejected -ConfigPath $configPath -Pattern 'may not be a volume root' `
        -Label 'volume-root install path'
} finally {
    $resolvedTempRoot = [IO.Path]::GetFullPath($tempRoot)
    if (($resolvedTempRoot + '\').StartsWith($tempBase,
            [StringComparison]::OrdinalIgnoreCase) -and
        (Test-Path -LiteralPath $resolvedTempRoot)) {
        Remove-Item -LiteralPath $resolvedTempRoot -Recurse -Force
    }
}

Write-Host ("PASS: portable B19 plans are sanitized, deterministic, structurally pinned, patch-asserted, and fail closed on unsafe config; local_golden={0}" -f
    $localGoldenStatus)
