[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$plannerPath = Join-Path $repoRoot `
    'tools\runtime\New-AotRuntimeCoreLaunchPlan.ps1'
$productionProfileRoot = Join-Path $repoRoot `
    'profiles\b19-runtime-core-acceptance'
$tempPrefix = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
$fixtureRoots = [Collections.Generic.List[string]]::new()

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Get-Sha256 {
    param([Parameter(Mandatory = $true)][string]$Path)
    return (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash
}

function Get-NormalizedTextSha256 {
    param([Parameter(Mandatory = $true)][string]$Path)
    $text = (Get-Content -Raw -LiteralPath $Path).Replace("`r`n", "`n").Replace("`r", "`n")
    $algorithm = [Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString($algorithm.ComputeHash(
            [Text.Encoding]::UTF8.GetBytes($text)))) -replace '-', ''
    } finally {
        $algorithm.Dispose()
    }
}

function Write-Utf8NoBom {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Text
    )
    [IO.File]::WriteAllText($Path, $Text, [Text.UTF8Encoding]::new($false))
}

function ConvertTo-Psd1Literal {
    param([Parameter(Mandatory = $true)][string]$Value)
    return "'" + $Value.Replace("'", "''") + "'"
}

function Set-FixtureProfileText {
    param(
        [Parameter(Mandatory = $true)][object]$Fixture,
        [Parameter(Mandatory = $true)][string]$Text
    )
    Write-Utf8NoBom -Path $Fixture.ProfilePath -Text $Text
}

function Set-FixtureSideTemplateHash {
    param(
        [Parameter(Mandatory = $true)][object]$Fixture,
        [Parameter(Mandatory = $true)][ValidateSet('Daddy', 'Cj')]
        [string]$Side,
        [Parameter(Mandatory = $true)][string]$Hash
    )
    $text = Get-Content -Raw -LiteralPath $Fixture.ProfilePath
    $pattern = "(?s)(\b$Side\s*=\s*@\{.*?TemplateSha256\s*=\s*')[0-9A-F]{64}(')"
    $regex = [regex]::new($pattern)
    $updated = $regex.Replace($text, '${1}' + $Hash + '${2}', 1)
    if ($updated -ceq $text) {
        throw "Could not update $Side fixture template hash."
    }
    Set-FixtureProfileText -Fixture $Fixture -Text $updated
}

