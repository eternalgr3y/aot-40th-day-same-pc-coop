[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$modulePath = Join-Path $repoRoot 'tools\runtime\AotRuntimeCoreEvidence.psm1'
Import-Module -Force $modulePath

$script:AssertionCount = 0
$script:CaseCount = 0
$prefix = '[AOT-RUNTIME-SA2][ACCEPT]'
$events = @{
    1 = 'PRECONNECT_XSA1_PREPARED_FOR_GUEST'
    2 = 'XNETCONNECT_MANAGER_ARMED'
    3 = 'POSTCONNECT_XSA1_RETRANSMIT_CONSUMED_ACK_SENT'
}

function Assert-True {
    param([bool]$Condition, [string]$Message)
    $script:AssertionCount++
    if (-not $Condition) { throw $Message }
}

function Assert-Equal {
    param([AllowNull()][object]$Actual, [AllowNull()][object]$Expected,
        [string]$Message)
    $script:AssertionCount++
    if ($Actual -cne $Expected) {
        throw "$Message Expected '$Expected'; found '$Actual'."
    }
}

function Assert-HasCode {
    param([Parameter(Mandatory = $true)][object]$Result,
        [Parameter(Mandatory = $true)][string]$Code,
        [string]$Message = 'Expected stable error code was absent.')
    Assert-True (@($Result.ErrorCodes) -ccontains $Code) "$Message Code=$Code"
}

function New-Line {
    param(
        [Parameter(Mandatory = $true)][ValidateSet('Daddy', 'CJ')][string]$Side,
        [Parameter(Mandatory = $true)][uint64]$Position,
        [Parameter(Mandatory = $true)][string]$Text,
        [switch]$ByteOffset
    )
    if ($ByteOffset) {
        return [pscustomobject]@{ Side = $Side; ByteOffset = $Position; Text = $Text }
    }
    return [pscustomobject]@{ Side = $Side; Ordinal = $Position; Text = $Text }
}

function New-MarkerText {
    param(
        [Parameter(Mandatory = $true)][uint64]$Seq,
        [Parameter(Mandatory = $true)][uint64]$Generation,
        [Parameter(Mandatory = $true)][ValidateRange(1, 3)][int]$Stage,
        [string]$LogPrefix = ''
    )
    return '{0}{1} seq={2} generation={3} stage={4} event={5}' -f
        $LogPrefix, $prefix, $Seq, $Generation, $Stage, $events[$Stage]
}

function Invoke-Case {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][scriptblock]$Body
    )
    $script:CaseCount++
    try {
        & $Body
    } catch {
        throw "SA2 evidence case '$Name' failed: $($_.Exception.Message)"
    }
}

function New-DaddyChainCjArm {
    param([uint64]$Generation = 7)
    return @(
        New-Line Daddy 10 (New-MarkerText 11 $Generation 1)
        New-Line CJ 5 (New-MarkerText 21 41 2)
        New-Line Daddy 20 (New-MarkerText 12 $Generation 2)
        New-Line Daddy 30 (New-MarkerText 13 $Generation 3)
    )
}

Invoke-Case 'Daddy full chain and CJ arm' {
    $result = Test-AotRuntimeCoreSa2Evidence -InputObject (New-DaddyChainCjArm)
    Assert-True $result.Passed 'Natural Daddy-chain asymmetry should pass.'
    Assert-Equal $result.Sides.Daddy.Stage1Count 1 'Daddy stage-1 count changed.'
    Assert-Equal $result.Sides.Daddy.Stage2Count 1 'Daddy stage-2 count changed.'
    Assert-Equal $result.Sides.Daddy.Stage3Count 1 'Daddy stage-3 count changed.'
    Assert-True $result.Sides.Daddy.CompleteChain 'Daddy chain was not recognized.'
    Assert-Equal $result.Sides.CJ.Stage2Count 1 'CJ arm count changed.'
    Assert-True (-not $result.Sides.CJ.CompleteChain) 'CJ arm-only evidence became a chain.'
    Assert-Equal (@($result.CompleteChainSides) -join ',') 'Daddy' `
        'Complete-chain side set changed.'
}

Invoke-Case 'Daddy chain and CJ armed consume' {
    $records = New-DaddyChainCjArm
    $records += New-Line CJ 6 (New-MarkerText 22 41 3)
    $result = Test-AotRuntimeCoreSa2Evidence -InputObject $records
    Assert-True $result.Passed `
        'The non-chain side may consume after arming without a preconnect marker.'
    Assert-True (-not $result.Sides.CJ.CompleteChain) `
        'A same-side 2-3 pair must not be promoted to a full chain.'
    Assert-Equal (@($result.CompleteChainSides) -join ',') 'Daddy' `
        'Only the side with a strict 1-2-3 chain should close the global gate.'
}

