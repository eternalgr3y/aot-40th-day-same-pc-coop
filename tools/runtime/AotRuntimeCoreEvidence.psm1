Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:Sa2AcceptPrefix = '[AOT-RUNTIME-SA2][ACCEPT]'
$script:Sa2StageEvents = @{
    1 = 'PRECONNECT_XSA1_PREPARED_FOR_GUEST'
    2 = 'XNETCONNECT_MANAGER_ARMED'
    3 = 'POSTCONNECT_XSA1_RETRANSMIT_CONSUMED_ACK_SENT'
}

function New-AotSa2EvidenceError {
    param(
        [Parameter(Mandatory = $true)][string]$Code,
        [Parameter(Mandatory = $true)][string]$Message,
        [AllowNull()][string]$Side = $null,
        [AllowNull()][object]$InputIndex = $null,
        [AllowNull()][string]$PositionKind = $null,
        [AllowNull()][object]$Position = $null
    )

    return [pscustomobject][ordered]@{
        Code = $Code
        Message = $Message
        Side = $Side
        InputIndex = $InputIndex
        PositionKind = $PositionKind
        Position = $Position
    }
}

function Get-AotSa2Property {
    param(
        [Parameter(Mandatory = $true)][object]$InputObject,
        [Parameter(Mandatory = $true)][string]$Name
    )

    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return [pscustomobject]@{ Exists = $false; Value = $null }
    }
    return [pscustomobject]@{ Exists = $true; Value = $property.Value }
}

function ConvertTo-AotSa2UInt64 {
    param(
        [AllowNull()][object]$Value,
        [Parameter(Mandatory = $true)][string]$InvalidCode,
        [Parameter(Mandatory = $true)][string]$OverflowCode,
        [AllowNull()][string]$ZeroCode = $null
    )

    if ($null -eq $Value) {
        return [pscustomobject]@{ Valid = $false; Code = $InvalidCode; Value = $null }
    }
    $text = [string]$Value
    if ($text -cnotmatch '^[0-9]+$') {
        return [pscustomobject]@{ Valid = $false; Code = $InvalidCode; Value = $null }
    }
    if ($null -ne $ZeroCode -and $text -cnotmatch '^[1-9][0-9]*$') {
        $code = if ($text -ceq '0') { $ZeroCode } else { $InvalidCode }
        return [pscustomobject]@{ Valid = $false; Code = $code; Value = $null }
    }
    [uint64]$number = 0
    if (-not [uint64]::TryParse(
            $text, [Globalization.NumberStyles]::None,
            [Globalization.CultureInfo]::InvariantCulture, [ref]$number)) {
        return [pscustomobject]@{ Valid = $false; Code = $OverflowCode; Value = $null }
    }
    if ($null -ne $ZeroCode -and $number -eq 0) {
        return [pscustomobject]@{ Valid = $false; Code = $ZeroCode; Value = $null }
    }
    return [pscustomobject]@{ Valid = $true; Code = $null; Value = $number }
}

function Get-AotSa2SortedErrorCodes {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()][object[]]$Errors
    )

    [string[]]$codes = @($Errors | ForEach-Object { [string]$_.Code } |
        Select-Object -Unique)
    [Array]::Sort($codes, [StringComparer]::Ordinal)
    return [string[]]$codes
}

