[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$modulePath = Join-Path $repoRoot `
    'tools\runtime\AotRuntimeCoreLogWatch.psm1'
Import-Module -Force $modulePath

$script:AssertionCount = 0
$script:CaseCount = 0
$script:FixtureRoots = [Collections.Generic.List[string]]::new()
$script:Utf8NoBom = [Text.UTF8Encoding]::new($false)
$script:Prefix = '[AOT-RUNTIME-SA2][ACCEPT]'
$script:Events = @{
    1 = 'PRECONNECT_XSA1_PREPARED_FOR_GUEST'
    2 = 'XNETCONNECT_MANAGER_ARMED'
    3 = 'POSTCONNECT_XSA1_RETRANSMIT_CONSUMED_ACK_SENT'
}

function Get-TrustedFixtureAnchor {
    $localAppData = [Environment]::GetFolderPath(
        [Environment+SpecialFolder]::LocalApplicationData)
    if ([string]::IsNullOrWhiteSpace($localAppData)) {
        throw 'The LocalApplicationData known folder is unavailable.'
    }
    $localFull = [IO.Path]::GetFullPath($localAppData).TrimEnd('\', '/')
    $volumeRoot = [IO.Path]::GetPathRoot($localFull)
    if ([string]::IsNullOrWhiteSpace($volumeRoot) -or
        $localFull -ieq $volumeRoot.TrimEnd('\', '/')) {
        throw 'The LocalApplicationData known folder resolved to a volume root.'
    }
    $anchor = [IO.Path]::GetFullPath((Join-Path $localFull 'Temp')).TrimEnd('\', '/')
    if (-not [IO.Directory]::Exists($anchor)) {
        throw 'The trusted LocalApplicationData Temp anchor is unavailable.'
    }
    foreach ($directory in $localFull, $anchor) {
        if (([IO.File]::GetAttributes($directory) -band
                [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw 'The trusted fixture anchor contains a reparse point.'
        }
    }
    return $anchor
}

$script:TrustedFixtureAnchor = Get-TrustedFixtureAnchor

function Assert-True {
    param([bool]$Condition, [string]$Message)
    $script:AssertionCount++
    if (-not $Condition) { throw $Message }
}

function Assert-Equal {
    param(
        [AllowNull()][object]$Actual,
        [AllowNull()][object]$Expected,
        [string]$Message
    )
    $script:AssertionCount++
    if ($Actual -cne $Expected) {
        throw "$Message Expected '$Expected'; found '$Actual'."
    }
}

function Assert-HasCode {
    param(
        [Parameter(Mandatory = $true)][object]$Evidence,
        [Parameter(Mandatory = $true)][string]$Code,
        [string]$Message = 'Expected evidence error code was absent.'
    )
    Assert-True (@($Evidence.ErrorCodes) -ccontains $Code) "$Message Code=$Code"
}

function Get-Sha256 {
    param([Parameter(Mandatory = $true)][string]$Path)
    return (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash
}

function Write-Bytes {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][byte[]]$Bytes
    )
    [IO.File]::WriteAllBytes($Path, $Bytes)
}

function Append-Bytes {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][byte[]]$Bytes
    )
    $share = [IO.FileShare]([IO.FileShare]::Read -bor
        [IO.FileShare]::Write -bor [IO.FileShare]::Delete)
    $stream = [IO.FileStream]::new(
        $Path, [IO.FileMode]::Append, [IO.FileAccess]::Write, $share)
    try {
        $stream.Write($Bytes, 0, $Bytes.Length)
        $stream.Flush()
    } finally {
        $stream.Dispose()
    }
}

function Append-Text {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Text
    )
    Append-Bytes -Path $Path -Bytes $script:Utf8NoBom.GetBytes($Text)
}

function New-TestHardLink {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Target
    )

    if ([IO.File]::Exists($Path)) { [IO.File]::Delete($Path) }
    $null = New-Item -ItemType HardLink -Path $Path -Target $Target `
        -ErrorAction Stop
    if (-not [IO.File]::Exists($Path)) {
        throw 'Hard-link fixture creation did not produce a file.'
    }
}