Invoke-Case 'Daddy chain and CJ prepared arm' {
    $records = New-DaddyChainCjArm
    $records += New-Line CJ 4 (New-MarkerText 20 41 1)
    $result = Test-AotRuntimeCoreSa2Evidence -InputObject $records
    Assert-True $result.Passed `
        'The non-chain side may prepare before arming without later consumption.'
    Assert-True (-not $result.Sides.CJ.CompleteChain) `
        'A same-side 1-2 pair must not be promoted to a full chain.'
    Assert-Equal (@($result.CompleteChainSides) -join ',') 'Daddy' `
        'Only the side with a strict 1-2-3 chain should close the global gate.'
}

Invoke-Case 'CJ full chain and Daddy arm' {
    $records = @(
        New-Line Daddy 1 (New-MarkerText 90 9 2)
        New-Line CJ 90 (New-MarkerText 4 22 1)
        New-Line CJ 100 (New-MarkerText 5 22 2)
        New-Line CJ 110 (New-MarkerText 6 22 3)
    )
    $result = Test-AotRuntimeCoreSa2Evidence -InputObject $records
    Assert-True $result.Passed 'Natural CJ-chain asymmetry should pass.'
    Assert-Equal (@($result.CompleteChainSides) -join ',') 'CJ' `
        'CJ should be the only complete-chain side.'
}

Invoke-Case 'both sides full chain' {
    $records = @(
        New-Line Daddy 1 (New-MarkerText 1 1 1)
        New-Line CJ 100 (New-MarkerText 51 8 1)
        New-Line CJ 200 (New-MarkerText 52 8 2)
        New-Line Daddy 2 (New-MarkerText 2 1 2)
        New-Line Daddy 3 (New-MarkerText 3 1 3)
        New-Line CJ 300 (New-MarkerText 53 8 3)
    )
    $result = Test-AotRuntimeCoreSa2Evidence -InputObject $records
    Assert-True $result.Passed `
        'Independent per-side positions should pass despite cross-side interleaving.'
    Assert-Equal (@($result.CompleteChainSides) -join ',') 'Daddy,CJ' `
        'Both complete chains should be reported.'
}

Invoke-Case 'ordinary prefixes and lobby noise' {
    $records = @(
        New-Line Daddy 1 '[I 00:00:01.000] Online lobby created'
        New-Line CJ 1 'Player0 is host'
        New-Line Daddy 2 (New-MarkerText 7 4 1 '[I 00:00:02.000] ')
        New-Line CJ 2 (New-MarkerText 40 19 2 '[D 00:00:02.100] ')
        New-Line Daddy 3 (New-MarkerText 8 4 2 '[I 00:00:03.000] ')
        New-Line Daddy 4 (New-MarkerText 9 4 3 '[I 00:00:04.000] ')
        New-Line CJ 3 'shared session gameplay three minutes death reload'
    )
    $conversion = ConvertFrom-AotRuntimeCoreSa2Lines -InputObject $records
    $result = Test-AotRuntimeCoreSa2Evidence -InputObject $records
    Assert-True $conversion.ParseSucceeded 'Valid prefixed markers should parse.'
    Assert-Equal $conversion.NoiseRecordCount 3 'Noise count changed.'
    Assert-Equal $conversion.ParsedRecordCount 4 'Parsed marker count changed.'
    Assert-True $result.Passed 'Generic lobby noise must not replace or invalidate evidence.'
}