function New-Fixture {
    param([Parameter(Mandatory = $true)][string]$Label)

    $root = Join-Path $tempPrefix ('AoT runtime core {0} {1}' -f
        $Label, [Guid]::NewGuid().ToString('N'))
    $resolvedRoot = [IO.Path]::GetFullPath($root)
    if (-not ($resolvedRoot + '\').StartsWith(
            $tempPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Synthetic fixture escaped the system temp directory.'
    }
    [void][IO.Directory]::CreateDirectory($resolvedRoot)
    $fixtureRoots.Add($resolvedRoot)

    $profileRoot = Join-Path $resolvedRoot 'acceptance profile'
    Copy-Item -LiteralPath $productionProfileRoot -Destination $profileRoot `
        -Recurse

    $installRoot = Join-Path $resolvedRoot 'portable install'
    $daddyRig = Join-Path $installRoot 'rigs\daddy side'
    $cjRig = Join-Path $installRoot 'rigs\cj side'
    foreach ($directory in $daddyRig, $cjRig,
            (Join-Path $daddyRig 'patches'), (Join-Path $cjRig 'patches')) {
        [void][IO.Directory]::CreateDirectory($directory)
    }

    $xeniaFileName = 'xenia_runtime_core_fixture.exe'
    $xeniaBytes = [Text.Encoding]::UTF8.GetBytes(
        'synthetic-runtime-core-xenia-candidate')
    foreach ($rig in $daddyRig, $cjRig) {
        [IO.File]::WriteAllBytes((Join-Path $rig $xeniaFileName), $xeniaBytes)
        Get-ChildItem -LiteralPath (Join-Path $profileRoot 'patches') `
            -File -Filter '*.patch.toml' | ForEach-Object {
                Copy-Item -LiteralPath $_.FullName -Destination `
                    (Join-Path (Join-Path $rig 'patches') $_.Name)
            }
    }
    $xeniaHash = Get-Sha256 -Path (Join-Path $daddyRig $xeniaFileName)

    $gamePath = Join-Path $installRoot 'game images\Army of Two fixture.iso'
    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($gamePath))
    $gameBytes = [Text.Encoding]::UTF8.GetBytes(
        'synthetic legally-owned game fixture')
    [IO.File]::WriteAllBytes($gamePath, $gameBytes)
    $gameHash = Get-Sha256 -Path $gamePath

    $profilePath = Join-Path $profileRoot 'profile.psd1'
    $profileText = Get-Content -Raw -LiteralPath $profilePath
    $profileText = $profileText.Replace(
        'E0AE2C785BC19637E83019FE921E0D3CEE83B229D1CDF9B82F6508A50336C629',
        $xeniaHash)
    $profileText = $profileText.Replace(
        'XeniaBytes = 17942016', "XeniaBytes = $($xeniaBytes.Length)")
    $profileText = $profileText.Replace(
        'IsoBytes = 7838695424', "IsoBytes = $($gameBytes.Length)")
    $profileText = $profileText.Replace(
        '7C2008F53D4569D4079311B36CF2555E5FDC26B48A2C2E3578580B9F07EC16EF',
        $gameHash)
    Write-Utf8NoBom -Path $profilePath -Text $profileText

    $configPath = Join-Path $resolvedRoot 'synthetic acceptance config.psd1'
    $configText = @"
@{
    SchemaVersion = 2
    InstallRoot = $(ConvertTo-Psd1Literal $installRoot)
    GamePath = $(ConvertTo-Psd1Literal $gamePath)
    XeniaFileName = '$xeniaFileName'
    ApiAddress = 'http://127.0.0.1:36000/'
    XwsRoot = 'services\xws'
    NodeExe = 'tools\node.exe'
    PythonExe = 'tools\python.exe'
    FeslSeconds = 7200
    XwsCpuMask = '00000030'
    FeslCpuMask = '00000010'
    CpuAllocationPolicy = 'WholeCoreTierSplitV1'
    CpuTopologySignature = 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA'
    ReservedCpuMask = '00000000'
    SaveSlot = 1
    Daddy = @{
        RigDir = 'rigs\daddy side'
        ProfileXuid = 'E000A1A152111111'
        OnlineXuid = '0009000000000001'
        MacAddress = '7C1E52111111'
        HostAddress = '127.17.17.17'
        Controller = '0x1234/0x0001'
        CpuMask = '00000003'
        InvertRightX = `$false
    }
    Cj = @{
        RigDir = 'rigs\cj side'
        ProfileXuid = 'E000B2B252222222'
        OnlineXuid = '0009000000000002'
        MacAddress = '7C1E52222222'
        HostAddress = '127.34.34.34'
        Controller = '0x1234/0x0002'
        CpuMask = '0000000C'
        InvertRightX = `$true
    }
}
"@
    Write-Utf8NoBom -Path $configPath -Text $configText

    return [pscustomobject]@{
        Root = $resolvedRoot
        ProfileRoot = $profileRoot
        ProfilePath = $profilePath
        ConfigPath = $configPath
        InstallRoot = $installRoot
        GamePath = $gamePath
        DaddyRig = $daddyRig
        CjRig = $cjRig
        XeniaFileName = $xeniaFileName
    }
}

function Invoke-Plan {
    param(
        [Parameter(Mandatory = $true)][object]$Fixture,
        [Parameter(Mandatory = $true)][ValidateSet('Daddy', 'Cj')]
        [string]$Side
    )
    return & $plannerPath -Side $Side -ConfigPath $Fixture.ConfigPath `
        -ProfileRoot $Fixture.ProfileRoot -SyntheticFixture
}

function Assert-Throws {
    param(
        [Parameter(Mandatory = $true)][scriptblock]$Action,
        [Parameter(Mandatory = $true)][string]$Pattern,
        [Parameter(Mandatory = $true)][string]$Label
    )
    $caught = $null
    try {
        & $Action
    } catch {
        $caught = $_
    }
    if ($null -eq $caught) {
        throw "$Label did not fail closed."
    }
    if ([string]$caught.Exception.Message -notmatch $Pattern) {
        throw "$Label failed for the wrong reason: $($caught.Exception.Message)"
    }
}

function Get-FixtureFingerprint {
    param([Parameter(Mandatory = $true)][string]$Root)
    return @(
        Get-ChildItem -LiteralPath $Root -Recurse -File |
            Sort-Object FullName | ForEach-Object {
                $relative = $_.FullName.Substring($Root.Length).TrimStart('\')
                '{0}|{1}|{2}|{3:o}' -f $relative, $_.Length,
                    (Get-Sha256 -Path $_.FullName), $_.LastWriteTimeUtc
            }
    ) -join "`n"
}

try {
    Assert-True (Test-Path -LiteralPath $plannerPath -PathType Leaf) `
        'Runtime-core acceptance planner is missing.'
    Assert-True (Test-Path -LiteralPath $productionProfileRoot -PathType Container) `
        'Runtime-core acceptance profile is missing.'

    $productionManifest = Import-PowerShellDataFile -LiteralPath `
        (Join-Path $productionProfileRoot 'profile.psd1')
    Assert-True (
        [string]$productionManifest.SourceCommit -ceq
            'b8c0c49520e841a97309e7c742570c0a8769c4f6' -and
        [string]$productionManifest.SourceTree -ceq
            '1194169c7723b1bbf314105c5255a7ea2e2e7c97' -and
        [int64]$productionManifest.XeniaBytes -eq 17942016 -and
        [string]$productionManifest.XeniaSha256 -ceq
            'E0AE2C785BC19637E83019FE921E0D3CEE83B229D1CDF9B82F6508A50336C629' -and
        @($productionManifest.PendingRuntimeGates).Count -eq 14 -and
        @($productionManifest.RequiredSa2AcceptanceMarkers).Count -eq 3 -and
        -not [bool]$productionManifest.PlayerKitReady -and
        -not [bool]$productionManifest.RuntimeTested -and
        -not [bool]$productionManifest.LaunchCapable) `
        'Production runtime-core profile lost its source/build-only pins.'
    Assert-True ((Get-NormalizedTextSha256 -Path (Join-Path `
            $productionProfileRoot 'profile.psd1')) -ceq
            '87987BECC70800C3D7CA3434E7BE15365A8E3053185E04121AE38525BFA5E891') `
        'Production runtime-core profile bytes lost their reviewed normalized hash.'

    $canonicalPatchHashes = @{
        '454108D8 - coop-bind-6000.patch.toml' =
            'BCD3F9A62106424908DA3AD8B543D1A482D4C4561DCCBF26D8EBE99A8CFBE295'
        '454108D8 - coop-cod-unaddressed.patch.toml' =
            'F5CC6083791194E48106E4DE7D6D31C061BAFB43FA90EE935A56698398BC5036'
        '454108D8 - coop-hold-connecting-v2.patch.toml' =
            'F01126934D5CE6E7DBC9D3C51D3F119DA7C50684B83AF838B4C3C8ED22497440'
    }
    foreach ($patchName in $canonicalPatchHashes.Keys) {
        foreach ($root in $productionProfileRoot, (Join-Path $repoRoot 'profiles\b19')) {
            Assert-True ((Get-Sha256 -Path (Join-Path $root "patches\$patchName")) `
                -ceq $canonicalPatchHashes[$patchName]) `
                "Canonical patch bytes changed: $root $patchName"
        }
    }
    Assert-True ((Get-Sha256 -Path (Join-Path $repoRoot `
            'profiles\b19\profile.psd1')) -ceq
            '22E20270E20B17F06B134C8757E1B20A71DA4126C5EABC810F52369D1543765B') `
        'Frozen B19 manifest bytes changed.'
    Assert-True ((Get-Sha256 -Path (Join-Path $repoRoot `
            'profiles\b19\daddy.launch.template.txt')) -ceq
            '26C44B74511E80238042F61C095976A03089DBCBF65E31A7DCD02CDA78A952DF') `
        'Frozen B19 Daddy template bytes changed.'
    Assert-True ((Get-Sha256 -Path (Join-Path $repoRoot `
            'profiles\b19\cj.launch.template.txt')) -ceq
            '8E9122E972389EAFA0701DA7BFC1C301043FF490049334EC70901B743145CEBC') `
        'Frozen B19 CJ template bytes changed.'

    $plannerSource = Get-Content -Raw -LiteralPath $plannerPath
    $forbiddenPlannerPattern = ('(?i)\b(?:Start-Process|Stop-Process|' +
        'Get-Process|Get-CimInstance|Get-Net\w*|Set-Net\w*|Copy-Item|' +
        'Move-Item|Rename-Item|New-Item|Remove-Item|Set-Content|' +
        'Add-Content|Clear-Content|Out-File|Tee-Object|Start-Job|' +
        'Invoke-Expression|Invoke-Command|Invoke-WebRequest|' +
        'Invoke-RestMethod|Start-Service|Stop-Service|Set-Service|' +
        'Register-ScheduledTask|Start-BitsTransfer)\b|' +
        '\[(?:IO\.(?:File|Directory)|Diagnostics\.Process)\]::' +
        '(?:Write|WriteAll|CreateDirectory|Delete|Move|Copy|OpenWrite|Start)|' +
        'Net\.(?:WebClient|HttpClient|Sockets|TcpClient|UdpClient)|' +
        'Microsoft\.Win32\.Registry|WScript\.Shell|Diagnostics\.Process')
    Assert-True ($plannerSource -notmatch $forbiddenPlannerPattern) `
        'Offline planner contains a process, network-discovery, or write primitive.'
    $plannerTokens = $null
    $plannerErrors = $null
    $plannerAst = [Management.Automation.Language.Parser]::ParseFile(
        $plannerPath, [ref]$plannerTokens, [ref]$plannerErrors)
    Assert-True ($plannerErrors.Count -eq 0) `
        'Offline planner does not parse for command allowlist inspection.'
    $allowedPlannerCommands = @(
        'Assert-CanonicalPatch', 'Assert-ExactKeys', 'Assert-PlainValue',
        'Compare-Object', 'ConvertTo-Json', 'ConvertTo-WindowsArgument',
        'ForEach-Object', 'Get-ChildItem', 'Get-Content', 'Get-FileHash',
        'Get-FileSha256', 'Get-Item', 'Get-NormalizedConfig',
        'Get-NormalizedTextFileSha256', 'Get-TextSha256', 'Group-Object',
        'Import-Module', 'Import-PowerShellDataFile', 'Join-Path',
        'Normalize-CpuMask', 'Resolve-ConfigPath', 'Set-StrictMode',
        'Split-Path', 'Test-Path', 'Where-Object', 'Write-Output')
    $unknownPlannerCommands = @($plannerAst.FindAll({
            param($node)
            $node -is [Management.Automation.Language.CommandAst]
        }, $true) | ForEach-Object {
            $name = $_.GetCommandName()
            if ([string]::IsNullOrWhiteSpace($name) -or
                $name -notin $allowedPlannerCommands) {
                if ([string]::IsNullOrWhiteSpace($name)) {
                    '<dynamic-command>'
                } else { $name }
            }
        })
    Assert-True ($unknownPlannerCommands.Count -eq 0) `
        "Offline planner command escaped the read-only allowlist: $($unknownPlannerCommands -join ',')"

    $fixture = New-Fixture -Label 'positive'
    $before = Get-FixtureFingerprint -Root $fixture.Root
    $daddy = Invoke-Plan -Fixture $fixture -Side Daddy
    $cj = Invoke-Plan -Fixture $fixture -Side Cj
    $daddyAgain = Invoke-Plan -Fixture $fixture -Side Daddy
    $after = Get-FixtureFingerprint -Root $fixture.Root
    Assert-True ($before -ceq $after) `
        'Offline planning changed or created fixture files.'
    Assert-True (($daddy | ConvertTo-Json -Depth 7 -Compress) -ceq
        ($daddyAgain | ConvertTo-Json -Depth 7 -Compress)) `
        'Offline planning is not deterministic.'

    foreach ($plan in $daddy, $cj) {
        Assert-True (-not [bool]$plan.LaunchCapable -and
            [string]$plan.LaunchCapability -ceq 'NONE_OFFLINE_PLAN_ONLY' -and
            [string]$plan.RuntimeProof -ceq
                'SYNTHETIC FIXTURE - NO CANDIDATE RUNTIME PROOF' -and
            [string]$plan.ProfileTrust -ceq 'UNTRUSTED_SYNTHETIC_TEST_ONLY' -and
            -not [bool]$plan.ProductionPinVerified -and
            [bool]$plan.GameHashVerified) `
            "$($plan.Side) plan overstates runtime or launch readiness."
        Assert-True ($plan.PSObject.Properties.Name -notcontains 'CommandLine') `
            "$($plan.Side) plan exposed a start command."
        Assert-True ([int]$plan.PatchCount -eq 3 -and
            [string]$plan.SourceCommit -ceq
                'b8c0c49520e841a97309e7c742570c0a8769c4f6' -and
            [string]$plan.SourceTree -ceq
                '1194169c7723b1bbf314105c5255a7ea2e2e7c97' -and
            [int64]$plan.XeniaBytes -gt 0) `
            "$($plan.Side) plan lost its source or patch pins."
        Assert-True ([string]$plan.RuntimeGateStatus -ceq
                'PENDING_NOT_EXECUTED' -and
            [int]$plan.RuntimeGateCount -eq 14 -and
            @($plan.PendingRuntimeGates)[0] -ceq
                'ZERO_LIVE_XENIA_PROCESSES_BEFORE_STAGING' -and
            @($plan.PendingRuntimeGates)[1] -ceq
                'VERIFIED_SAVE_BACKUP_COMPLETED_BEFORE_ACCEPTANCE_RUN_PREP' -and
            @($plan.PendingRuntimeGates)[2] -ceq
                'ISOLATED_RIG_ROOTS_CREATED_WITHOUT_OVERWRITE' -and
            @($plan.PendingRuntimeGates)[3] -ceq
                'DADDY_SLOT_1_OCCUPIED_AND_CJ_SLOT_2_VERIFIED_EMPTY' -and
            @($plan.PendingRuntimeGates)[7] -ceq
                'XWS_WHOAMI_IS_NONZERO_AND_BACKEND_IS_HEALTHY_BEFORE_JOIN' -and
            @($plan.PendingRuntimeGates)[8] -ceq
                'SA2_BOTH_SIDES_EMIT_EXACTLY_ONE_MANAGER_ARM_MARKER' -and
            @($plan.PendingRuntimeGates)[9] -ceq
                'SA2_ONE_SIDE_PROVES_GENERATION_BOUND_PREPARE_ARM_CONSUME_ACK_CHAIN' -and
            @($plan.PendingRuntimeGates)[10] -ceq
                'EXTERNAL_TIMEOUT_AND_CLEANUP_ARE_ENFORCED') `
            "$($plan.Side) plan lost the decisive SA2 ordering or timeout gates."
        $sa2Markers = @($plan.RequiredSa2AcceptanceMarkers)
        Assert-True ([string]$plan.Sa2AcceptanceMarkerStatus -ceq
                'PENDING_NOT_EXECUTED' -and
            [int]$plan.Sa2AcceptanceMarkerCount -eq 3 -and
            $sa2Markers.Count -eq 3 -and
            [int]$sa2Markers[0].Stage -eq 1 -and
            [string]$sa2Markers[0].Event -ceq
                'PRECONNECT_XSA1_PREPARED_FOR_GUEST' -and
            [string]$sa2Markers[0].Format -ceq
                '[AOT-RUNTIME-SA2][ACCEPT] seq=<seq> generation=<generation> stage=1 event=PRECONNECT_XSA1_PREPARED_FOR_GUEST' -and
            [int]$sa2Markers[1].Stage -eq 2 -and
            [string]$sa2Markers[1].Event -ceq
                'XNETCONNECT_MANAGER_ARMED' -and
            [string]$sa2Markers[1].Format -ceq
                '[AOT-RUNTIME-SA2][ACCEPT] seq=<seq> generation=<generation> stage=2 event=XNETCONNECT_MANAGER_ARMED' -and
            [int]$sa2Markers[2].Stage -eq 3 -and
            [string]$sa2Markers[2].Event -ceq
                'POSTCONNECT_XSA1_RETRANSMIT_CONSUMED_ACK_SENT' -and
            [string]$sa2Markers[2].Format -ceq
                '[AOT-RUNTIME-SA2][ACCEPT] seq=<seq> generation=<generation> stage=3 event=POSTCONNECT_XSA1_RETRANSMIT_CONSUMED_ACK_SENT') `
            "$($plan.Side) plan lost the exact generation-bound SA2 marker order."
        $optionNames = @($plan.ArgumentTokens | Where-Object {
            $_ -match '^--[^=]+='
        } | ForEach-Object {
            [regex]::Match($_, '^--(?<name>[^=]+)=').Groups['name'].Value
        })
        $aotNames = @($optionNames | Where-Object { $_ -like 'aot_*' })
        $expectedAot = @(
            'aot_runtime_peer_ipv4',
            'aot_runtime_sa2',
            'aot_runtime_leg_destination_repair',
            'aot_runtime_xport_control_load_repair')
        Assert-True ($aotNames.Count -eq 4 -and
            @($aotNames | Where-Object { $_ -notin $expectedAot }).Count -eq 0) `
            "$($plan.Side) plan escaped the four-option AoT boundary."
        Assert-True (@($optionNames | Group-Object |
            Where-Object Count -gt 1).Count -eq 0) `
            "$($plan.Side) plan contains duplicate options."
    }
    Assert-True ([int]$daddy.ArgumentCount -eq 16 -and
        [int]$daddy.OptionCount -eq 15 -and -not [bool]$daddy.InvertRightX) `
        'Daddy plan does not preserve the minimal non-inverted shape.'
    Assert-True ([int]$cj.ArgumentCount -eq 17 -and
        [int]$cj.OptionCount -eq 16 -and [bool]$cj.InvertRightX) `
        'CJ plan does not preserve the one-option right-X delta.'
    Assert-True ([string]$daddy.OwnHostAddress -ceq '127.17.17.17' -and
        [string]$daddy.PeerHostAddress -ceq '127.34.34.34' -and
        [string]$cj.OwnHostAddress -ceq '127.34.34.34' -and
        [string]$cj.PeerHostAddress -ceq '127.17.17.17') `
        'Runtime peer addresses were not cross-mapped.'

    $case = New-Fixture -Label 'profile-override'
    Assert-Throws -Label 'production profile override' `
        -Pattern 'reserved for synthetic tests' -Action {
            & $plannerPath -Side Daddy -ConfigPath $case.ConfigPath `
                -ProfileRoot $case.ProfileRoot
        }

    $case = New-Fixture -Label 'unsupported-aot'
    $templatePath = Join-Path $case.ProfileRoot 'daddy.arguments.template.txt'
    Write-Utf8NoBom -Path $templatePath -Text (
        (Get-Content -Raw -LiteralPath $templatePath).TrimEnd("`r", "`n") +
        ' --aot_sp_join=false')
    Set-FixtureSideTemplateHash -Fixture $case -Side Daddy `
        -Hash (Get-Sha256 -Path $templatePath)
    Assert-Throws -Label 'unsupported AoT option' -Pattern 'unsupported AoT option' `
        -Action { Invoke-Plan -Fixture $case -Side Daddy }

    $case = New-Fixture -Label 'exe-size'
    [IO.File]::WriteAllBytes((Join-Path $case.DaddyRig $case.XeniaFileName),
        [byte[]](1, 2, 3, 4))
    Assert-Throws -Label 'candidate executable size' -Pattern 'candidate executable size' `
        -Action { Invoke-Plan -Fixture $case -Side Daddy }

    $case = New-Fixture -Label 'exe-hash'
    $xeniaPath = Join-Path $case.DaddyRig $case.XeniaFileName
    $changedXeniaBytes = [IO.File]::ReadAllBytes($xeniaPath)
    $changedXeniaBytes[0] = $changedXeniaBytes[0] -bxor 0x01
    [IO.File]::WriteAllBytes($xeniaPath, $changedXeniaBytes)
    Assert-Throws -Label 'candidate executable hash' -Pattern 'candidate pin' `
        -Action { Invoke-Plan -Fixture $case -Side Daddy }

    $case = New-Fixture -Label 'patch-hash'
    $patchPath = Join-Path $case.DaddyRig `
        'patches\454108D8 - coop-bind-6000.patch.toml'
    Write-Utf8NoBom -Path $patchPath -Text (
        (Get-Content -Raw -LiteralPath $patchPath) + '# changed')
    Assert-Throws -Label 'changed patch' -Pattern 'patch hash mismatch' `
        -Action { Invoke-Plan -Fixture $case -Side Daddy }

    $case = New-Fixture -Label 'missing-patch'
    Remove-Item -LiteralPath (Join-Path $case.DaddyRig `
        'patches\454108D8 - coop-cod-unaddressed.patch.toml') -Force
    Assert-Throws -Label 'missing patch' -Pattern 'exactly three patch TOMLs' `
        -Action { Invoke-Plan -Fixture $case -Side Daddy }

    $case = New-Fixture -Label 'fourth-patch'
    Write-Utf8NoBom -Path (Join-Path $case.DaddyRig `
        'patches\454108D8 - unreviewed.patch.toml') -Text 'unreviewed'
    Assert-Throws -Label 'fourth patch' -Pattern 'exactly three patch TOMLs' `
        -Action { Invoke-Plan -Fixture $case -Side Daddy }

    $case = New-Fixture -Label 'template-hash'
    $templatePath = Join-Path $case.ProfileRoot 'daddy.arguments.template.txt'
    Write-Utf8NoBom -Path $templatePath -Text (
        (Get-Content -Raw -LiteralPath $templatePath) + ' ')
    Assert-Throws -Label 'template hash' -Pattern 'template hash mismatch' `
        -Action { Invoke-Plan -Fixture $case -Side Daddy }

    $case = New-Fixture -Label 'host-address'
    $text = (Get-Content -Raw -LiteralPath $case.ConfigPath).Replace(
        "HostAddress = '127.17.17.17'", "HostAddress = '127.17.17.18'")
    Write-Utf8NoBom -Path $case.ConfigPath -Text $text
    Assert-Throws -Label 'MAC-derived host address' -Pattern 'MAC-derived address' `
        -Action { Invoke-Plan -Fixture $case -Side Daddy }

    $case = New-Fixture -Label 'controller-route'
    $text = (Get-Content -Raw -LiteralPath $case.ConfigPath).Replace(
        "Controller = '0x1234/0x0002'", "Controller = '0x1234/0x0001'")
    Write-Utf8NoBom -Path $case.ConfigPath -Text $text
    Assert-Throws -Label 'duplicate controller' -Pattern 'distinct SDL' `
        -Action { Invoke-Plan -Fixture $case -Side Daddy }

    $case = New-Fixture -Label 'cpu-overlap'
    $text = (Get-Content -Raw -LiteralPath $case.ConfigPath).Replace(
        "CpuMask = '0000000C'", "CpuMask = '00000002'")
    Write-Utf8NoBom -Path $case.ConfigPath -Text $text
    Assert-Throws -Label 'CPU overlap' -Pattern 'CPU masks overlap' `
        -Action { Invoke-Plan -Fixture $case -Side Daddy }

    $case = New-Fixture -Label 'identity-suffix'
    $text = (Get-Content -Raw -LiteralPath $case.ConfigPath).Replace(
        "ProfileXuid = 'E000A1A152111111'",
        "ProfileXuid = 'E000A1A152999999'")
    Write-Utf8NoBom -Path $case.ConfigPath -Text $text
    Assert-Throws -Label 'XUID/MAC mismatch' -Pattern 'suffixes do not match' `
        -Action { Invoke-Plan -Fixture $case -Side Daddy }

    $case = New-Fixture -Label 'placeholder'
    $templatePath = Join-Path $case.ProfileRoot 'daddy.arguments.template.txt'
    Write-Utf8NoBom -Path $templatePath -Text (
        (Get-Content -Raw -LiteralPath $templatePath).TrimEnd("`r", "`n") +
        ' {{UNREVIEWED_ARG}}')
    Set-FixtureSideTemplateHash -Fixture $case -Side Daddy `
        -Hash (Get-Sha256 -Path $templatePath)
    Assert-Throws -Label 'unresolved placeholder' -Pattern 'unresolved placeholder' `
        -Action { Invoke-Plan -Fixture $case -Side Daddy }

    $case = New-Fixture -Label 'game-hash'
    $gameBytes = [IO.File]::ReadAllBytes($case.GamePath)
    $gameBytes[0] = $gameBytes[0] -bxor 0x01
    [IO.File]::WriteAllBytes($case.GamePath, $gameBytes)
    Assert-Throws -Label 'game hash' -Pattern 'game image hash' `
        -Action { Invoke-Plan -Fixture $case -Side Daddy }

    $case = New-Fixture -Label 'source-pin'
    $text = (Get-Content -Raw -LiteralPath $case.ProfilePath).Replace(
        'b8c0c49520e841a97309e7c742570c0a8769c4f6',
        '0000000000000000000000000000000000000000')
    Set-FixtureProfileText -Fixture $case -Text $text
    Assert-Throws -Label 'source pin' -Pattern 'source commit/tree pin' `
        -Action { Invoke-Plan -Fixture $case -Side Daddy }

    $case = New-Fixture -Label 'profile-schema-xenia-bytes'
    $xeniaBytesLine = [regex]::new('(?m)^\s*XeniaBytes\s*=\s*\d+\s*\r?\n')
    $text = $xeniaBytesLine.Replace(
        (Get-Content -Raw -LiteralPath $case.ProfilePath), '', 1)
    Set-FixtureProfileText -Fixture $case -Text $text
    Assert-Throws -Label 'profile XeniaBytes schema' `
        -Pattern 'Runtime-core profile keys differ' `
        -Action { Invoke-Plan -Fixture $case -Side Daddy }

    $case = New-Fixture -Label 'sa2-marker-order'
    $text = (Get-Content -Raw -LiteralPath $case.ProfilePath).Replace(
        'Stage = 2', 'Stage = 3')
    Set-FixtureProfileText -Fixture $case -Text $text
    Assert-Throws -Label 'SA2 acceptance marker order' `
        -Pattern 'SA2 acceptance marker mismatch' `
        -Action { Invoke-Plan -Fixture $case -Side Daddy }

    $case = New-Fixture -Label 'sa2-marker-schema'
    $text = (Get-Content -Raw -LiteralPath $case.ProfilePath).Replace(
        "            Stage = 1", "            Unknown = 'reject-me'`r`n            Stage = 1")
    Set-FixtureProfileText -Fixture $case -Text $text
    Assert-Throws -Label 'SA2 acceptance marker schema' `
        -Pattern 'SA2 acceptance marker 0 keys differ' `
        -Action { Invoke-Plan -Fixture $case -Side Daddy }

    Write-Host ('PASS: runtime-core offline launch plan sides=2 ' +
        'argument_shapes=16/17 aot_options=4 patches=3 ' +
        'synthetic_negative_gates=14 launch_capable=false runtime_tested=false ' +
        'game_hash=required runtime_gates=14 sa2_acceptance_markers=3')
} finally {
    foreach ($fixtureRoot in $fixtureRoots) {
        $resolved = [IO.Path]::GetFullPath($fixtureRoot)
        if (($resolved + '\').StartsWith(
                $tempPrefix, [StringComparison]::OrdinalIgnoreCase) -and
            (Test-Path -LiteralPath $resolved)) {
            Remove-Item -LiteralPath $resolved -Recurse -Force
        }
    }
}