function Invoke-AotSa2LineConversion {
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject]$InputBuffer
    )

    [Collections.Generic.List[object]]$Items = $InputBuffer.Items
    $parsed = [Collections.Generic.List[object]]::new()
    $errors = [Collections.Generic.List[object]]::new()
    $noiseCount = 0
    $markerPattern = [regex]::Escape($script:Sa2AcceptPrefix)
    $markerOptions = [Text.RegularExpressions.RegexOptions]::IgnoreCase -bor
        [Text.RegularExpressions.RegexOptions]::CultureInvariant
    $bodyPattern = '^' + [regex]::Escape($script:Sa2AcceptPrefix) +
        ' seq=(?<Seq>[^ \t\r\n]+)' +
        ' generation=(?<Generation>[^ \t\r\n]+)' +
        ' stage=(?<Stage>[^ \t\r\n]+)' +
        ' event=(?<Event>[^ \t\r\n]+)\z'
    $bodyRegex = [regex]::new(
        $bodyPattern, [Text.RegularExpressions.RegexOptions]::CultureInvariant)

    for ($inputIndex = 0; $inputIndex -lt $Items.Count; $inputIndex++) {
        $item = $Items[$inputIndex]
        if ($null -eq $item) {
            $errors.Add((New-AotSa2EvidenceError -Code 'INPUT_RECORD_NULL' `
                -Message 'An input record was null.' -InputIndex $inputIndex))
            continue
        }

        $sideProperty = Get-AotSa2Property -InputObject $item -Name 'Side'
        if (-not $sideProperty.Exists -or $null -eq $sideProperty.Value) {
            $errors.Add((New-AotSa2EvidenceError -Code 'INPUT_SIDE_MISSING' `
                -Message 'An input record did not contain Side.' `
                -InputIndex $inputIndex))
            continue
        }
        $side = [string]$sideProperty.Value
        if ($side -cne 'Daddy' -and $side -cne 'CJ') {
            $errors.Add((New-AotSa2EvidenceError -Code 'INPUT_SIDE_INVALID' `
                -Message "Side must be exactly Daddy or CJ; found '$side'." `
                -Side $side -InputIndex $inputIndex))
            continue
        }

        $textProperty = Get-AotSa2Property -InputObject $item -Name 'Text'
        if (-not $textProperty.Exists -or $null -eq $textProperty.Value) {
            $errors.Add((New-AotSa2EvidenceError -Code 'INPUT_TEXT_MISSING' `
                -Message 'An input record did not contain Text.' `
                -Side $side -InputIndex $inputIndex))
            continue
        }
        if ($textProperty.Value -isnot [string]) {
            $errors.Add((New-AotSa2EvidenceError -Code 'INPUT_TEXT_NOT_STRING' `
                -Message 'Text must be a string.' -Side $side `
                -InputIndex $inputIndex))
            continue
        }
        $line = [string]$textProperty.Value
        if ($line.IndexOf("`r", [StringComparison]::Ordinal) -ge 0 -or
            $line.IndexOf("`n", [StringComparison]::Ordinal) -ge 0) {
            $errors.Add((New-AotSa2EvidenceError `
                -Code 'INPUT_TEXT_NOT_SINGLE_LINE' `
                -Message 'Text must contain exactly one complete line.' `
                -Side $side -InputIndex $inputIndex))
            continue
        }

        $ordinalProperty = Get-AotSa2Property -InputObject $item -Name 'Ordinal'
        $offsetProperty = Get-AotSa2Property -InputObject $item -Name 'ByteOffset'
        $hasOrdinal = $ordinalProperty.Exists -and $null -ne $ordinalProperty.Value -and
            [string]$ordinalProperty.Value -cne ''
        $hasOffset = $offsetProperty.Exists -and $null -ne $offsetProperty.Value -and
            [string]$offsetProperty.Value -cne ''
        if (-not $hasOrdinal -and -not $hasOffset) {
            $errors.Add((New-AotSa2EvidenceError -Code 'INPUT_POSITION_MISSING' `
                -Message 'An input record must contain Ordinal or ByteOffset.' `
                -Side $side -InputIndex $inputIndex))
            continue
        }
        if ($hasOrdinal -and $hasOffset) {
            $errors.Add((New-AotSa2EvidenceError `
                -Code 'INPUT_POSITION_AMBIGUOUS' `
                -Message 'An input record must contain exactly one of Ordinal or ByteOffset.' `
                -Side $side -InputIndex $inputIndex))
            continue
        }

        $ordinal = $null
        if ($hasOrdinal) {
            $ordinalResult = ConvertTo-AotSa2UInt64 -Value $ordinalProperty.Value `
                -InvalidCode 'INPUT_ORDINAL_INVALID' `
                -OverflowCode 'INPUT_ORDINAL_OVERFLOW'
            if (-not $ordinalResult.Valid) {
                $errors.Add((New-AotSa2EvidenceError -Code $ordinalResult.Code `
                    -Message 'Ordinal must be an unsigned 64-bit integer.' `
                    -Side $side -InputIndex $inputIndex `
                    -PositionKind 'Ordinal' -Position $ordinalProperty.Value))
                continue
            }
            $ordinal = [uint64]$ordinalResult.Value
        }

        $byteOffset = $null
        if ($hasOffset) {
            $offsetResult = ConvertTo-AotSa2UInt64 -Value $offsetProperty.Value `
                -InvalidCode 'INPUT_BYTE_OFFSET_INVALID' `
                -OverflowCode 'INPUT_BYTE_OFFSET_OVERFLOW'
            if (-not $offsetResult.Valid) {
                $errors.Add((New-AotSa2EvidenceError -Code $offsetResult.Code `
                    -Message 'ByteOffset must be an unsigned 64-bit integer.' `
                    -Side $side -InputIndex $inputIndex `
                    -PositionKind 'ByteOffset' -Position $offsetProperty.Value))
                continue
            }
            $byteOffset = [uint64]$offsetResult.Value
        }
        $positionKind = if ($hasOffset) { 'ByteOffset' } else { 'Ordinal' }
        [uint64]$position = if ($hasOffset) { $byteOffset } else { $ordinal }

        $markerMatches = [regex]::Matches($line, $markerPattern, $markerOptions)
        if ($markerMatches.Count -eq 0) {
            $noiseCount++
            continue
        }
        if ($markerMatches.Count -gt 1) {
            $errors.Add((New-AotSa2EvidenceError `
                -Code 'MULTIPLE_MARKERS_IN_LINE' `
                -Message 'A line contained more than one SA2 acceptance marker.' `
                -Side $side -InputIndex $inputIndex `
                -PositionKind $positionKind -Position $position))
            continue
        }
        if ($markerMatches[0].Value -cne $script:Sa2AcceptPrefix) {
            $errors.Add((New-AotSa2EvidenceError `
                -Code 'MARKER_PREFIX_CASE_MISMATCH' `
                -Message 'The SA2 acceptance marker prefix is case-sensitive.' `
                -Side $side -InputIndex $inputIndex `
                -PositionKind $positionKind -Position $position))
            continue
        }

        $markerIndex = $line.IndexOf(
            $script:Sa2AcceptPrefix, [StringComparison]::Ordinal)
        $markerText = $line.Substring($markerIndex)
        $bodyMatch = $bodyRegex.Match($markerText)
        if (-not $bodyMatch.Success) {
            $errors.Add((New-AotSa2EvidenceError -Code 'MARKER_MALFORMED' `
                -Message 'The SA2 acceptance marker did not match the exact field grammar.' `
                -Side $side -InputIndex $inputIndex `
                -PositionKind $positionKind -Position $position))
            continue
        }

        $seqResult = ConvertTo-AotSa2UInt64 -Value $bodyMatch.Groups['Seq'].Value `
            -InvalidCode 'SEQ_INVALID' -OverflowCode 'SEQ_OVERFLOW' `
            -ZeroCode 'SEQ_NOT_POSITIVE'
        $generationResult = ConvertTo-AotSa2UInt64 `
            -Value $bodyMatch.Groups['Generation'].Value `
            -InvalidCode 'GENERATION_INVALID' `
            -OverflowCode 'GENERATION_OVERFLOW' `
            -ZeroCode 'GENERATION_NOT_POSITIVE'
        $lineHasError = $false
        if (-not $seqResult.Valid) {
            $errors.Add((New-AotSa2EvidenceError -Code $seqResult.Code `
                -Message 'seq must be a positive unsigned 64-bit integer.' `
                -Side $side -InputIndex $inputIndex `
                -PositionKind $positionKind -Position $position))
            $lineHasError = $true
        }
        if (-not $generationResult.Valid) {
            $errors.Add((New-AotSa2EvidenceError -Code $generationResult.Code `
                -Message 'generation must be a positive unsigned 64-bit integer.' `
                -Side $side -InputIndex $inputIndex `
                -PositionKind $positionKind -Position $position))
            $lineHasError = $true
        }

        $stageText = $bodyMatch.Groups['Stage'].Value
        if ($stageText -cnotmatch '^[123]$') {
            $errors.Add((New-AotSa2EvidenceError -Code 'STAGE_INVALID' `
                -Message 'stage must be exactly 1, 2, or 3.' `
                -Side $side -InputIndex $inputIndex `
                -PositionKind $positionKind -Position $position))
            $lineHasError = $true
            $stage = $null
        } else {
            $stage = [int]$stageText
        }

        $event = $bodyMatch.Groups['Event'].Value
        $knownEvent = $false
        foreach ($candidate in $script:Sa2StageEvents.Values) {
            if ($event -ceq $candidate) {
                $knownEvent = $true
                break
            }
        }
        if (-not $knownEvent) {
            $errors.Add((New-AotSa2EvidenceError -Code 'EVENT_UNKNOWN' `
                -Message "The SA2 acceptance event '$event' is unknown or has the wrong case." `
                -Side $side -InputIndex $inputIndex `
                -PositionKind $positionKind -Position $position))
            $lineHasError = $true
        } elseif ($null -ne $stage -and
            $event -cne $script:Sa2StageEvents[$stage]) {
            $errors.Add((New-AotSa2EvidenceError `
                -Code 'STAGE_EVENT_MISMATCH' `
                -Message "stage $stage does not match event '$event'." `
                -Side $side -InputIndex $inputIndex `
                -PositionKind $positionKind -Position $position))
            $lineHasError = $true
        }
        if ($lineHasError) { continue }

        $parsed.Add([pscustomobject][ordered]@{
            Side = $side
            InputIndex = $inputIndex
            PositionKind = $positionKind
            Position = $position
            Ordinal = $ordinal
            ByteOffset = $byteOffset
            Seq = [uint64]$seqResult.Value
            Generation = [uint64]$generationResult.Value
            Stage = $stage
            Event = $event
            Text = $line
        })
    }

    foreach ($side in 'Daddy', 'CJ') {
        $sideRecords = @($parsed | Where-Object { $_.Side -ceq $side })
        $positionKinds = @($sideRecords | ForEach-Object PositionKind |
            Sort-Object -Unique)
        if ($positionKinds.Count -gt 1) {
            $errors.Add((New-AotSa2EvidenceError `
                -Code ($side.ToUpperInvariant() + '_POSITION_KIND_MIXED') `
                -Message "$side marker records mix Ordinal and ByteOffset ordering." `
                -Side $side))
            continue
        }
        $duplicatePositions = @($sideRecords | Group-Object Position |
            Where-Object Count -gt 1)
        if ($duplicatePositions.Count -gt 0) {
            $errors.Add((New-AotSa2EvidenceError `
                -Code ($side.ToUpperInvariant() + '_POSITION_DUPLICATE') `
                -Message "$side marker records contain duplicate positions." `
                -Side $side))
        }
    }

    $parsedArray = @($parsed | Sort-Object Side, Position)
    $errorArray = $errors.ToArray()
    return [pscustomobject][ordered]@{
        SchemaVersion = 1
        MarkerPrefix = $script:Sa2AcceptPrefix
        InputRecordCount = $Items.Count
        NoiseRecordCount = $noiseCount
        ParsedRecordCount = $parsedArray.Count
        ParseSucceeded = ($errorArray.Count -eq 0)
        ErrorCodes = @(Get-AotSa2SortedErrorCodes -Errors $errorArray)
        Errors = $errorArray
        Records = $parsedArray
    }
}

<#
.SYNOPSIS
Parses complete post-baseline Xenia log records into exact SA2 markers.

.DESCRIPTION
This function performs no file or process I/O. The caller owns the log-file
baseline and must supply only complete lines appended after that baseline.
Each record must contain Side (Daddy or CJ), Text, and exactly one unsigned
64-bit ordering field: Ordinal or ByteOffset. Noise is retained only as a
count; any malformed acceptance-prefix line fails parsing.

.PARAMETER InputObject
One or more post-baseline records. Records may be supplied as an array or
through the pipeline.
#>
function ConvertFrom-AotRuntimeCoreSa2Lines {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, ValueFromPipeline = $true)]
        [AllowNull()][AllowEmptyCollection()][object[]]$InputObject
    )

    begin { $items = [Collections.Generic.List[object]]::new() }
    process {
        if ($null -eq $InputObject) {
            $items.Add($null)
        } else {
            foreach ($item in $InputObject) { $items.Add($item) }
        }
    }
    end {
        return Invoke-AotSa2LineConversion -InputBuffer (
            [pscustomobject]@{ Items = $items })
    }
}

<#
.SYNOPSIS
Reduces complete post-baseline log records against the SA2 acceptance rule.

.DESCRIPTION
Requires exactly one stage-2 arm marker on each side and at least one
same-side, same-generation, strictly ordered 1-2-3 chain. The other side may
contain stage 2 only, a valid 1-2 pair, or a valid 2-3 pair. Markers are never
ordered across processes. This pure reducer does not establish or verify the
caller-owned file handle, EOF baseline, PID, or process start time.

.PARAMETER InputObject
One or more records using the same schema as
ConvertFrom-AotRuntimeCoreSa2Lines.
#>
function Test-AotRuntimeCoreSa2Evidence {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, ValueFromPipeline = $true)]
        [AllowNull()][AllowEmptyCollection()][object[]]$InputObject
    )

    begin { $items = [Collections.Generic.List[object]]::new() }
    process {
        if ($null -eq $InputObject) {
            $items.Add($null)
        } else {
            foreach ($item in $InputObject) { $items.Add($item) }
        }
    }
    end {
        $conversion = Invoke-AotSa2LineConversion -InputBuffer (
            [pscustomobject]@{ Items = $items })
        $errors = [Collections.Generic.List[object]]::new()
        foreach ($error in $conversion.Errors) { $errors.Add($error) }

        $sideResults = [ordered]@{}
        foreach ($side in 'Daddy', 'CJ') {
            $sideRecords = @($conversion.Records |
                Where-Object { $_.Side -ceq $side } | Sort-Object Position)
            $stage1 = @($sideRecords | Where-Object Stage -eq 1)
            $stage2 = @($sideRecords | Where-Object Stage -eq 2)
            $stage3 = @($sideRecords | Where-Object Stage -eq 3)
            $sideCode = $side.ToUpperInvariant()

            if ($stage1.Count -gt 1) {
                $errors.Add((New-AotSa2EvidenceError `
                    -Code ($sideCode + '_STAGE1_DUPLICATE') `
                    -Message "$side has more than one stage-1 marker." -Side $side))
            }
            if ($stage2.Count -eq 0) {
                $errors.Add((New-AotSa2EvidenceError `
                    -Code ($sideCode + '_STAGE2_MISSING') `
                    -Message "$side does not have its required stage-2 marker." `
                    -Side $side))
            } elseif ($stage2.Count -gt 1) {
                $errors.Add((New-AotSa2EvidenceError `
                    -Code ($sideCode + '_STAGE2_DUPLICATE') `
                    -Message "$side has more than one stage-2 marker." -Side $side))
            }
            if ($stage3.Count -gt 1) {
                $errors.Add((New-AotSa2EvidenceError `
                    -Code ($sideCode + '_STAGE3_DUPLICATE') `
                    -Message "$side has more than one stage-3 marker." -Side $side))
            }
            $stage12Valid = $false
            if ($stage1.Count -eq 1 -and $stage2.Count -eq 1) {
                $stage12Valid = $true
                if ($stage1[0].PositionKind -cne $stage2[0].PositionKind -or
                    $stage1[0].Position -ge $stage2[0].Position) {
                    $errors.Add((New-AotSa2EvidenceError `
                        -Code ($sideCode + '_STAGE1_STAGE2_ORDER_INVALID') `
                        -Message "$side stage 1 is not before stage 2." -Side $side))
                    $stage12Valid = $false
                }
                if ($stage1[0].Seq -ge $stage2[0].Seq) {
                    $errors.Add((New-AotSa2EvidenceError `
                        -Code ($sideCode + '_STAGE1_STAGE2_SEQUENCE_INVALID') `
                        -Message "$side stage-1 seq is not less than stage-2 seq." `
                        -Side $side))
                    $stage12Valid = $false
                }
                if ($stage1[0].Generation -ne $stage2[0].Generation) {
                    $errors.Add((New-AotSa2EvidenceError `
                        -Code ($sideCode + '_STAGE1_STAGE2_GENERATION_MISMATCH') `
                        -Message "$side stages 1 and 2 use different generations." `
                        -Side $side))
                    $stage12Valid = $false
                }
            }

            $stage23Valid = $false
            if ($stage2.Count -eq 1 -and $stage3.Count -eq 1) {
                $stage23Valid = $true
                if ($stage2[0].PositionKind -cne $stage3[0].PositionKind -or
                    $stage2[0].Position -ge $stage3[0].Position) {
                    $errors.Add((New-AotSa2EvidenceError `
                        -Code ($sideCode + '_STAGE2_STAGE3_ORDER_INVALID') `
                        -Message "$side stage 2 is not before stage 3." -Side $side))
                    $stage23Valid = $false
                }
                if ($stage2[0].Seq -ge $stage3[0].Seq) {
                    $errors.Add((New-AotSa2EvidenceError `
                        -Code ($sideCode + '_STAGE2_STAGE3_SEQUENCE_INVALID') `
                        -Message "$side stage-2 seq is not less than stage-3 seq." `
                        -Side $side))
                    $stage23Valid = $false
                }
                if ($stage2[0].Generation -ne $stage3[0].Generation) {
                    $errors.Add((New-AotSa2EvidenceError `
                        -Code ($sideCode + '_STAGE2_STAGE3_GENERATION_MISMATCH') `
                        -Message "$side stages 2 and 3 use different generations." `
                        -Side $side))
                    $stage23Valid = $false
                }
            }

            $completeChain = $stage1.Count -eq 1 -and $stage2.Count -eq 1 -and
                $stage3.Count -eq 1 -and $stage12Valid -and $stage23Valid
            $sideResults[$side] = [pscustomobject][ordered]@{
                Stage1Count = $stage1.Count
                Stage2Count = $stage2.Count
                Stage3Count = $stage3.Count
                CompleteChain = $completeChain
                CompleteGeneration = if ($completeChain) {
                    [uint64]$stage2[0].Generation
                } else { $null }
                Records = $sideRecords
            }
        }

        $completeSides = @('Daddy', 'CJ' | Where-Object {
            [bool]$sideResults[$_].CompleteChain
        })
        if ($completeSides.Count -eq 0) {
            $errors.Add((New-AotSa2EvidenceError `
                -Code 'NO_COMPLETE_SAME_SIDE_CHAIN' `
                -Message 'Neither side has a strict generation-bound 1-2-3 chain.'))
        }

        $errorArray = $errors.ToArray()
        return [pscustomobject][ordered]@{
            SchemaVersion = 1
            Passed = ($errorArray.Count -eq 0)
            ErrorCodes = @(Get-AotSa2SortedErrorCodes -Errors $errorArray)
            Errors = $errorArray
            InputRecordCount = $conversion.InputRecordCount
            NoiseRecordCount = $conversion.NoiseRecordCount
            ParsedRecordCount = $conversion.ParsedRecordCount
            Records = $conversion.Records
            Sides = [pscustomobject]$sideResults
            CompleteChainSides = $completeSides
        }
    }
}

Export-ModuleMember -Function ConvertFrom-AotRuntimeCoreSa2Lines,
    Test-AotRuntimeCoreSa2Evidence