Invoke-Case 'byte offsets and pipeline input' {
    $records = @(
        New-Line Daddy 100 (New-MarkerText 1 3 1) -ByteOffset
        New-Line Daddy 200 (New-MarkerText 2 3 2) -ByteOffset
        New-Line CJ 99 (New-MarkerText 1 6 2) -ByteOffset
        New-Line Daddy 300 (New-MarkerText 3 3 3) -ByteOffset
    )
    $result = $records | Test-AotRuntimeCoreSa2Evidence
    Assert-True $result.Passed 'ByteOffset pipeline input should pass.'
    Assert-Equal $result.Records[0].PositionKind 'ByteOffset' `
        'ByteOffset ordering kind was not retained.'
}

Invoke-Case 'stale records excluded by caller baseline' {
    $all = @(
        New-Line Daddy 10 ($prefix + ' seq=0 generation=0 stage=1 event=bad') -ByteOffset
        New-Line Daddy 100 (New-MarkerText 1 13 1) -ByteOffset
        New-Line CJ 110 (New-MarkerText 1 14 2) -ByteOffset
        New-Line Daddy 120 (New-MarkerText 2 13 2) -ByteOffset
        New-Line Daddy 130 (New-MarkerText 3 13 3) -ByteOffset
    )
    $postBaseline = @($all | Where-Object { $_.ByteOffset -ge 100 })
    $result = Test-AotRuntimeCoreSa2Evidence -InputObject $postBaseline
    Assert-True $result.Passed `
        'The pure reducer should accept only the post-baseline records supplied to it.'
    Assert-Equal $result.InputRecordCount 4 'Pre-baseline record leaked into the reducer.'
}

Invoke-Case 'empty and lobby-only evidence' {
    $empty = Test-AotRuntimeCoreSa2Evidence -InputObject @()
    Assert-True (-not $empty.Passed) 'Empty evidence must fail closed.'
    Assert-HasCode $empty 'DADDY_STAGE2_MISSING'
    Assert-HasCode $empty 'CJ_STAGE2_MISSING'
    Assert-HasCode $empty 'NO_COMPLETE_SAME_SIDE_CHAIN'

    $lobby = Test-AotRuntimeCoreSa2Evidence -InputObject @(
        New-Line Daddy 1 'IN LOBBY'
        New-Line CJ 1 'Player0 is the host'
    )
    Assert-True (-not $lobby.Passed) 'Lobby strings must not substitute for markers.'
    Assert-Equal $lobby.ParsedRecordCount 0 'Lobby strings were parsed as markers.'
}

Invoke-Case 'both arms without complete chain' {
    $result = Test-AotRuntimeCoreSa2Evidence -InputObject @(
        New-Line Daddy 1 (New-MarkerText 1 1 2)
        New-Line CJ 1 (New-MarkerText 1 2 2)
    )
    Assert-True (-not $result.Passed) 'Two arm markers alone must fail.'
    Assert-HasCode $result 'NO_COMPLETE_SAME_SIDE_CHAIN'
}

