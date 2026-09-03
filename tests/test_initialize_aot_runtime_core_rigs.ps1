[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$seederPath = Join-Path $repoRoot `
    'tools\runtime\Initialize-AotRuntimeCoreRigs.ps1'
$productionProfileRoot = Join-Path $repoRoot `
    'profiles\b19-runtime-core-acceptance'
$localApplicationDataRoot = [IO.Path]::GetFullPath(
    [Environment]::GetFolderPath(
        [Environment+SpecialFolder]::LocalApplicationData)).TrimEnd('\')
$trustedSyntheticRoot = [IO.Path]::GetFullPath((Join-Path `
    $localApplicationDataRoot 'Temp')).TrimEnd('\')
$trustedSyntheticPrefix = $trustedSyntheticRoot + '\'
if ([string]::IsNullOrWhiteSpace($localApplicationDataRoot) -or
    [string]::Equals([IO.Path]::GetDirectoryName($trustedSyntheticRoot),
        $localApplicationDataRoot,
        [StringComparison]::OrdinalIgnoreCase) -eq $false -or
    -not (Test-Path -LiteralPath $trustedSyntheticRoot -PathType Container)) {
    throw 'Trusted test root is not the direct LocalApplicationData\Temp child.'
}
$fixtureRoots = [Collections.Generic.List[string]]::new()

function Assert-True {
    param(
        [Parameter(Mandatory = $true)][bool]$Condition,
        [Parameter(Mandatory = $true)][string]$Message
    )
    if (-not $Condition) { throw $Message }
}

function Assert-Equal {
    param(
        [Parameter(Mandatory = $true)]$Actual,
        [Parameter(Mandatory = $true)]$Expected,
        [Parameter(Mandatory = $true)][string]$Message
    )
    if ($Actual -cne $Expected) {
        throw "$Message actual=[$Actual] expected=[$Expected]"
    }
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
    if ($caught.Exception.Message -notmatch $Pattern) {
        throw ("$Label failed for the wrong reason: " +
            $caught.Exception.Message)
    }
}

function Get-Sha256 {
    param([Parameter(Mandatory = $true)][string]$Path)
    return (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash
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

function Write-ProcessInventory {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [string[]]$BeforeFirstWrite = @(),
        [string[]]$BeforePublishPreparation = @(),
        [string[]]$FinalBeforePublish = @()
    )
    $first = @($BeforeFirstWrite | ForEach-Object {
        ConvertTo-Psd1Literal -Value $_
    }) -join ', '
    $second = @($BeforePublishPreparation | ForEach-Object {
        ConvertTo-Psd1Literal -Value $_
    }) -join ', '
    $third = @($FinalBeforePublish | ForEach-Object {
        ConvertTo-Psd1Literal -Value $_
    }) -join ', '
    $text = @"
@{
    SchemaVersion = 1
    BeforeFirstWrite = @($first)
    BeforePublishPreparation = @($second)
    FinalBeforePublish = @($third)
}
"@
    Write-Utf8NoBom -Path $Path -Text $text
}

function New-Fixture {
    param([Parameter(Mandatory = $true)][string]$Label)

    $root = Join-Path $trustedSyntheticRoot ('AoT runtime seed {0} {1}' -f
        $Label, [Guid]::NewGuid().ToString('N'))
    $root = [IO.Path]::GetFullPath($root)
    if (-not ($root + '\').StartsWith(
            $trustedSyntheticPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Synthetic seeder fixture escaped the trusted Known Folder root.'
    }
    [void][IO.Directory]::CreateDirectory($root)
    $fixtureRoots.Add($root)

    $profileRoot = Join-Path $root 'acceptance profile'
    Copy-Item -LiteralPath $productionProfileRoot -Destination $profileRoot `
        -Recurse
    $installRoot = Join-Path $root 'portable install'
    $sourceRoot = Join-Path $root 'source inputs'
    [void][IO.Directory]::CreateDirectory($installRoot)
    [void][IO.Directory]::CreateDirectory($sourceRoot)

    $candidatePath = Join-Path $sourceRoot 'xenia_fixture_candidate.exe'
    $candidateBytes = [Text.Encoding]::ASCII.GetBytes(
        'synthetic xenia runtime-core candidate bytes')
    [IO.File]::WriteAllBytes($candidatePath, $candidateBytes)
    $candidateHash = Get-Sha256 -Path $candidatePath

    $profilePath = Join-Path $profileRoot 'profile.psd1'
    $profileText = Get-Content -Raw -LiteralPath $profilePath
    $updatedText = $profileText.Replace(
        'E0AE2C785BC19637E83019FE921E0D3CEE83B229D1CDF9B82F6508A50336C629',
        $candidateHash)
    $updatedText = [regex]::Replace($updatedText,
        '(?m)^(\s*XeniaBytes\s*=\s*)17942016\s*$',
        '${1}' + $candidateBytes.Length, 1)
    if ($updatedText -ceq $profileText) {
        throw 'Could not install synthetic executable pins into profile fixture.'
    }
    Write-Utf8NoBom -Path $profilePath -Text $updatedText

    $inventoryPath = Join-Path $root 'process inventory.psd1'
    Write-ProcessInventory -Path $inventoryPath
    return [pscustomobject]@{
        Root = $root
        ProfileRoot = $profileRoot
        ProfilePath = $profilePath
        InstallRoot = $installRoot
        CandidatePath = $candidatePath
        CandidateBytes = $candidateBytes
        CandidateHash = $candidateHash
        InventoryPath = $inventoryPath
        XeniaFileName = 'xenia_canary_netplay.exe'
        StagingName = '.aot-runtime-core-rigs-staging-11111111111111111111111111111111'
    }
}

function Invoke-Seeder {
    param(
        [Parameter(Mandatory = $true)][object]$Fixture,
        [string]$InstallRoot = '',
        [string]$CandidatePath = '',
        [string]$ProfileRoot = '',
        [string]$XeniaFileName = '',
        [string]$ProcessInventoryPath = '',
        [ValidateSet('None', 'CreateRigsDestination',
            'InjectUnknownStagingFileThenFail')]
        [string]$BeforePublishAction = 'None',
        [ValidateSet('None', 'PrecreateDaddyDirectory',
            'PrecreateDaddyJunction')]
        [string]$ChildClaimAction = 'None',
        [string]$ChildHijackTarget = ''
    )
    if ([string]::IsNullOrWhiteSpace($InstallRoot)) {
        $InstallRoot = $Fixture.InstallRoot
    }
    if ([string]::IsNullOrWhiteSpace($CandidatePath)) {
        $CandidatePath = $Fixture.CandidatePath
    }
    if ([string]::IsNullOrWhiteSpace($ProfileRoot)) {
        $ProfileRoot = $Fixture.ProfileRoot
    }
    if ([string]::IsNullOrWhiteSpace($XeniaFileName)) {
        $XeniaFileName = $Fixture.XeniaFileName
    }
    if ([string]::IsNullOrWhiteSpace($ProcessInventoryPath)) {
        $ProcessInventoryPath = $Fixture.InventoryPath
    }
    $arguments = @{
        InstallRoot = $InstallRoot
        CandidateXeniaPath = $CandidatePath
        XeniaFileName = $XeniaFileName
        ProfileRoot = $ProfileRoot
        SyntheticFixture = $true
        SyntheticProcessInventoryPath = $ProcessInventoryPath
        SyntheticStagingName = $Fixture.StagingName
        SyntheticBeforePublishAction = $BeforePublishAction
        SyntheticChildClaimAction = $ChildClaimAction
    }
    if (-not [string]::IsNullOrWhiteSpace($ChildHijackTarget)) {
        $arguments.SyntheticChildHijackTarget = $ChildHijackTarget
    }
    return & $seederPath @arguments
}

function Get-RelativeFileNames {
    param([Parameter(Mandatory = $true)][string]$Root)
    return @(Get-ChildItem -LiteralPath $Root -File -Force -Recurse |
        ForEach-Object {
            $_.FullName.Substring($Root.Length).TrimStart('\')
        } | Sort-Object)
}

function Get-ExactTreeState {
    param([Parameter(Mandatory = $true)][string]$Root)
    $rows = [Collections.Generic.List[string]]::new()
    foreach ($item in @(Get-ChildItem -LiteralPath $Root -Force -Recurse |
            Sort-Object FullName)) {
        $relative = $item.FullName.Substring($Root.Length).TrimStart('\')
        if ($item.PSIsContainer) {
            $rows.Add(('D|{0}|{1}' -f $relative, [int]$item.Attributes))
        } else {
            $rows.Add(('F|{0}|{1}|{2}|{3}' -f $relative,
                [int]$item.Attributes, [int64]$item.Length,
                (Get-Sha256 -Path $item.FullName)))
        }
    }
    return @($rows) -join "`n"
}

function Assert-NoStagingTree {
    param(
        [Parameter(Mandatory = $true)][string]$InstallRoot,
        [Parameter(Mandatory = $true)][string]$Label
    )
    $staging = @(Get-ChildItem -LiteralPath $InstallRoot -Force |
        Where-Object {
            $_.Name -like '.aot-runtime-core-rigs-staging-*'
        })
    if ($staging.Count -ne 0) {
        throw "$Label left $($staging.Count) staging tree(s)."
    }
}

function Get-StagingTrees {
    param([Parameter(Mandatory = $true)][string]$InstallRoot)
    return @(Get-ChildItem -LiteralPath $InstallRoot -Force -Directory |
        Where-Object {
            $_.Name -like '.aot-runtime-core-rigs-staging-*'
        })
}

function Assert-OneIntentionallyRetainedStagingTree {
    param(
        [Parameter(Mandatory = $true)][string]$InstallRoot,
        [Parameter(Mandatory = $true)][string]$Label,
        [Parameter(Mandatory = $true)][bool]$ExpectHidden,
        [Parameter(Mandatory = $true)][bool]$ExpectOwnerMarker
    )
    $staging = @(Get-StagingTrees -InstallRoot $InstallRoot)
    Assert-Equal -Actual $staging.Count -Expected 1 `
        -Message "$Label did not retain exactly one staging tree."
    $isHidden = ($staging[0].Attributes -band
        [IO.FileAttributes]::Hidden) -ne 0
    Assert-True -Condition ($isHidden -eq $ExpectHidden) `
        -Message "$Label retained staging Hidden state differs from policy."
    $hasOwnerMarker = Test-Path -LiteralPath `
        (Join-Path $staging[0].FullName '.aot-runtime-core-owner') `
        -PathType Leaf
    Assert-True -Condition ($hasOwnerMarker -eq $ExpectOwnerMarker) `
        -Message "$Label retained staging owner-marker state differs from policy."
    return $staging[0]
}

function Assert-NoRigsOrStaging {
    param(
        [Parameter(Mandatory = $true)][string]$InstallRoot,
        [Parameter(Mandatory = $true)][string]$Label
    )
    Assert-True -Condition (-not (Test-Path -LiteralPath `
        (Join-Path $InstallRoot 'rigs'))) `
        -Message "$Label unexpectedly published rigs."
    Assert-NoStagingTree -InstallRoot $InstallRoot -Label $Label
}

function Remove-FixtureRoot {
    param([Parameter(Mandatory = $true)][string]$Path)
    $resolved = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    if (-not (($resolved + '\').StartsWith(
            $trustedSyntheticPrefix, [StringComparison]::OrdinalIgnoreCase))) {
        throw "Refusing fixture cleanup outside trusted Known Folder root: $resolved"
    }
    if (-not (Test-Path -LiteralPath $resolved -PathType Container)) { return }
    $reparseItems = @(Get-ChildItem -LiteralPath $resolved -Force -Recurse |
        Where-Object {
            ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0
        } | Sort-Object { $_.FullName.Length } -Descending)
    foreach ($item in $reparseItems) {
        if ($item.PSIsContainer) {
            [IO.Directory]::Delete($item.FullName, $false)
        } else {
            [IO.File]::Delete($item.FullName)
        }
    }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}

if (-not (Test-Path -LiteralPath $seederPath -PathType Leaf)) {
    throw "Seeder under test is missing: $seederPath"
}
$seederSource = Get-Content -Raw -LiteralPath $seederPath
foreach ($requiredSourceContract in @(
        '[IO.FileShare]::Read',
        'CreateDirectoryW',
        '.aot-runtime-core-owner',
        '[IO.Directory]::Move($stagingRoot, $rigsRoot)',
        'FinalBeforePublish',
        'ZERO_LIVE_XENIA_PROCESSES gate failed',
        'PRODUCTION_RIG_SEEDING_CLOSURE_DEFERRED',
        'INERT_FIRST_TIME_RUNTIME_CORE_RIG_SEED')) {
    if ($seederSource.IndexOf($requiredSourceContract,
            [StringComparison]::Ordinal) -lt 0) {
        throw "Seeder source lost required contract: $requiredSourceContract"
    }
}
$normalizedSeederSource = $seederSource.Replace("`r`n", "`n").Replace(
    "`r", "`n")
$earlyProductionClosure = @'
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (-not $SyntheticFixture) {
    throw 'PRODUCTION_RIG_SEEDING_CLOSURE_DEFERRED'
}
Import-Module Microsoft.PowerShell.Utility -ErrorAction Stop
'@
if ($normalizedSeederSource.IndexOf($earlyProductionClosure,
        [StringComparison]::Ordinal) -lt 0 -or
    [regex]::Matches($normalizedSeederSource,
        "'PRODUCTION_RIG_SEEDING_CLOSURE_DEFERRED'").Count -ne 1) {
    throw 'Production closure must be the exact first guard after strict/error setup.'
}
foreach ($forbiddenSourceContract in 'Start-Process', 'Invoke-Expression',
        'Start-Job') {
    if ($seederSource -match ("(?m)^\s*" +
            [regex]::Escape($forbiddenSourceContract) + '\b')) {
        throw "Seeder must not execute runtime work: $forbiddenSourceContract"
    }
}
if ($seederSource -match
        '(?i)Directory\]::Delete\(\$Path\s*,\s*\$true\)' -or
    $seederSource -match '(?im)^\s*Remove-Item\b.*-Recurse\b') {
    throw 'Seeder cleanup must remain finite, subset-closed, and non-recursive.'
}
$cleanupStart = $seederSource.IndexOf(
    'function Remove-ValidatedRunOwnedStagingTree',
    [StringComparison]::Ordinal)
$cleanupEnd = $seederSource.IndexOf('$trustedSyntheticRoot = $null',
    $cleanupStart, [StringComparison]::Ordinal)
if ($cleanupStart -lt 0 -or $cleanupEnd -le $cleanupStart) {
    throw 'Could not isolate the run-owned cleanup function source.'
}
$cleanupSource = $seederSource.Substring($cleanupStart,
    $cleanupEnd - $cleanupStart)
$knownFileDelete = $cleanupSource.IndexOf(
    '[IO.File]::Delete((Join-Path $Path $relative))',
    [StringComparison]::Ordinal)
$knownDirectoryDelete = $cleanupSource.IndexOf(
    '[IO.Directory]::Delete($directoryPath, $false)',
    [StringComparison]::Ordinal)
$ownerDispose = $cleanupSource.IndexOf('$OwnerMarkerStream.Dispose()',
    [StringComparison]::Ordinal)
$ownerMarkerDelete = $cleanupSource.IndexOf(
    '[IO.File]::Delete($OwnerMarkerPath)', [StringComparison]::Ordinal)
$rootDelete = $cleanupSource.IndexOf(
    '[IO.Directory]::Delete($Path, $false)', [StringComparison]::Ordinal)
if ($knownFileDelete -lt 0 -or $knownDirectoryDelete -lt 0 -or
    $ownerDispose -lt 0 -or $ownerMarkerDelete -lt 0 -or
    $rootDelete -lt 0 -or
    -not ($knownFileDelete -lt $ownerDispose -and
        $knownDirectoryDelete -lt $ownerDispose -and
        $ownerDispose -lt $ownerMarkerDelete -and
        $ownerMarkerDelete -lt $rootDelete)) {
    throw 'Cleanup lost the retained-owner-handle deletion ordering contract.'
}
$stagingStart = $seederSource.IndexOf(
    'New-AtomicStagingDirectory -Path $stagingRoot',
    [StringComparison]::Ordinal)
$sideClaim = $seederSource.IndexOf(
    'New-AtomicValidatedChildDirectory -Path $sideRoot', $stagingStart,
    [StringComparison]::Ordinal)
$patchClaim = $seederSource.IndexOf(
    'New-AtomicValidatedChildDirectory `', $sideClaim + 1,
    [StringComparison]::Ordinal)
$ownerMarkerOpen = $seederSource.IndexOf(
    '$ownerMarkerStream = Open-NewOwnerMarker', $stagingStart,
    [StringComparison]::Ordinal)
$firstSeedCopy = $seederSource.IndexOf(
    'Copy-LockedStreamToNewFile -Source $candidateStream', $stagingStart,
    [StringComparison]::Ordinal)
if ($stagingStart -lt 0 -or $sideClaim -lt 0 -or $patchClaim -lt 0 -or
    $ownerMarkerOpen -lt 0 -or $firstSeedCopy -lt 0 -or
    -not ($sideClaim -lt $patchClaim -and
        $patchClaim -lt $ownerMarkerOpen -and
        $ownerMarkerOpen -lt $firstSeedCopy)) {
    throw 'Descendant directories must be atomically claimed before any run-owned file.'
}

try {
    $oldTemp = $env:TEMP
    $oldTmp = $env:TMP
    try {
        $fixture = New-Fixture -Label 'poisoned-environment-contained'
        $env:TEMP = 'C:\'
        $env:TMP = 'C:\'
        $poisonedReceipt = Invoke-Seeder -Fixture $fixture
        Assert-True -Condition ($poisonedReceipt.RigsRoot.StartsWith(
            $trustedSyntheticPrefix,
            [StringComparison]::OrdinalIgnoreCase)) `
            -Message 'Poisoned TEMP/TMP redirected a synthetic publish.'

        $fixture = New-Fixture -Label 'poisoned-environment-root-reject'
        Assert-Throws -Label 'poisoned TEMP/TMP volume-root escape' `
            -Pattern 'InstallRoot must stay under trusted LocalApplicationData\\Temp' `
            -Action { Invoke-Seeder -Fixture $fixture -InstallRoot 'C:\' }
        Assert-NoRigsOrStaging -InstallRoot $fixture.InstallRoot `
            -Label 'Poisoned environment root rejection'
    } finally {
        if ($null -eq $oldTemp) {
            Remove-Item Env:TEMP -ErrorAction SilentlyContinue
        } else {
            $env:TEMP = $oldTemp
        }
        if ($null -eq $oldTmp) {
            Remove-Item Env:TMP -ErrorAction SilentlyContinue
        } else {
            $env:TMP = $oldTmp
        }
    }

    $fixture = New-Fixture -Label 'owner-marker-parent-lock'
    $ownerLockRoot = Join-Path $fixture.InstallRoot 'owner lock probe'
    $ownerLockSwap = Join-Path $fixture.InstallRoot 'owner lock swapped'
    [void][IO.Directory]::CreateDirectory($ownerLockRoot)
    $ownerLockMarker = Join-Path $ownerLockRoot '.aot-runtime-core-owner'
    $ownerLockStream = [IO.File]::Open($ownerLockMarker,
        [IO.FileMode]::CreateNew, [IO.FileAccess]::ReadWrite,
        [IO.FileShare]::Read)
    try {
        $ownerLockStream.WriteByte(0x41)
        $ownerLockStream.Flush($true)
        $moveFailure = $null
        try {
            [IO.Directory]::Move($ownerLockRoot, $ownerLockSwap)
        } catch {
            $moveFailure = $_
        }
        Assert-True -Condition ($null -ne $moveFailure) `
            -Message 'An open owner marker did not block its parent path move.'
        $moveException = $moveFailure.Exception
        $moveInnerException = $moveException.InnerException
        $expectedMoveFailure = ($moveException -is [IO.IOException] -or
            $moveException -is [UnauthorizedAccessException] -or
            $moveInnerException -is [IO.IOException] -or
            $moveInnerException -is [UnauthorizedAccessException])
        Assert-True -Condition $expectedMoveFailure `
            -Message 'Owner-marker parent move failed for an unexpected reason.'
        Assert-True -Condition ((Test-Path -LiteralPath $ownerLockRoot `
                -PathType Container) -and
            -not (Test-Path -LiteralPath $ownerLockSwap)) `
            -Message 'Owner-marker lock did not retain the original parent identity.'
    } finally {
        $ownerLockStream.Dispose()
        foreach ($root in $ownerLockRoot, $ownerLockSwap) {
            $marker = Join-Path $root '.aot-runtime-core-owner'
            if (Test-Path -LiteralPath $marker -PathType Leaf) {
                [IO.File]::Delete($marker)
            }
            if (Test-Path -LiteralPath $root -PathType Container) {
                [IO.Directory]::Delete($root, $false)
            }
        }
    }

    $fixture = New-Fixture -Label 'happy'
    $sourceHashBefore = Get-Sha256 -Path $fixture.CandidatePath
    $readLock = [IO.File]::Open($fixture.CandidatePath,
        [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    try {
        $writeWasBlocked = $false
        try {
            $unexpectedWriter = [IO.File]::Open($fixture.CandidatePath,
                [IO.FileMode]::Open, [IO.FileAccess]::Write,
                [IO.FileShare]::ReadWrite)
            $unexpectedWriter.Dispose()
        } catch [IO.IOException] {
            $writeWasBlocked = $true
        }
        Assert-True -Condition $writeWasBlocked `
            -Message 'FileShare.Read did not behaviorally block source mutation.'
    } finally {
        $readLock.Dispose()
    }
    $receipt = Invoke-Seeder -Fixture $fixture
    Assert-True -Condition ($receipt.Published -eq $true) `
        -Message 'Happy path did not return a published receipt.'
    Assert-Equal -Actual $receipt.Operation `
        -Expected 'INERT_FIRST_TIME_RUNTIME_CORE_RIG_SEED' `
        -Message 'Receipt operation changed.'
    Assert-Equal -Actual $receipt.ProcessInventoryChecks -Expected 3 `
        -Message 'Seeder did not perform all three zero-live checks.'
    Assert-Equal -Actual $receipt.AtomicDescendantDirectoryClaims -Expected 4 `
        -Message 'Seeder did not atomically claim all four descendant directories.'
    Assert-Equal -Actual $receipt.FinalProcessInventoryPhase `
        -Expected 'FinalBeforePublish' `
        -Message 'Receipt lost its final process-inventory boundary.'
    Assert-True -Condition $receipt.OwnerTokenDisarmedBeforePublish `
        -Message 'Receipt did not record owner-token disarm before publish.'
    Assert-True -Condition (-not $receipt.PublishedRigsRootHidden -and
        -not $receipt.PublishedRigsRootReparsePoint) `
        -Message 'Receipt did not prove a normal visible rigs root.'
    Assert-Equal -Actual $receipt.XeniaSha256 -Expected $fixture.CandidateHash `
        -Message 'Receipt candidate hash changed.'
    Assert-Equal -Actual $receipt.XeniaBytes `
        -Expected ([int64]$fixture.CandidateBytes.Length) `
        -Message 'Receipt candidate length changed.'
    Assert-Equal -Actual $receipt.FileCount -Expected 12 `
        -Message 'Receipt must cover exactly twelve seeded files.'
    Assert-True -Condition (-not $receipt.PlayerKitReady -and
        -not $receipt.RuntimeTested -and -not $receipt.LaunchCapable) `
        -Message 'Inert seed receipt overstated runtime readiness.'
    Assert-Equal -Actual (Get-Sha256 -Path $fixture.CandidatePath) `
        -Expected $sourceHashBefore -Message 'Seeder changed its candidate source.'

    $rigsRoot = Join-Path $fixture.InstallRoot 'rigs'
    $rigsRootInfo = Get-Item -LiteralPath $rigsRoot -Force
    Assert-True -Condition (($rigsRootInfo.Attributes -band
        ([IO.FileAttributes]::Hidden -bor
            [IO.FileAttributes]::ReparsePoint)) -eq 0) `
        -Message 'Published rigs root is hidden or a reparse point.'
    $expectedFiles = [Collections.Generic.List[string]]::new()
    $patchNames = @(Get-ChildItem -LiteralPath `
        (Join-Path $fixture.ProfileRoot 'patches') -File | Select-Object `
        -ExpandProperty Name | Sort-Object)
    foreach ($side in 'cj', 'daddy') {
        $expectedFiles.Add("$side\$($fixture.XeniaFileName)")
        $expectedFiles.Add("$side\inject.txt")
        $expectedFiles.Add("$side\portable.txt")
        foreach ($patchName in $patchNames) {
            $expectedFiles.Add("$side\patches\$patchName")
        }
    }
    $actualFiles = @(Get-RelativeFileNames -Root $rigsRoot)
    $expectedFileNames = @($expectedFiles | Sort-Object)
    Assert-True -Condition (@(Compare-Object -ReferenceObject $expectedFileNames `
        -DifferenceObject $actualFiles -SyncWindow 0).Count -eq 0) `
        -Message 'Happy path tree closure changed.'
    Assert-Equal -Actual $actualFiles.Count -Expected 12 `
        -Message 'Happy path did not seed exactly twelve files.'
    foreach ($side in 'daddy', 'cj') {
        $sideRoot = Join-Path $rigsRoot $side
        $portable = Join-Path $sideRoot 'portable.txt'
        $inject = Join-Path $sideRoot 'inject.txt'
        Assert-Equal -Actual (Get-Item -LiteralPath $portable).Length `
            -Expected ([int64]0) -Message "$side portable marker is not empty."
        $injectBytes = [IO.File]::ReadAllBytes($inject)
        Assert-Equal -Actual $injectBytes.Length -Expected 4 `
            -Message "$side inject marker length changed."
        Assert-Equal -Actual ([Text.Encoding]::ASCII.GetString($injectBytes)) `
            -Expected 'NONE' -Message "$side inject marker is not ASCII NONE."
        Assert-Equal -Actual (Get-Sha256 -Path `
            (Join-Path $sideRoot $fixture.XeniaFileName)) `
            -Expected $fixture.CandidateHash `
            -Message "$side executable copy hash changed."
        foreach ($patchName in $patchNames) {
            Assert-Equal -Actual (Get-Sha256 -Path `
                (Join-Path (Join-Path $sideRoot 'patches') $patchName)) `
                -Expected (Get-Sha256 -Path `
                    (Join-Path (Join-Path $fixture.ProfileRoot 'patches') `
                        $patchName)) `
                -Message "$side patch copy hash changed: $patchName"
        }
        foreach ($forbidden in 'config.toml', 'profile', 'content', 'saves') {
            Assert-True -Condition (-not (Test-Path -LiteralPath `
                (Join-Path $sideRoot $forbidden))) `
                -Message "$side inert seed created forbidden state: $forbidden"
        }
    }
    Assert-NoStagingTree -InstallRoot $fixture.InstallRoot -Label 'Happy path'

    $fixture = New-Fixture -Label 'live-first'
    Write-ProcessInventory -Path $fixture.InventoryPath `
        -BeforeFirstWrite @('notepad.exe', 'xenia_canary_netplay.exe')
    Assert-Throws -Label 'live Xenia before first write' `
        -Pattern 'ZERO_LIVE_XENIA_PROCESSES.*BeforeFirstWrite' `
        -Action { Invoke-Seeder -Fixture $fixture }
    Assert-NoRigsOrStaging -InstallRoot $fixture.InstallRoot `
        -Label 'First process check failure'

    $fixture = New-Fixture -Label 'live-preparation'
    Write-ProcessInventory -Path $fixture.InventoryPath `
        -BeforePublishPreparation @('xenia_fixture_candidate.exe')
    Assert-Throws -Label 'live Xenia before publish preparation' `
        -Pattern 'ZERO_LIVE_XENIA_PROCESSES.*BeforePublishPreparation' `
        -Action { Invoke-Seeder -Fixture $fixture }
    Assert-NoRigsOrStaging -InstallRoot $fixture.InstallRoot `
        -Label 'Second process check token-bound cleanup'

    $fixture = New-Fixture -Label 'live-final'
    Write-ProcessInventory -Path $fixture.InventoryPath `
        -FinalBeforePublish @('xenia_fixture_candidate.exe')
    Assert-Throws -Label 'live Xenia at final publish boundary' `
        -Pattern 'intentionally retained.*ZERO_LIVE_XENIA_PROCESSES.*FinalBeforePublish' `
        -Action { Invoke-Seeder -Fixture $fixture }
    Assert-True -Condition (-not (Test-Path -LiteralPath `
        (Join-Path $fixture.InstallRoot 'rigs'))) `
        -Message 'Final process check failure published rigs.'
    $null = Assert-OneIntentionallyRetainedStagingTree `
        -InstallRoot $fixture.InstallRoot -Label 'Final process check failure' `
        -ExpectHidden $false -ExpectOwnerMarker $false

    $fixture = New-Fixture -Label 'existing-rigs'
    $existingRigs = Join-Path $fixture.InstallRoot 'rigs'
    [void][IO.Directory]::CreateDirectory($existingRigs)
    $sentinel = Join-Path $existingRigs 'preserve.me'
    [IO.File]::WriteAllText($sentinel, 'keep')
    Assert-Throws -Label 'preexisting entire rigs path' `
        -Pattern 'entire InstallRoot\\rigs path.*already exists' `
        -Action { Invoke-Seeder -Fixture $fixture }
    Assert-Equal -Actual (Get-Content -Raw -LiteralPath $sentinel) `
        -Expected 'keep' -Message 'Existing rigs sentinel was altered.'
    Assert-NoStagingTree -InstallRoot $fixture.InstallRoot `
        -Label 'Existing rigs rejection'

    $fixture = New-Fixture -Label 'ordinary-stage-hijack'
    $foreignStage = Join-Path $fixture.InstallRoot $fixture.StagingName
    [void][IO.Directory]::CreateDirectory($foreignStage)
    $foreignSentinel = Join-Path $foreignStage 'foreign-state.txt'
    [IO.File]::WriteAllText($foreignSentinel, 'do not delete')
    Assert-Throws -Label 'precreated ordinary staging hijack' `
        -Pattern 'Atomic CreateDirectoryW staging claim failed' `
        -Action { Invoke-Seeder -Fixture $fixture }
    Assert-Equal -Actual (Get-Content -Raw -LiteralPath $foreignSentinel) `
        -Expected 'do not delete' `
        -Message 'Seeder deleted or changed a foreign ordinary staging tree.'
    Assert-True -Condition (-not (Test-Path -LiteralPath `
        (Join-Path $fixture.InstallRoot 'rigs'))) `
        -Message 'Ordinary staging hijack published rigs.'

    $fixture = New-Fixture -Label 'junction-stage-hijack'
    $foreignTarget = Join-Path $fixture.Root 'foreign junction target'
    $foreignStage = Join-Path $fixture.InstallRoot $fixture.StagingName
    [void][IO.Directory]::CreateDirectory($foreignTarget)
    $foreignSentinel = Join-Path $foreignTarget 'foreign-state.txt'
    [IO.File]::WriteAllText($foreignSentinel, 'do not follow')
    try {
        $null = New-Item -ItemType Junction -Path $foreignStage `
            -Target $foreignTarget
        Assert-Throws -Label 'precreated junction staging hijack' `
            -Pattern 'Atomic CreateDirectoryW staging claim failed' `
            -Action { Invoke-Seeder -Fixture $fixture }
        Assert-Equal -Actual (Get-Content -Raw -LiteralPath $foreignSentinel) `
            -Expected 'do not follow' `
            -Message 'Seeder followed or changed a foreign staging junction.'
        Assert-True -Condition (-not (Test-Path -LiteralPath `
            (Join-Path $fixture.InstallRoot 'rigs'))) `
            -Message 'Junction staging hijack published rigs.'
    } finally {
        if (Test-Path -LiteralPath $foreignStage) {
            $foreignStageItem = Get-Item -LiteralPath $foreignStage -Force
            if (($foreignStageItem.Attributes -band
                    [IO.FileAttributes]::ReparsePoint) -eq 0) {
                throw 'Refusing test cleanup because staging junction lost identity.'
            }
            [IO.Directory]::Delete($foreignStage, $false)
        }
    }

    $fixture = New-Fixture -Label 'ordinary-child-hijack'
    Assert-Throws -Label 'precreated ordinary child-directory hijack' `
        -Pattern ('cryptographic owner token.*intentionally retained.*' +
            'Atomic descendant CreateDirectoryW claim failed') `
        -Action { Invoke-Seeder -Fixture $fixture `
            -ChildClaimAction PrecreateDaddyDirectory }
    Assert-True -Condition (-not (Test-Path -LiteralPath `
        (Join-Path $fixture.InstallRoot 'rigs'))) `
        -Message 'Ordinary child-directory hijack published rigs.'
    $retainedChildStage = Assert-OneIntentionallyRetainedStagingTree `
        -InstallRoot $fixture.InstallRoot `
        -Label 'Ordinary child-directory hijack' `
        -ExpectHidden $true -ExpectOwnerMarker $false
    $foreignChildSentinel = Join-Path $retainedChildStage.FullName `
        'daddy\foreign-child-sentinel.txt'
    Assert-Equal -Actual (Get-Content -Raw -LiteralPath `
        $foreignChildSentinel) -Expected 'foreign-child' `
        -Message 'Ordinary child-directory hijack sentinel was changed.'
    $ordinaryChildFiles = @(Get-RelativeFileNames `
        -Root $retainedChildStage.FullName)
    Assert-Equal -Actual $ordinaryChildFiles.Count -Expected 1 `
        -Message 'Ordinary child-directory hijack received a seeded file.'
    Assert-Equal -Actual $ordinaryChildFiles[0] `
        -Expected 'daddy\foreign-child-sentinel.txt' `
        -Message 'Ordinary child-directory hijack tree closure changed.'

    $fixture = New-Fixture -Label 'junction-child-hijack'
    $foreignChildTarget = Join-Path $fixture.Root `
        'foreign child junction target'
    [void][IO.Directory]::CreateDirectory($foreignChildTarget)
    $foreignChildTargetSentinel = Join-Path $foreignChildTarget `
        'foreign-target-sentinel.txt'
    [IO.File]::WriteAllText($foreignChildTargetSentinel, 'do not follow child')
    $retainedChildJunction = $null
    try {
        Assert-Throws -Label 'precreated child-junction hijack' `
            -Pattern ('cryptographic owner token.*intentionally retained.*' +
                'Atomic descendant CreateDirectoryW claim failed') `
            -Action { Invoke-Seeder -Fixture $fixture `
                -ChildClaimAction PrecreateDaddyJunction `
                -ChildHijackTarget $foreignChildTarget }
        Assert-True -Condition (-not (Test-Path -LiteralPath `
            (Join-Path $fixture.InstallRoot 'rigs'))) `
            -Message 'Child-junction hijack published rigs.'
        $retainedChildStage = Assert-OneIntentionallyRetainedStagingTree `
            -InstallRoot $fixture.InstallRoot `
            -Label 'Child-junction hijack' `
            -ExpectHidden $true -ExpectOwnerMarker $false
        $retainedChildJunction = Join-Path $retainedChildStage.FullName 'daddy'
        $retainedChildJunctionInfo = Get-Item -LiteralPath `
            $retainedChildJunction -Force
        Assert-True -Condition (($retainedChildJunctionInfo.Attributes -band
                [IO.FileAttributes]::ReparsePoint) -ne 0) `
            -Message 'Child-junction hijack did not retain its reparse identity.'
        Assert-Equal -Actual (Get-Content -Raw -LiteralPath `
            $foreignChildTargetSentinel) -Expected 'do not follow child' `
            -Message 'Seeder followed or changed the child-junction target.'
        $targetFiles = @(Get-RelativeFileNames -Root $foreignChildTarget)
        Assert-Equal -Actual $targetFiles.Count -Expected 1 `
            -Message 'Seeder wrote a file through the child junction.'
        Assert-Equal -Actual $targetFiles[0] `
            -Expected 'foreign-target-sentinel.txt' `
            -Message 'Child-junction target closure changed.'
    } finally {
        if ($null -ne $retainedChildJunction -and
            (Test-Path -LiteralPath $retainedChildJunction)) {
            $junctionInfo = Get-Item -LiteralPath $retainedChildJunction -Force
            if (($junctionInfo.Attributes -band
                    [IO.FileAttributes]::ReparsePoint) -eq 0) {
                throw 'Refusing test cleanup because the child junction lost identity.'
            }
            [IO.Directory]::Delete($retainedChildJunction, $false)
        }
    }

    $fixture = New-Fixture -Label 'publish-race'
    Assert-Throws -Label 'atomic destination race' `
        -Pattern 'intentionally retained.*Atomic rigs publish failed without overwrite' `
        -Action { Invoke-Seeder -Fixture $fixture `
            -BeforePublishAction CreateRigsDestination }
    $raceRigs = Join-Path $fixture.InstallRoot 'rigs'
    Assert-True -Condition (Test-Path -LiteralPath $raceRigs -PathType Container) `
        -Message 'Synthetic publish-race destination was not created.'
    Assert-Equal -Actual @(Get-ChildItem -LiteralPath $raceRigs -Force).Count `
        -Expected 0 -Message 'Destination race received a partial publish.'
    $null = Assert-OneIntentionallyRetainedStagingTree `
        -InstallRoot $fixture.InstallRoot -Label 'Destination race safe refusal' `
        -ExpectHidden $false -ExpectOwnerMarker $false

    $fixture = New-Fixture -Label 'foreign-file-cleanup-refusal'
    Assert-Throws -Label 'unknown staging file cleanup refusal' `
        -Pattern 'run-owner cleanup was refused.*unknown file: foreign-injected\.txt' `
        -Action { Invoke-Seeder -Fixture $fixture `
            -BeforePublishAction InjectUnknownStagingFileThenFail }
    Assert-True -Condition (-not (Test-Path -LiteralPath `
        (Join-Path $fixture.InstallRoot 'rigs'))) `
        -Message 'Unknown staging file failure published rigs.'
    $retainedForeignStage = Assert-OneIntentionallyRetainedStagingTree `
        -InstallRoot $fixture.InstallRoot `
        -Label 'Unknown staging file cleanup refusal' `
        -ExpectHidden $true -ExpectOwnerMarker $true
    Assert-Equal -Actual (Get-Content -Raw -LiteralPath `
        (Join-Path $retainedForeignStage.FullName 'foreign-injected.txt')) `
        -Expected 'foreign' `
        -Message 'Subset-closed cleanup deleted or changed the unknown file.'

    $fixture = New-Fixture -Label 'bad-hash'
    $badBytes = [IO.File]::ReadAllBytes($fixture.CandidatePath)
    $badBytes[0] = $badBytes[0] -bxor 1
    [IO.File]::WriteAllBytes($fixture.CandidatePath, $badBytes)
    Assert-Throws -Label 'candidate hash mismatch' `
        -Pattern 'executable hash does not match' `
        -Action { Invoke-Seeder -Fixture $fixture }
    Assert-NoRigsOrStaging -InstallRoot $fixture.InstallRoot `
        -Label 'Bad candidate hash'

    $fixture = New-Fixture -Label 'bad-size'
    $largerBytes = [byte[]]::new($fixture.CandidateBytes.Length + 1)
    [Array]::Copy($fixture.CandidateBytes, $largerBytes,
        $fixture.CandidateBytes.Length)
    $largerBytes[$largerBytes.Length - 1] = 0x5A
    [IO.File]::WriteAllBytes($fixture.CandidatePath, $largerBytes)
    Assert-Throws -Label 'candidate size mismatch' `
        -Pattern 'executable size does not match' `
        -Action { Invoke-Seeder -Fixture $fixture }
    Assert-NoRigsOrStaging -InstallRoot $fixture.InstallRoot `
        -Label 'Bad candidate size'

    $fixture = New-Fixture -Label 'patch-tamper'
    $patchToTamper = Get-ChildItem -LiteralPath `
        (Join-Path $fixture.ProfileRoot 'patches') -File | Select-Object -First 1
    [IO.File]::AppendAllText($patchToTamper.FullName, "`n# tamper")
    Assert-Throws -Label 'canonical patch tamper' `
        -Pattern 'patch hash mismatch' `
        -Action { Invoke-Seeder -Fixture $fixture }
    Assert-NoRigsOrStaging -InstallRoot $fixture.InstallRoot `
        -Label 'Patch tamper'

    $fixture = New-Fixture -Label 'reparse-install'
    $junctionTarget = Join-Path $fixture.Root 'junction target'
    $junctionPath = Join-Path $fixture.Root 'install junction'
    [void][IO.Directory]::CreateDirectory($junctionTarget)
    try {
        $null = New-Item -ItemType Junction -Path $junctionPath `
            -Target $junctionTarget
        Assert-Throws -Label 'reparse install root' -Pattern 'reparse point' `
            -Action { Invoke-Seeder -Fixture $fixture `
                -InstallRoot $junctionPath }
        Assert-Equal -Actual @(Get-ChildItem -LiteralPath $junctionTarget `
            -Force).Count -Expected 0 `
            -Message 'Reparse rejection wrote through the junction.'
    } finally {
        if (Test-Path -LiteralPath $junctionPath) {
            $junctionItem = Get-Item -LiteralPath $junctionPath -Force
            if (($junctionItem.Attributes -band
                    [IO.FileAttributes]::ReparsePoint) -eq 0) {
                throw 'Refusing test cleanup because junction lost reparse identity.'
            }
            [IO.Directory]::Delete($junctionPath, $false)
        }
    }

    $fixture = New-Fixture -Label 'profile-escape'
    $outsideProfileRoot = [Environment]::SystemDirectory
    Assert-True -Condition ([IO.Directory]::Exists($outsideProfileRoot)) `
        -Message 'Known outside synthetic profile root is unavailable.'
    Assert-Throws -Label 'synthetic profile escape' `
        -Pattern 'ProfileRoot must stay under trusted LocalApplicationData\\Temp' `
        -Action { Invoke-Seeder -Fixture $fixture `
            -ProfileRoot $outsideProfileRoot }
    Assert-NoRigsOrStaging -InstallRoot $fixture.InstallRoot `
        -Label 'Profile escape'

    $fixture = New-Fixture -Label 'nested-name'
    Assert-Throws -Label 'nested output executable name' `
        -Pattern 'safe, non-nested xenia' `
        -Action { Invoke-Seeder -Fixture $fixture `
            -XeniaFileName 'nested\xenia.exe' }
    Assert-NoRigsOrStaging -InstallRoot $fixture.InstallRoot `
        -Label 'Nested output name'

    $fixture = New-Fixture -Label 'same-roots'
    Assert-Throws -Label 'same install and profile roots' `
        -Pattern 'InstallRoot and ProfileRoot must be distinct' `
        -Action { Invoke-Seeder -Fixture $fixture `
            -ProfileRoot $fixture.InstallRoot }
    Assert-NoRigsOrStaging -InstallRoot $fixture.InstallRoot `
        -Label 'Same source and destination roots'

    $fixture = New-Fixture -Label 'production-closure'
    $productionSentinel = Join-Path $fixture.InstallRoot 'preserve-state.txt'
    [IO.File]::WriteAllText($productionSentinel, 'production guard sentinel')
    $productionStateBefore = Get-ExactTreeState -Root $fixture.Root
    $productionOutput = @()
    $productionError = $null
    try {
        $productionOutput = @(& $seederPath `
            -InstallRoot $fixture.InstallRoot `
            -CandidateXeniaPath $fixture.CandidatePath `
            -ProfileRoot $fixture.ProfileRoot)
    } catch {
        $productionError = $_
    }
    Assert-True -Condition ($null -ne $productionError) `
        -Message 'Production seeding did not fail closed.'
    Assert-Equal -Actual $productionError.Exception.Message `
        -Expected 'PRODUCTION_RIG_SEEDING_CLOSURE_DEFERRED' `
        -Message 'Production seeding returned a non-stable closure error.'
    Assert-Equal -Actual $productionOutput.Count -Expected 0 `
        -Message 'Production closure emitted a receipt or other output.'
    Assert-Equal -Actual (Get-ExactTreeState -Root $fixture.Root) `
        -Expected $productionStateBefore `
        -Message 'Production closure changed fixture state.'
    Assert-NoRigsOrStaging -InstallRoot $fixture.InstallRoot `
        -Label 'Production closure'

    $poisonedProductionOutput = @()
    $poisonedProductionError = $null
    try {
        $poisonedProductionOutput = @(& $seederPath `
            -InstallRoot '?:\intentionally-invalid-install-root' `
            -CandidateXeniaPath '\\inaccessible.invalid\share\xenia.exe' `
            -ProfileRoot 'Z:\definitely-missing-profile' `
            -XeniaFileName 'nested\invalid.exe')
    } catch {
        $poisonedProductionError = $_
    }
    Assert-True -Condition ($null -ne $poisonedProductionError) `
        -Message 'Poisoned production paths did not hit the early closure.'
    Assert-Equal -Actual $poisonedProductionError.Exception.Message `
        -Expected 'PRODUCTION_RIG_SEEDING_CLOSURE_DEFERRED' `
        -Message 'Poisoned paths were inspected before the production closure.'
    Assert-Equal -Actual $poisonedProductionOutput.Count -Expected 0 `
        -Message 'Poisoned production closure emitted output.'

    $profileText = (Get-Content -Raw -LiteralPath `
        (Join-Path $productionProfileRoot 'profile.psd1')).Replace(
            "`r`n", "`n").Replace("`r", "`n")
    $algorithm = [Security.Cryptography.SHA256]::Create()
    try {
        $productionProfileHash = ([BitConverter]::ToString(
            $algorithm.ComputeHash([Text.Encoding]::UTF8.GetBytes(
                $profileText)))) -replace '-', ''
    } finally {
        $algorithm.Dispose()
    }
    Assert-Equal -Actual $productionProfileHash `
        -Expected '87987BECC70800C3D7CA3434E7BE15365A8E3053185E04121AE38525BFA5E891' `
        -Message 'Seeder production-profile pin is stale.'

    Write-Output (('PASS: inert runtime-core seeder ps={0} fixtures={1} ' +
        'edition={2} files=12 patches_per_side=3 live_checks=3 ' +
        'atomic_publish=1 atomic_children=4 owner_token=1 owner_lock=1 ' +
        'subset_cleanup=1 child_hijacks=2 visible_rigs=1 ' +
        'known_folder_anchor=1 retained_failures=5 ' +
        'production_closed=2 readiness=false') -f $PSVersionTable.PSVersion,
        $fixtureRoots.Count, $PSVersionTable.PSEdition)
} finally {
    for ($index = $fixtureRoots.Count - 1; $index -ge 0; $index--) {
        Remove-FixtureRoot -Path $fixtureRoots[$index]
    }
}