function New-TestJunction {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Target
    )

    $null = New-Item -ItemType Junction -Path $Path -Target $Target `
        -ErrorAction Stop
    $attributes = [IO.File]::GetAttributes($Path)
    if (($attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0) {
        throw 'Junction fixture did not produce a reparse point.'
    }
}

function New-Marker {
    param(
        [Parameter(Mandatory = $true)][uint64]$Seq,
        [Parameter(Mandatory = $true)][uint64]$Generation,
        [Parameter(Mandatory = $true)][ValidateRange(1, 3)][int]$Stage,
        [string]$LogPrefix = 'i> 00000001 '
    )
    return '{0}{1} seq={2} generation={3} stage={4} event={5}' -f
        $LogPrefix, $script:Prefix, $Seq, $Generation, $Stage,
        $script:Events[$Stage]
}

function New-WatchFixture {
    param([Parameter(Mandatory = $true)][string]$Label)

    $tempBase = $script:TrustedFixtureAnchor
    $root = Join-Path $tempBase ('AotLogWatch_{0}_{1}' -f
        $Label, [Guid]::NewGuid().ToString('N'))
    $rootFull = [IO.Path]::GetFullPath($root)
    if (-not ($rootFull + '\').StartsWith(
            $tempBase + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Synthetic fixture escaped the trusted fixture anchor.'
    }
    [void][IO.Directory]::CreateDirectory($rootFull)
    $script:FixtureRoots.Add($rootFull)

    $runId = [Guid]::NewGuid().ToString('N')
    $startUtc = [DateTime]::SpecifyKind(
        [DateTime]'2026-08-28T12:00:00.0000000', [DateTimeKind]::Utc)
    $states = @{}
    $receipts = @{}
    $paths = @{}
    $fixturePid = 42000
    $executableBytes = $script:Utf8NoBom.GetBytes(
        'synthetic runtime-core executable')
    foreach ($side in 'Daddy', 'CJ') {
        $fixturePid++
        $rig = Join-Path $rootFull $side
        [void][IO.Directory]::CreateDirectory($rig)
        $exe = Join-Path $rig 'xenia_runtime_core_fixture.exe'
        $log = Join-Path $rig 'xenia.log'
        Write-Bytes -Path $exe -Bytes $executableBytes
        Write-Bytes -Path $log -Bytes $script:Utf8NoBom.GetBytes(
            "i> 00000001 synthetic boot $side`r`n")
        $paths[$side] = [pscustomobject]@{
            Rig = $rig
            Exe = $exe
            Log = $log
        }
        $states[$side] = [pscustomobject]@{
            Exists = $true
            HasExited = $false
            ProcessId = $fixturePid
            StartTimeUtc = $startUtc
            ExecutablePath = $exe
        }
        $receipts[$side] = [pscustomobject][ordered]@{
            Side = $side
            ProcessId = $fixturePid
            StartTimeUtc = $startUtc
            FilePath = $exe
            XeniaBytes = (Get-Item -LiteralPath $exe).Length
            XeniaSha256 = Get-Sha256 $exe
            WorkingDirectory = $rig
            ArgumentListSha256 = if ($side -ceq 'Daddy') {
                'A' * 64
            } else { 'B' * 64 }
            RunId = $runId
        }
    }

    return [pscustomobject]@{
        Root = $rootFull
        Paths = $paths
        States = $states
        Receipts = $receipts
        Clock = [pscustomobject]@{ Milliseconds = [int64]0 }
    }
}

function Remove-WatchFixture {
    param([Parameter(Mandatory = $true)][object]$Fixture)

    $tempBase = $script:TrustedFixtureAnchor.TrimEnd('\') + '\'
    $resolved = [IO.Path]::GetFullPath([string]$Fixture.Root)
    if (-not ($resolved + '\').StartsWith(
            $tempBase, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Refusing to remove a synthetic fixture outside the trusted anchor.'
    }
    if (Test-Path -LiteralPath $resolved) {
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
    Assert-True (-not (Test-Path -LiteralPath $resolved)) `
        'Watcher leaked a retained handle into fixture cleanup.'
}

function New-TestHooks {
    param(
        [Parameter(Mandatory = $true)][object]$Fixture,
        [AllowNull()][scriptblock]$BeforeBaselineProbe = $null,
        [AllowNull()][scriptblock]$BeforePoll = $null,
        [AllowNull()][scriptblock]$AfterRead = $null,
        [AllowNull()][scriptblock]$CancellationRequested = $null
    )

    $states = $Fixture.States
    $clock = $Fixture.Clock
    $tempRoot = $Fixture.Root
    $getSnapshot = {
        param($Side, $ProcessId, $PollIndex)
        $state = $states[$Side]
        return [pscustomobject]@{
            Exists = [bool]$state.Exists
            HasExited = [bool]$state.HasExited
            ProcessId = [int]$state.ProcessId
            StartTimeUtc = [DateTime]$state.StartTimeUtc
            ExecutablePath = [string]$state.ExecutablePath
        }
    }.GetNewClosure()
    $getElapsed = { return [int64]$clock.Milliseconds }.GetNewClosure()
    $sleep = {
        param($Milliseconds)
        $clock.Milliseconds = [int64]$clock.Milliseconds + [int64]$Milliseconds
    }.GetNewClosure()
    $hooks = [ordered]@{
        TempRoot = $tempRoot
        GetProcessSnapshot = $getSnapshot
        GetElapsedMilliseconds = $getElapsed
        Sleep = $sleep
    }
    if ($null -ne $BeforeBaselineProbe) {
        $hooks.BeforeBaselineProbe = $BeforeBaselineProbe
    }
    if ($null -ne $BeforePoll) { $hooks.BeforePoll = $BeforePoll }
    if ($null -ne $AfterRead) { $hooks.AfterRead = $AfterRead }
    if ($null -ne $CancellationRequested) {
        $hooks.CancellationRequested = $CancellationRequested
    }
    return $hooks
}

function Invoke-SyntheticWatch {
    param(
        [Parameter(Mandatory = $true)][object]$Fixture,
        [AllowNull()][scriptblock]$BeforeBaselineProbe = $null,
        [AllowNull()][scriptblock]$BeforePoll = $null,
        [AllowNull()][scriptblock]$AfterRead = $null,
        [AllowNull()][scriptblock]$CancellationRequested = $null,
        [ValidateRange(1, 10)][int]$TimeoutSeconds = 1,
        [ValidateRange(10, 1000)][int]$PollMilliseconds = 100
    )
    $hooks = New-TestHooks -Fixture $Fixture `
        -BeforeBaselineProbe $BeforeBaselineProbe -BeforePoll $BeforePoll `
        -AfterRead $AfterRead -CancellationRequested $CancellationRequested
    return Invoke-AotRuntimeCoreAcceptanceWatch `
        -DaddyLaunchReceipt $Fixture.Receipts.Daddy `
        -CjLaunchReceipt $Fixture.Receipts.CJ `
        -TimeoutSeconds $TimeoutSeconds -PollMilliseconds $PollMilliseconds `
        -SyntheticFixture -TestHooks $hooks
}