Invoke-Case 'split-side markers do not create cross-process order' {
    $result = Test-AotRuntimeCoreSa2Evidence -InputObject @(
        New-Line Daddy 1 (New-MarkerText 1 7 1)
        New-Line Daddy 2 (New-MarkerText 2 7 2)
        New-Line CJ 1 (New-MarkerText 20 9 2)
        New-Line CJ 2 (New-MarkerText 21 9 3)
    )
    Assert-True (-not $result.Passed) `
        'Separate local 1-2 and 2-3 pairs must not imply cross-process order.'
    Assert-HasCode $result 'NO_COMPLETE_SAME_SIDE_CHAIN'
}

Invoke-Case 'missing required arm marker' {
    $result = Test-AotRuntimeCoreSa2Evidence -InputObject @(
        New-Line Daddy 1 (New-MarkerText 1 1 1)
        New-Line Daddy 2 (New-MarkerText 2 1 2)
        New-Line Daddy 3 (New-MarkerText 3 1 3)
    )
    Assert-True (-not $result.Passed) 'A missing CJ arm must fail.'
    Assert-HasCode $result 'CJ_STAGE2_MISSING'
}

Invoke-Case 'stage 3 without same-side stage 2' {
    $records = @(
        New-Line Daddy 1 (New-MarkerText 1 1 1)
        New-Line Daddy 2 (New-MarkerText 2 1 2)
        New-Line Daddy 3 (New-MarkerText 3 1 3)
        New-Line CJ 1 (New-MarkerText 1 2 3)
    )
    $result = Test-AotRuntimeCoreSa2Evidence -InputObject $records
    Assert-True (-not $result.Passed) 'Stage 3 without same-side stage 2 must fail.'
    Assert-HasCode $result 'CJ_STAGE2_MISSING'
}

Invoke-Case 'same-side record ordering failures' {
    $cases = @(
        [pscustomobject]@{
            Name = '1-3-2'
            Records = @(
                New-Line Daddy 1 (New-MarkerText 1 1 1)
                New-Line Daddy 2 (New-MarkerText 3 1 3)
                New-Line Daddy 3 (New-MarkerText 2 1 2)
                New-Line CJ 1 (New-MarkerText 1 2 2))
            Code = 'DADDY_STAGE2_STAGE3_ORDER_INVALID'
        }
        [pscustomobject]@{
            Name = '2-1-3'
            Records = @(
                New-Line Daddy 1 (New-MarkerText 2 1 2)
                New-Line Daddy 2 (New-MarkerText 1 1 1)
                New-Line Daddy 3 (New-MarkerText 3 1 3)
                New-Line CJ 1 (New-MarkerText 1 2 2))
            Code = 'DADDY_STAGE1_STAGE2_ORDER_INVALID'
        }
        [pscustomobject]@{
            Name = '3-2 with no stage 1'
            Records = @(
                New-Line Daddy 1 (New-MarkerText 3 1 3)
                New-Line Daddy 2 (New-MarkerText 2 1 2)
                New-Line CJ 1 (New-MarkerText 1 2 2))
            Code = 'DADDY_STAGE2_STAGE3_ORDER_INVALID'
        }
    )
    foreach ($case in $cases) {
        $result = Test-AotRuntimeCoreSa2Evidence -InputObject $case.Records
        Assert-True (-not $result.Passed) "Ordering case $($case.Name) should fail."
        Assert-HasCode $result $case.Code
    }
}

Invoke-Case 'duplicate and concatenated generations' {
    $duplicates = New-DaddyChainCjArm
    $duplicates += New-Line Daddy 40 (New-MarkerText 14 7 1)
    $duplicateResult = Test-AotRuntimeCoreSa2Evidence -InputObject $duplicates
    Assert-True (-not $duplicateResult.Passed) 'Duplicate stage 1 must fail.'
    Assert-HasCode $duplicateResult 'DADDY_STAGE1_DUPLICATE'

    $duplicateStage3 = New-DaddyChainCjArm
    $duplicateStage3 += New-Line Daddy 40 (New-MarkerText 14 7 3)
    $duplicateStage3Result = Test-AotRuntimeCoreSa2Evidence `
        -InputObject $duplicateStage3
    Assert-True (-not $duplicateStage3Result.Passed) `
        'Duplicate stage 3 must fail.'
    Assert-HasCode $duplicateStage3Result 'DADDY_STAGE3_DUPLICATE'

    $concatenated = @(
        New-DaddyChainCjArm -Generation 7
        New-Line Daddy 100 (New-MarkerText 101 8 1)
        New-Line Daddy 110 (New-MarkerText 102 8 2)
        New-Line CJ 100 (New-MarkerText 101 9 2)
        New-Line Daddy 120 (New-MarkerText 103 8 3)
    )
    $concatResult = Test-AotRuntimeCoreSa2Evidence -InputObject $concatenated
    Assert-True (-not $concatResult.Passed) 'Concatenated attempts must fail.'
    Assert-HasCode $concatResult 'DADDY_STAGE2_DUPLICATE'
    Assert-HasCode $concatResult 'CJ_STAGE2_DUPLICATE'
}

Invoke-Case 'generation and sequence mismatches' {
    $generationMismatch = @(
        New-Line Daddy 1 (New-MarkerText 1 1 1)
        New-Line Daddy 2 (New-MarkerText 2 2 2)
        New-Line Daddy 3 (New-MarkerText 3 2 3)
        New-Line CJ 1 (New-MarkerText 1 4 2)
    )
    $generationResult = Test-AotRuntimeCoreSa2Evidence -InputObject $generationMismatch
    Assert-True (-not $generationResult.Passed) 'Mixed generations must fail.'
    Assert-HasCode $generationResult 'DADDY_STAGE1_STAGE2_GENERATION_MISMATCH'

    $badSequence = @(
        New-Line Daddy 1 (New-MarkerText 5 1 1)
        New-Line Daddy 2 (New-MarkerText 4 1 2)
        New-Line Daddy 3 (New-MarkerText 6 1 3)
        New-Line CJ 1 (New-MarkerText 1 4 2)
    )
    $sequenceResult = Test-AotRuntimeCoreSa2Evidence -InputObject $badSequence
    Assert-True (-not $sequenceResult.Passed) 'Non-increasing marker sequence must fail.'
    Assert-HasCode $sequenceResult 'DADDY_STAGE1_STAGE2_SEQUENCE_INVALID'
}

Invoke-Case 'stage event mismatch and unknown event' {
    $mismatch = New-DaddyChainCjArm
    $mismatch[0].Text = "$prefix seq=11 generation=7 stage=1 event=$($events[2])"
    $mismatchResult = Test-AotRuntimeCoreSa2Evidence -InputObject $mismatch
    Assert-True (-not $mismatchResult.Passed) 'Stage/event mismatch must fail.'
    Assert-HasCode $mismatchResult 'STAGE_EVENT_MISMATCH'

    $unknown = New-DaddyChainCjArm
    $unknown[0].Text = "$prefix seq=11 generation=7 stage=1 event=UNKNOWN"
    $unknownResult = Test-AotRuntimeCoreSa2Evidence -InputObject $unknown
    Assert-True (-not $unknownResult.Passed) 'Unknown event must fail.'
    Assert-HasCode $unknownResult 'EVENT_UNKNOWN'

    $unknownStage = New-DaddyChainCjArm
    $unknownStage[0].Text = $unknownStage[0].Text.Replace(
        'stage=1', 'stage=4')
    $unknownStageResult = Test-AotRuntimeCoreSa2Evidence `
        -InputObject $unknownStage
    Assert-True (-not $unknownStageResult.Passed) 'Unknown stage must fail.'
    Assert-HasCode $unknownStageResult 'STAGE_INVALID'
}