function Invoke-Case {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][scriptblock]$Body
    )
    $script:CaseCount++
    $fixture = New-WatchFixture -Label ('case' + $script:CaseCount)
    try {
        & $Body $fixture
    } catch {
        throw "Log-watch case '$Name' failed: $($_.Exception.Message)"
    } finally {
        Remove-WatchFixture $fixture
    }
}

function Add-DaddyChainCjArm {
    param(
        [Parameter(Mandatory = $true)][object]$Fixture,
        [uint64]$Generation = 7
    )
    Append-Text $Fixture.Paths.Daddy.Log ((New-Marker 11 $Generation 1) + "`r`n")
    Append-Text $Fixture.Paths.CJ.Log ((New-Marker 21 41 2) + "`r`n")
    Append-Text $Fixture.Paths.Daddy.Log ((New-Marker 12 $Generation 2) + "`r`n")
    Append-Text $Fixture.Paths.Daddy.Log ((New-Marker 13 $Generation 3) + "`r`n")
}

try {
    $exports = @(Get-Command -Module AotRuntimeCoreLogWatch |
        ForEach-Object Name)
    Assert-Equal ($exports -join ',') 'Invoke-AotRuntimeCoreAcceptanceWatch' `
        'Watcher module export surface changed.'
    $source = Get-Content -Raw -LiteralPath $modulePath
    Assert-True ($source -notmatch '(?i)\bStop-Process\b|\btaskkill\b|\bRemove-Item\b') `
        'Observer-only watcher gained process-stop or file-delete behavior.'
    Assert-True ($source -match "-Code 'LOG_SHORT_READ'") `
        'Captured-length short-read guard was removed.'

    Invoke-Case 'identical receipt identities are rejected before binding' {
        param($fixture)
        $daddy = $fixture.Receipts.Daddy
        $cj = $fixture.Receipts.CJ
        $cj.ProcessId = $daddy.ProcessId
        $cj.StartTimeUtc = $daddy.StartTimeUtc
        $cj.FilePath = $daddy.FilePath
        $cj.XeniaBytes = $daddy.XeniaBytes
        $cj.XeniaSha256 = $daddy.XeniaSha256
        $cj.WorkingDirectory = $daddy.WorkingDirectory
        $cj.ArgumentListSha256 = $daddy.ArgumentListSha256
        $result = Invoke-SyntheticWatch $fixture
        Assert-Equal $result.FailureCode 'WATCH_INPUT_INVALID' `
            'Identical receipt identities were accepted.'
        Assert-True ($result.FailureMessage -match 'ProcessId') `
            'Identical receipts did not trip the ProcessId guard first.'
        Assert-True ($null -eq $result.Daddy -and $null -eq $result.CJ) `
            'Identical receipts reached retained-handle binding.'
    }

    Invoke-Case 'distinct PIDs cannot share one rig and log' {
        param($fixture)
        $daddy = $fixture.Receipts.Daddy
        $cj = $fixture.Receipts.CJ
        Assert-True ($daddy.ProcessId -ne $cj.ProcessId) `
            'Shared-rig adversarial fixture unexpectedly reused a PID.'
        $cj.WorkingDirectory = $daddy.WorkingDirectory
        $cj.FilePath = $daddy.FilePath
        $result = Invoke-SyntheticWatch $fixture
        Assert-Equal $result.FailureCode 'WATCH_INPUT_INVALID' `
            'Distinct PIDs sharing one rig/log were accepted.'
        Assert-True ($result.FailureMessage -match 'WorkingDirectory') `
            'Shared-rig receipts missed the WorkingDirectory guard.'
        Assert-True ($null -eq $result.Daddy -and $null -eq $result.CJ) `
            'Shared-rig receipts reached retained-handle binding.'
    }

    Invoke-Case 'mismatched Xenia builds are rejected before binding' {
        param($fixture)
        Write-Bytes -Path $fixture.Paths.CJ.Exe `
            -Bytes $script:Utf8NoBom.GetBytes('different synthetic Xenia build')
        $fixture.Receipts.CJ.XeniaBytes =
            (Get-Item -LiteralPath $fixture.Paths.CJ.Exe).Length
        $fixture.Receipts.CJ.XeniaSha256 = Get-Sha256 $fixture.Paths.CJ.Exe
        $result = Invoke-SyntheticWatch $fixture
        Assert-Equal $result.FailureCode 'WATCH_INPUT_INVALID' `
            'Different Xenia builds were accepted as one run.'
        Assert-True ($result.FailureMessage -match 'different Xenia builds') `
            'Build mismatch did not trip the pair-level build guard.'
        Assert-True ($null -eq $result.Daddy -and $null -eq $result.CJ) `
            'Build-mismatched receipts reached retained-handle binding.'
    }

    Invoke-Case 'argument-list identities must be distinct' {
        param($fixture)
        $fixture.Receipts.CJ.ArgumentListSha256 =
            $fixture.Receipts.Daddy.ArgumentListSha256
        $result = Invoke-SyntheticWatch $fixture
        Assert-Equal $result.FailureCode 'WATCH_INPUT_INVALID' `
            'One argument-list identity was accepted for both rigs.'
        Assert-True ($result.FailureMessage -match 'argument-list') `
            'Argument-list collision missed its pair-level guard.'
        Assert-True ($null -eq $result.Daddy -and $null -eq $result.CJ) `
            'Argument-list collision reached retained-handle binding.'
    }

    Invoke-Case 'executable hard-link alias is rejected after binding' {
        param($fixture)
        New-TestHardLink -Path $fixture.Paths.CJ.Exe `
            -Target $fixture.Paths.Daddy.Exe
        $result = Invoke-SyntheticWatch $fixture
        Assert-Equal $result.FailureCode 'WATCH_INPUT_INVALID' `
            'One executable file ID was accepted for both rigs.'
        Assert-True ($result.FailureMessage -match 'one executable file') `
            'Executable hard-link alias missed its retained-ID guard.'
        Assert-True ($null -ne $result.Daddy -and $null -ne $result.CJ) `
            'Executable alias did not reach the post-bind guard.'
        Assert-Equal $result.Daddy.ExecutableFileId `
            $result.CJ.ExecutableFileId `
            'Executable alias fixture did not share a file ID.'
    }

    Invoke-Case 'log hard-link alias is rejected after binding' {
        param($fixture)
        New-TestHardLink -Path $fixture.Paths.CJ.Log `
            -Target $fixture.Paths.Daddy.Log
        $result = Invoke-SyntheticWatch $fixture
        Assert-Equal $result.FailureCode 'WATCH_INPUT_INVALID' `
            'One log file ID was accepted for both rigs.'
        Assert-True ($result.FailureMessage -match 'one log file') `
            'Log hard-link alias missed its retained-ID guard.'
        Assert-True ($null -ne $result.Daddy -and $null -ne $result.CJ) `
            'Log alias did not reach the post-bind guard.'
        Assert-Equal $result.Daddy.LogFileId $result.CJ.LogFileId `
            'Log alias fixture did not share a file ID.'
    }

    Invoke-Case 'missing required xenia log has a stable code' {
        param($fixture)
        [IO.File]::Delete($fixture.Paths.CJ.Log)
        $result = Invoke-SyntheticWatch $fixture
        Assert-Equal $result.FailureCode 'LOG_NOT_FOUND' `
            'Missing required xenia.log did not emit LOG_NOT_FOUND.'
        Assert-Equal $result.FailureSide 'CJ' `
            'Missing-log side attribution changed.'
    }

    Invoke-Case 'actual junction is rejected from synthetic scope' {
        param($fixture)
        $junction = Join-Path $fixture.Root 'CjJunction'
        try {
            New-TestJunction -Path $junction -Target $fixture.Paths.CJ.Rig
            $fixture.Receipts.CJ.WorkingDirectory = $junction
            $fixture.Receipts.CJ.FilePath = Join-Path $junction `
                'xenia_runtime_core_fixture.exe'
            $result = Invoke-SyntheticWatch $fixture
            Assert-Equal $result.FailureCode 'WATCH_INPUT_INVALID' `
                'Synthetic receipt accepted a real junction.'
            Assert-True ($result.FailureMessage -match 'reparse point') `
                'Junction rejection did not exercise the reparse guard.'
            Assert-True ($null -eq $result.Daddy -and $null -eq $result.CJ) `
                'Junction receipt reached retained-handle binding.'
        } finally {
            if ([IO.Directory]::Exists($junction)) {
                [IO.Directory]::Delete($junction)
            }
        }
    }

    Invoke-Case 'Daddy chain and CJ arm' {
        param($fixture)
        $didWrite = $false
        $before = {
            param($poll)
            if (-not $didWrite) {
                Add-DaddyChainCjArm $fixture
                $didWrite = $true
            }
        }.GetNewClosure()
        $result = Invoke-SyntheticWatch $fixture -BeforePoll $before
        Assert-True $result.Passed 'Natural Daddy-chain asymmetry should pass.'
        Assert-Equal $result.Status 'PASSED' 'Success status changed.'
        Assert-Equal $result.EvidenceTrust 'SYNTHETIC_TEST_ONLY' `
            'Synthetic evidence trust label changed.'
        Assert-True (-not $result.RequiresOwnedRunCleanup) `
            'Successful watch incorrectly requested owner cleanup.'
        Assert-True ($null -ne $result.PSObject.Properties['DurationMs']) `
            'Structured result lost its DurationMs field.'
        Assert-Equal $result.Daddy.CandidateLineCount 3 `
            'Daddy candidate count changed.'
        Assert-Equal $result.CJ.CandidateLineCount 1 'CJ candidate count changed.'
        Assert-True $result.Evidence.Sides.Daddy.CompleteChain `
            'Daddy complete chain was not preserved.'
        Assert-Equal (@($result.Evidence.CompleteChainSides) -join ',') 'Daddy' `
            'Complete-chain side changed.'
    }

    Invoke-Case 'CJ chain and stale prebaseline marker' {
        param($fixture)
        Append-Text $fixture.Paths.Daddy.Log `
            ($script:Prefix + ' seq=0 generation=0 stage=1 event=bad' + "`r`n")
        $didWrite = $false
        $before = {
            param($poll)
            if (-not $didWrite) {
                Append-Text $fixture.Paths.Daddy.Log ((New-Marker 50 6 2) + "`n")
                Append-Text $fixture.Paths.CJ.Log ((New-Marker 1 9 1) + "`n")
                Append-Text $fixture.Paths.CJ.Log ((New-Marker 2 9 2) + "`n")
                Append-Text $fixture.Paths.CJ.Log ((New-Marker 3 9 3) + "`n")
                $didWrite = $true
            }
        }.GetNewClosure()
        $result = Invoke-SyntheticWatch $fixture -BeforePoll $before
        Assert-True $result.Passed `
            'Post-baseline CJ chain should ignore malformed stale history.'
        Assert-Equal (@($result.Evidence.CompleteChainSides) -join ',') 'CJ' `
            'CJ should be the only complete-chain side.'
        Assert-Equal $result.Daddy.CandidateLineCount 1 `
            'Prebaseline marker leaked into candidate records.'
    }

    Invoke-Case 'marker split across appended polls' {
        param($fixture)
        $full = (New-Marker 11 7 1) + "`r`n"
        $cut = [int]($full.Length / 2)
        $before = {
            param($poll)
            if ($poll -eq 0) {
                Append-Text $fixture.Paths.Daddy.Log $full.Substring(0, $cut)
                Append-Text $fixture.Paths.CJ.Log ((New-Marker 21 41 2) + "`r`n")
            } elseif ($poll -eq 1) {
                Append-Text $fixture.Paths.Daddy.Log $full.Substring($cut)
                Append-Text $fixture.Paths.Daddy.Log ((New-Marker 12 7 2) + "`r`n")
                Append-Text $fixture.Paths.Daddy.Log ((New-Marker 13 7 3) + "`r`n")
            }
        }.GetNewClosure()
        $result = Invoke-SyntheticWatch $fixture -BeforePoll $before
        Assert-True $result.Passed `
            'A post-baseline marker split across reads should reassemble safely.'
        Assert-Equal $result.Daddy.PartialByteCount 0 `
            'Completed split marker left a partial carry.'
        Assert-True ($result.Daddy.FinalReadOffset -gt $result.Daddy.BaselineOffset) `
            'Watcher did not advance from its baseline.'
    }

    Invoke-Case 'noise-only timeout' {
        param($fixture)
        $didWrite = $false
        $before = {
            param($poll)
            if (-not $didWrite) {
                Append-Text $fixture.Paths.Daddy.Log "IN LOBBY`r`n"
                Append-Text $fixture.Paths.CJ.Log "Player0 is the host`r`n"
                $didWrite = $true
            }
        }.GetNewClosure()
        $result = Invoke-SyntheticWatch $fixture -BeforePoll $before `
            -PollMilliseconds 500
        Assert-True (-not $result.Passed) 'Lobby noise must not pass evidence.'
        Assert-Equal $result.Status 'TIMED_OUT' `
            "Noise timeout status changed (code=$($result.FailureCode) message=$($result.FailureMessage))."
        Assert-Equal $result.FailureCode 'SA2_EVIDENCE_TIMEOUT' `
            'Noise-only failure code changed.'
        Assert-HasCode $result.Evidence 'DADDY_STAGE2_MISSING'
        Assert-HasCode $result.Evidence 'CJ_STAGE2_MISSING'
        Assert-True $result.RequiresOwnedRunCleanup `
            'Timeout did not request owner-controlled cleanup.'
    }

    Invoke-Case 'partial line at baseline' {
        param($fixture)
        Write-Bytes $fixture.Paths.Daddy.Log `
            $script:Utf8NoBom.GetBytes('partial-before-baseline')
        $result = Invoke-SyntheticWatch $fixture
        Assert-Equal $result.FailureCode 'BASELINE_PARTIAL_LINE' `
            'Partial baseline did not fail closed.'
        Assert-Equal $result.FailureSide 'Daddy' `
            'Partial-baseline side attribution changed.'
    }

    Invoke-Case 'bounded baseline stabilization excludes prior partial line' {
        param($fixture)
        Write-Bytes $fixture.Paths.Daddy.Log $script:Utf8NoBom.GetBytes(
            'stale [AOT-RUNTIME-SA2][ACCEPT] seq=0 generation=0')
        $completedBaseline = $false
        $baselineHook = {
            param($side, $probe)
            if ($side -ceq 'Daddy' -and $probe -eq 0 -and
                -not $completedBaseline) {
                Append-Text $fixture.Paths.Daddy.Log "`r`n"
                $completedBaseline = $true
            }
        }.GetNewClosure()
        $before = {
            param($poll)
            if ($poll -eq 0) { Add-DaddyChainCjArm $fixture }
        }.GetNewClosure()
        $result = Invoke-SyntheticWatch $fixture `
            -BeforeBaselineProbe $baselineHook -BeforePoll $before
        Assert-True $result.Passed `
            'Bounded baseline stabilization should pass after reaching LF.'
        Assert-Equal $result.Daddy.CandidateLineCount 3 `
            'Partial prebaseline marker was stitched into current evidence.'
        Assert-True ($result.DurationMs -ge 25) `
            'Synthetic baseline stabilization did not use the bounded clock.'
    }

    Invoke-Case 'success waits for a stable EOF snapshot' {
        param($fixture)
        $before = {
            param($poll)
            if ($poll -eq 0) { Add-DaddyChainCjArm $fixture }
        }.GetNewClosure()
        $after = {
            param($poll)
            if ($poll -eq 0) {
                Append-Text $fixture.Paths.Daddy.Log "late complete noise`r`n"
            }
        }.GetNewClosure()
        $result = Invoke-SyntheticWatch $fixture -BeforePoll $before `
            -AfterRead $after
        Assert-True $result.Passed `
            'Watcher should consume post-read growth before returning success.'
        Assert-Equal $result.Daddy.CompleteLineCount 4 `
            'Late complete line was not consumed before success.'
        Assert-Equal $result.Daddy.FinalReadOffset `
            ($result.Daddy.BaselineOffset + $result.Daddy.BytesRead) `
            'Stable EOF receipt contains unread or double-counted bytes.'
    }

    Invoke-Case 'partial final line at timeout' {
        param($fixture)
        $before = {
            param($poll)
            if ($poll -eq 0) {
                Append-Text $fixture.Paths.Daddy.Log (New-Marker 1 1 1)
                Append-Text $fixture.Paths.CJ.Log ((New-Marker 1 2 2) + "`n")
            }
        }.GetNewClosure()
        $result = Invoke-SyntheticWatch $fixture -BeforePoll $before `
            -PollMilliseconds 500
        Assert-Equal $result.FailureCode 'LOG_PARTIAL_FINAL_LINE' `
            "Incomplete final line did not fail with the integrity code (message=$($result.FailureMessage))."
        Assert-True ($result.Daddy.PartialByteCount -gt 0) `
            'Partial carry was not exposed in the sanitized receipt.'
    }

    Invoke-Case 'malformed marker is terminal' {
        param($fixture)
        $didWrite = $false
        $before = {
            param($poll)
            if (-not $didWrite) {
                Add-DaddyChainCjArm $fixture
                Append-Text $fixture.Paths.Daddy.Log `
                    ((New-Marker 14 7 1) + ' trailing-junk' + "`n")
                $didWrite = $true
            }
        }.GetNewClosure()
        $result = Invoke-SyntheticWatch $fixture -BeforePoll $before
        Assert-Equal $result.FailureCode 'SA2_EVIDENCE_INVALID' `
            'Malformed marker was not terminal.'
        Assert-HasCode $result.Evidence 'MARKER_MALFORMED'
    }

    Invoke-Case 'same-file shrink' {
        param($fixture)
        $didShrink = $false
        $before = {
            param($poll)
            if (-not $didShrink) {
                $share = [IO.FileShare]([IO.FileShare]::Read -bor
                    [IO.FileShare]::Write -bor [IO.FileShare]::Delete)
                $writer = [IO.FileStream]::new(
                    $fixture.Paths.Daddy.Log, [IO.FileMode]::Open,
                    [IO.FileAccess]::Write, $share)
                try { $writer.SetLength(0); $writer.Flush() } finally {
                    $writer.Dispose()
                }
                $didShrink = $true
            }
        }.GetNewClosure()
        $result = Invoke-SyntheticWatch $fixture -BeforePoll $before
        Assert-Equal $result.FailureCode 'LOG_SHRANK' `
            'Same-file truncation was not rejected.'
        Assert-Equal $result.FailureSide 'Daddy' 'Shrink side attribution changed.'
    }

    Invoke-Case 'log rename and replacement' {
        param($fixture)
        $didReplace = $false
        $before = {
            param($poll)
            if (-not $didReplace) {
                $old = Join-Path $fixture.Paths.Daddy.Rig 'xenia.rotated.log'
                Move-Item -LiteralPath $fixture.Paths.Daddy.Log -Destination $old
                Append-Text $fixture.Paths.Daddy.Log "replacement`r`n"
                $didReplace = $true
            }
        }.GetNewClosure()
        $result = Invoke-SyntheticWatch $fixture -BeforePoll $before
        Assert-True ($result.FailureCode -cin @(
                'LOG_FINAL_PATH_CHANGED', 'LOG_FILE_ID_CHANGED')) `
            "Log replacement did not trip a stable identity guard (code=$($result.FailureCode) message=$($result.FailureMessage))."
        Assert-Equal $result.FailureSide 'Daddy' `
            'Log replacement side attribution changed.'
    }

    Invoke-Case 'PID reuse start mismatch' {
        param($fixture)
        $changed = $false
        $before = {
            param($poll)
            if (-not $changed) {
                $fixture.States.Daddy.StartTimeUtc =
                    $fixture.States.Daddy.StartTimeUtc.AddSeconds(1)
                $changed = $true
            }
        }.GetNewClosure()
        $result = Invoke-SyntheticWatch $fixture -BeforePoll $before
        Assert-Equal $result.FailureCode 'PROCESS_START_MISMATCH' `
            'PID reuse/start mismatch was not rejected.'
        Assert-Equal $result.FailureSide 'Daddy' `
            'PID reuse side attribution changed.'
    }

    Invoke-Case 'retained process exits' {
        param($fixture)
        $changed = $false
        $before = {
            param($poll)
            if (-not $changed) {
                $fixture.States.CJ.HasExited = $true
                $changed = $true
            }
        }.GetNewClosure()
        $result = Invoke-SyntheticWatch $fixture -BeforePoll $before
        Assert-Equal $result.FailureCode 'PROCESS_EXITED' `
            'Exited retained process was not rejected.'
        Assert-Equal $result.FailureSide 'CJ' `
            'Exited-process side attribution changed.'
    }

    Invoke-Case 'process image mismatch at bind' {
        param($fixture)
        $fixture.States.Daddy.ExecutablePath = $fixture.Paths.CJ.Exe
        $result = Invoke-SyntheticWatch $fixture
        Assert-Equal $result.FailureCode 'PROCESS_IMAGE_PATH_MISMATCH' `
            'Process image mismatch was not rejected at bind.'
        Assert-Equal $result.FailureSide 'Daddy' `
            'Image-mismatch side attribution changed.'
    }

    Invoke-Case 'executable hash mismatch at bind' {
        param($fixture)
        $fixture.Receipts.Daddy.XeniaSha256 = ('0' * 64)
        $fixture.Receipts.CJ.XeniaSha256 = ('0' * 64)
        $result = Invoke-SyntheticWatch $fixture
        Assert-Equal $result.FailureCode 'EXECUTABLE_HASH_MISMATCH' `
            'Executable hash mismatch was not rejected.'
        Assert-Equal $result.FailureSide 'Daddy' `
            'Executable-hash side attribution changed.'
    }

    Invoke-Case 'retained executable blocks rename and replacement' {
        param($fixture)
        $attempt = [pscustomobject]@{
            Complete = $false
            RenameBlocked = $false
            RenameSucceeded = $false
            ReplaceBlocked = $false
            ReplaceSucceeded = $false
        }
        $replacementBytes = $script:Utf8NoBom.GetBytes(
            'replacement executable')
        $before = {
            param($poll)
            if ($attempt.Complete) { return }
            $exe = $fixture.Paths.Daddy.Exe
            $renamed = Join-Path $fixture.Paths.Daddy.Rig 'xenia.renamed.exe'
            try {
                [IO.File]::Move($exe, $renamed)
                $attempt.RenameSucceeded = $true
            } catch {
                $attempt.RenameBlocked = $true
            }

            $candidate = Join-Path $fixture.Paths.Daddy.Rig `
                'xenia.replacement.candidate.exe'
            $backup = Join-Path $fixture.Paths.Daddy.Rig `
                'xenia.replacement.backup.exe'
            Write-Bytes -Path $candidate -Bytes $replacementBytes
            try {
                [IO.File]::Replace($candidate, $exe, $backup)
                $attempt.ReplaceSucceeded = $true
            } catch {
                $attempt.ReplaceBlocked = $true
            }
            Add-DaddyChainCjArm $fixture
            $attempt.Complete = $true
        }.GetNewClosure()
        $result = Invoke-SyntheticWatch $fixture -BeforePoll $before
        Assert-True $result.Passed `
            ("Executable sharing regression interrupted valid evidence: code={0} message={1}" -f
                $result.FailureCode, $result.FailureMessage)
        Assert-True ($attempt.RenameBlocked -and
            -not $attempt.RenameSucceeded) `
            'Retained executable handle allowed a rename.'
        Assert-True ($attempt.ReplaceBlocked -and
            -not $attempt.ReplaceSucceeded) `
            'Retained executable handle allowed atomic replacement.'
        Assert-Equal (Get-Sha256 $fixture.Paths.Daddy.Exe) `
            $fixture.Receipts.Daddy.XeniaSha256 `
            'Executable changed despite the retained read-only handle.'
    }

    Invoke-Case 'strict UTF-8 complete lines' {
        param($fixture)
        $didWrite = $false
        $before = {
            param($poll)
            if (-not $didWrite) {
                Append-Bytes $fixture.Paths.Daddy.Log ([byte[]](0xFF, 0x0A))
                $didWrite = $true
            }
        }.GetNewClosure()
        $result = Invoke-SyntheticWatch $fixture -BeforePoll $before
        Assert-Equal $result.FailureCode 'LOG_INVALID_UTF8' `
            'Invalid UTF-8 complete line was not rejected.'
        Assert-Equal $result.FailureSide 'Daddy' `
            'Invalid UTF-8 side attribution changed.'
    }

    Invoke-Case 'post-read identity change beats apparent pass' {
        param($fixture)
        $wrote = $false
        $replaced = $false
        $before = {
            param($poll)
            if (-not $wrote) {
                Add-DaddyChainCjArm $fixture
                $wrote = $true
            }
        }.GetNewClosure()
        $after = {
            param($poll)
            if (-not $replaced) {
                $old = Join-Path $fixture.Paths.CJ.Rig 'xenia.after-read.log'
                Move-Item -LiteralPath $fixture.Paths.CJ.Log -Destination $old
                Append-Text $fixture.Paths.CJ.Log "replacement`r`n"
                $replaced = $true
            }
        }.GetNewClosure()
        $result = Invoke-SyntheticWatch $fixture -BeforePoll $before `
            -AfterRead $after
        Assert-True (-not $result.Passed) `
            'Apparent evidence passed across a post-read identity change.'
        Assert-True ($result.FailureCode -cin @(
                'LOG_FINAL_PATH_CHANGED', 'LOG_FILE_ID_CHANGED')) `
            'Post-read replacement did not trip the identity guard.'
    }

    Invoke-Case 'cancellation' {
        param($fixture)
        $cancel = { param($poll); return $true }
        $result = Invoke-SyntheticWatch $fixture `
            -CancellationRequested $cancel
        Assert-Equal $result.Status 'CANCELLED' 'Cancellation status changed.'
        Assert-Equal $result.FailureCode 'WATCH_CANCELLED' `
            'Cancellation failure code changed.'
        Assert-True $result.RequiresOwnedRunCleanup `
            'Cancellation did not request owner cleanup.'
    }

    Invoke-Case 'candidate count is bounded' {
        param($fixture)
        $didWrite = $false
        $before = {
            param($poll)
            if (-not $didWrite) {
                for ($index = 1; $index -le 17; $index++) {
                    Append-Text $fixture.Paths.Daddy.Log `
                        ((New-Marker ([uint64]$index) 1 2) + "`n")
                }
                $didWrite = $true
            }
        }.GetNewClosure()
        $result = Invoke-SyntheticWatch $fixture -BeforePoll $before
        Assert-Equal $result.FailureCode 'SA2_EVIDENCE_INVALID' `
            'Unbounded candidate stream was not rejected.'
        Assert-Equal $result.FailureSide 'Daddy' `
            'Candidate-limit side attribution changed.'
    }

    Invoke-Case 'synthetic fixture cannot escape temp root' {
        param($fixture)
        $outside = Join-Path $script:TrustedFixtureAnchor `
            ('AotLogWatchOutside_' + [Guid]::NewGuid().ToString('N'))
        [void][IO.Directory]::CreateDirectory($outside)
        try {
            $fixture.Receipts.Daddy.WorkingDirectory = $outside
            $fixture.Receipts.Daddy.FilePath = Join-Path $outside `
                'xenia_runtime_core_fixture.exe'
            $hooks = New-TestHooks $fixture
            $result = Invoke-AotRuntimeCoreAcceptanceWatch `
                -DaddyLaunchReceipt $fixture.Receipts.Daddy `
                -CjLaunchReceipt $fixture.Receipts.CJ -TimeoutSeconds 1 `
                -SyntheticFixture -TestHooks $hooks
            Assert-Equal $result.FailureCode 'WATCH_INPUT_INVALID' `
                'Synthetic path escaped its declared fixture root.'
        } finally {
            $outsideFull = [IO.Path]::GetFullPath($outside)
            $tempFull = $script:TrustedFixtureAnchor.TrimEnd('\') + '\'
            Assert-True $outsideFull.StartsWith(
                $tempFull, [StringComparison]::OrdinalIgnoreCase) `
                'Outside fixture cleanup path escaped the trusted anchor.'
            if (Test-Path -LiteralPath $outsideFull) {
                Remove-Item -LiteralPath $outsideFull -Recurse -Force
            }
        }
    }

    Invoke-Case 'test hooks forbidden outside synthetic mode' {
        param($fixture)
        $hooks = New-TestHooks $fixture
        $result = Invoke-AotRuntimeCoreAcceptanceWatch `
            -DaddyLaunchReceipt $fixture.Receipts.Daddy `
            -CjLaunchReceipt $fixture.Receipts.CJ -TimeoutSeconds 1 `
            -TestHooks $hooks
        Assert-Equal $result.FailureCode 'WATCH_INPUT_INVALID' `
            'Production mode accepted synthetic hooks.'
        Assert-Equal $result.EvidenceTrust 'PRODUCTION_RETAINED_HANDLE' `
            'Production evidence trust label changed.'
        Assert-True ($null -eq $result.Daddy -and $null -eq $result.CJ) `
            'Hook rejection unexpectedly bound a process or file.'
    }

    Invoke-Case 'synthetic mode requires hooks' {
        param($fixture)
        $result = Invoke-AotRuntimeCoreAcceptanceWatch `
            -DaddyLaunchReceipt $fixture.Receipts.Daddy `
            -CjLaunchReceipt $fixture.Receipts.CJ -TimeoutSeconds 1 `
            -SyntheticFixture
        Assert-Equal $result.FailureCode 'WATCH_INPUT_INVALID' `
            'Synthetic mode accepted an absent TestHooks contract.'
        Assert-True ($null -eq $result.Daddy -and $null -eq $result.CJ) `
            'Missing-hook rejection unexpectedly bound a process or file.'
    }

    Invoke-Case 'run receipts must match' {
        param($fixture)
        $fixture.Receipts.CJ.RunId = [Guid]::NewGuid().ToString('N')
        $result = Invoke-SyntheticWatch $fixture
        Assert-Equal $result.FailureCode 'WATCH_INPUT_INVALID' `
            'Mismatched run receipts were accepted.'
    }

    Invoke-Case 'poisoned TEMP and TMP cannot widen synthetic root' {
        param($fixture)
        $oldTemp = [Environment]::GetEnvironmentVariable('TEMP', 'Process')
        $oldTmp = [Environment]::GetEnvironmentVariable('TMP', 'Process')
        try {
            [Environment]::SetEnvironmentVariable('TEMP', 'C:\', 'Process')
            [Environment]::SetEnvironmentVariable('TMP', 'C:\', 'Process')

            $poisonedHooks = New-TestHooks $fixture
            $poisonedHooks.TempRoot = 'C:\'
            $rejected = Invoke-AotRuntimeCoreAcceptanceWatch `
                -DaddyLaunchReceipt $fixture.Receipts.Daddy `
                -CjLaunchReceipt $fixture.Receipts.CJ -TimeoutSeconds 1 `
                -SyntheticFixture -TestHooks $poisonedHooks
            Assert-Equal $rejected.FailureCode 'WATCH_INPUT_INVALID' `
                'Poisoned TEMP/TMP widened the accepted synthetic root.'
            Assert-Equal $rejected.EvidenceTrust 'SYNTHETIC_TEST_ONLY' `
                'Rejected synthetic evidence lost its trust label.'

            $didWrite = $false
            $before = {
                param($poll)
                if (-not $didWrite) {
                    Add-DaddyChainCjArm $fixture
                    $didWrite = $true
                }
            }.GetNewClosure()
            $accepted = Invoke-SyntheticWatch $fixture -BeforePoll $before
            Assert-True $accepted.Passed `
                'Trusted synthetic fixture failed under poisoned TEMP/TMP.'
            Assert-Equal $accepted.EvidenceTrust 'SYNTHETIC_TEST_ONLY' `
                'Accepted synthetic evidence trust label changed.'
        } finally {
            [Environment]::SetEnvironmentVariable(
                'TEMP', $oldTemp, 'Process')
            [Environment]::SetEnvironmentVariable(
                'TMP', $oldTmp, 'Process')
        }
    }

    Write-Output ('PASS: AOT_RUNTIME_CORE_LOG_WATCH assertions={0} cases={1}' -f
        $script:AssertionCount, $script:CaseCount)
} finally {
    foreach ($root in @($script:FixtureRoots)) {
        if (-not (Test-Path -LiteralPath $root)) { continue }
        $tempBase = $script:TrustedFixtureAnchor.TrimEnd('\') + '\'
        $resolved = [IO.Path]::GetFullPath($root)
        if (($resolved + '\').StartsWith(
                $tempBase, [StringComparison]::OrdinalIgnoreCase)) {
            Remove-Item -LiteralPath $resolved -Recurse -Force
        }
    }
}