Invoke-Case 'case trailing malformed and multiple markers' {
    $wrongPrefix = New-DaddyChainCjArm
    $wrongPrefix[0].Text = $wrongPrefix[0].Text.Replace(
        '[AOT-RUNTIME-SA2]', '[aot-runtime-sa2]')
    $wrongPrefixResult = Test-AotRuntimeCoreSa2Evidence -InputObject $wrongPrefix
    Assert-HasCode $wrongPrefixResult 'MARKER_PREFIX_CASE_MISMATCH'

    $wrongEventCase = New-DaddyChainCjArm
    $wrongEventCase[0].Text = $wrongEventCase[0].Text.Replace(
        $events[1], $events[1].ToLowerInvariant())
    $wrongEventResult = Test-AotRuntimeCoreSa2Evidence -InputObject $wrongEventCase
    Assert-HasCode $wrongEventResult 'EVENT_UNKNOWN'

    $trailing = New-DaddyChainCjArm
    $trailing[0].Text += ' trailing-junk'
    $trailingResult = Test-AotRuntimeCoreSa2Evidence -InputObject $trailing
    Assert-HasCode $trailingResult 'MARKER_MALFORMED'

    $malformed = New-DaddyChainCjArm
    $malformed[0].Text = $malformed[0].Text.Replace(' generation=', ' extra=1 generation=')
    $malformedResult = Test-AotRuntimeCoreSa2Evidence -InputObject $malformed
    Assert-HasCode $malformedResult 'MARKER_MALFORMED'

    $multiple = New-DaddyChainCjArm
    $multiple[0].Text += ' ' + $multiple[0].Text
    $multipleResult = Test-AotRuntimeCoreSa2Evidence -InputObject $multiple
    Assert-HasCode $multipleResult 'MULTIPLE_MARKERS_IN_LINE'
}

Invoke-Case 'positive uint64 boundaries' {
    $zeroSeq = New-DaddyChainCjArm
    $zeroSeq[0].Text = $zeroSeq[0].Text.Replace('seq=11', 'seq=0')
    Assert-HasCode (Test-AotRuntimeCoreSa2Evidence -InputObject $zeroSeq) `
        'SEQ_NOT_POSITIVE'

    $zeroGeneration = New-DaddyChainCjArm
    $zeroGeneration[0].Text = $zeroGeneration[0].Text.Replace(
        'generation=7', 'generation=0')
    Assert-HasCode (Test-AotRuntimeCoreSa2Evidence -InputObject $zeroGeneration) `
        'GENERATION_NOT_POSITIVE'

    $leadingZeroSeq = New-DaddyChainCjArm
    $leadingZeroSeq[0].Text = $leadingZeroSeq[0].Text.Replace('seq=11', 'seq=011')
    Assert-HasCode (Test-AotRuntimeCoreSa2Evidence -InputObject $leadingZeroSeq) `
        'SEQ_INVALID'

    $leadingZeroGeneration = New-DaddyChainCjArm
    $leadingZeroGeneration[0].Text = $leadingZeroGeneration[0].Text.Replace(
        'generation=7', 'generation=007')
    Assert-HasCode (Test-AotRuntimeCoreSa2Evidence `
            -InputObject $leadingZeroGeneration) 'GENERATION_INVALID'

    $overflowSeq = New-DaddyChainCjArm
    $overflowSeq[0].Text = $overflowSeq[0].Text.Replace(
        'seq=11', 'seq=18446744073709551616')
    Assert-HasCode (Test-AotRuntimeCoreSa2Evidence -InputObject $overflowSeq) `
        'SEQ_OVERFLOW'

    $overflowGeneration = New-DaddyChainCjArm
    $overflowGeneration[0].Text = $overflowGeneration[0].Text.Replace(
        'generation=7', 'generation=18446744073709551616')
    Assert-HasCode (Test-AotRuntimeCoreSa2Evidence -InputObject $overflowGeneration) `
        'GENERATION_OVERFLOW'

    $max = '18446744073709551615'
    $maxRecords = @(
        New-Line Daddy 1 "$prefix seq=1 generation=$max stage=1 event=$($events[1])"
        New-Line Daddy 2 "$prefix seq=2 generation=$max stage=2 event=$($events[2])"
        New-Line Daddy 3 "$prefix seq=$max generation=$max stage=3 event=$($events[3])"
        New-Line CJ 1 "$prefix seq=$max generation=$max stage=2 event=$($events[2])"
    )
    Assert-True (Test-AotRuntimeCoreSa2Evidence -InputObject $maxRecords).Passed `
        'UInt64 maximum should parse when positive and ordered.'
}

Invoke-Case 'input schema and position ambiguity failures' {
    $invalidSide = New-DaddyChainCjArm
    $invalidSide[0].Side = 'daddy'
    Assert-HasCode (Test-AotRuntimeCoreSa2Evidence -InputObject $invalidSide) `
        'INPUT_SIDE_INVALID'

    $ambiguous = New-DaddyChainCjArm
    $ambiguous[0] | Add-Member -NotePropertyName ByteOffset `
        -NotePropertyValue ([uint64]10)
    Assert-HasCode (Test-AotRuntimeCoreSa2Evidence -InputObject $ambiguous) `
        'INPUT_POSITION_AMBIGUOUS'

    $mixed = New-DaddyChainCjArm
    $mixed[1] = New-Line CJ 5 $mixed[1].Text -ByteOffset
    $mixed[2] = New-Line Daddy 20 $mixed[2].Text -ByteOffset
    $mixedResult = Test-AotRuntimeCoreSa2Evidence -InputObject $mixed
    Assert-HasCode $mixedResult 'DADDY_POSITION_KIND_MIXED'

    $duplicatePosition = New-DaddyChainCjArm
    $duplicatePosition[2].Ordinal = 10
    Assert-HasCode (Test-AotRuntimeCoreSa2Evidence -InputObject $duplicatePosition) `
        'DADDY_POSITION_DUPLICATE'
}

Invoke-Case 'input record fields fail closed' {
    Assert-HasCode (Test-AotRuntimeCoreSa2Evidence `
            -InputObject ([object[]]@($null))) 'INPUT_RECORD_NULL'

    Assert-HasCode (Test-AotRuntimeCoreSa2Evidence -InputObject @(
            [pscustomobject]@{ Ordinal = 1; Text = 'noise' }
        )) 'INPUT_SIDE_MISSING'

    Assert-HasCode (Test-AotRuntimeCoreSa2Evidence -InputObject @(
            [pscustomobject]@{ Side = 'Daddy'; Ordinal = 1 }
        )) 'INPUT_TEXT_MISSING'

    Assert-HasCode (Test-AotRuntimeCoreSa2Evidence -InputObject @(
            [pscustomobject]@{ Side = 'Daddy'; Ordinal = 1; Text = 7 }
        )) 'INPUT_TEXT_NOT_STRING'

    Assert-HasCode (Test-AotRuntimeCoreSa2Evidence -InputObject @(
            [pscustomobject]@{
                Side = 'Daddy'; Ordinal = 1; Text = "first`nsecond"
            }
        )) 'INPUT_TEXT_NOT_SINGLE_LINE'

    Assert-HasCode (Test-AotRuntimeCoreSa2Evidence -InputObject @(
            [pscustomobject]@{ Side = 'Daddy'; Text = 'noise' }
        )) 'INPUT_POSITION_MISSING'

    Assert-HasCode (Test-AotRuntimeCoreSa2Evidence -InputObject @(
            [pscustomobject]@{
                Side = 'Daddy'; Ordinal = '-1'; Text = 'noise'
            }
        )) 'INPUT_ORDINAL_INVALID'

    Assert-HasCode (Test-AotRuntimeCoreSa2Evidence -InputObject @(
            [pscustomobject]@{
                Side = 'Daddy'
                ByteOffset = '18446744073709551616'
                Text = 'noise'
            }
        )) 'INPUT_BYTE_OFFSET_OVERFLOW'
}

Invoke-Case 'required marker exists only before baseline' {
    $all = @(
        New-Line Daddy 10 (New-MarkerText 1 1 1) -ByteOffset
        New-Line Daddy 20 (New-MarkerText 2 1 2) -ByteOffset
        New-Line Daddy 30 (New-MarkerText 3 1 3) -ByteOffset
        New-Line CJ 40 (New-MarkerText 1 2 2) -ByteOffset
        New-Line Daddy 100 'new run: lobby' -ByteOffset
        New-Line CJ 100 'new run: connecting please wait' -ByteOffset
    )
    $postBaseline = @($all | Where-Object ByteOffset -ge 100)
    $result = Test-AotRuntimeCoreSa2Evidence -InputObject $postBaseline
    Assert-True (-not $result.Passed) `
        'Markers that exist only before the caller baseline must not pass.'
    Assert-HasCode $result 'DADDY_STAGE2_MISSING'
    Assert-HasCode $result 'CJ_STAGE2_MISSING'
}

Write-Output ('PASS: AOT_RUNTIME_CORE_SA2_EVIDENCE assertions={0} cases={1}' -f
    $script:AssertionCount, $script:CaseCount)
