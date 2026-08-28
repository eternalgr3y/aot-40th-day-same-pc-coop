[CmdletBinding(DefaultParameterSetName = 'Live')]
param(
    [Parameter(Mandatory = $true, ParameterSetName = 'Live')]
    [ValidateRange(1, [int]::MaxValue)]
    [int]$TargetPid,

    [Parameter(Mandatory = $true, ParameterSetName = 'Fixture')]
    [string]$ClassificationLine,

    [Parameter(Mandatory = $true, ParameterSetName = 'Fixture')]
    [string]$UiJsonPath,

    [Parameter(Mandatory = $true)]
    [string]$RigDir,

    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[0-9A-Fa-f]{16}$')]
    [string]$ProfileXuid,

    [ValidatePattern('^[0-9A-Fa-f]{8}$')]
    [string]$TitleId = '454108D8',

    [ValidateRange(2, 2)]
    [int]$Slot = 2
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)

function Write-GateResult {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('ALLOW', 'HOLD', 'FAIL')]
        [string]$Decision,
        [Parameter(Mandatory = $true)][string]$Reason,
        [Parameter(Mandatory = $true)][int]$Code
    )
    Write-Output ("{0} cj_empty_slot {1}" -f $Decision, $Reason)
    exit $Code
}

try {
    $resolvedRig = [IO.Path]::GetFullPath($RigDir).TrimEnd('\')
    if (-not (Test-Path -LiteralPath $resolvedRig -PathType Container)) {
        Write-GateResult -Decision FAIL -Reason 'rig-directory-missing' -Code 20
    }

    $titleRoot = Join-Path $resolvedRig (
        'content\{0}\{1}' -f $ProfileXuid.ToUpperInvariant(),
        $TitleId.ToUpperInvariant())
    $container = Join-Path $titleRoot (
        '00000001\default_checkpoint_{0}.sav' -f $Slot)
    $header = Join-Path $titleRoot (
        'Headers\00000001\default_checkpoint_{0}.sav.header' -f $Slot)

    function Test-JoinSlotStorageEmpty {
        -not (Test-Path -LiteralPath $container) -and
        -not (Test-Path -LiteralPath $header)
    }

    if (-not (Test-JoinSlotStorageEmpty)) {
        Write-GateResult -Decision FAIL `
            -Reason 'right-slot-storage-is-occupied' -Code 20
    }

    if ($PSCmdlet.ParameterSetName -eq 'Live') {
        $first = ((& (Join-Path $root 'classify_screen.ps1') `
            -ProcId $TargetPid) -join ' ').Trim()
        $ui = @(& (Join-Path $root 'dump_aot_ui.ps1') `
            -TargetPid $TargetPid)
        $second = ((& (Join-Path $root 'classify_screen.ps1') `
            -ProcId $TargetPid) -join ' ').Trim()
        $classificationLines = @($first, $second)
    } else {
        if (-not (Test-Path -LiteralPath $UiJsonPath -PathType Leaf)) {
            Write-GateResult -Decision FAIL `
                -Reason 'fixture-ui-json-missing' -Code 20
        }
        $decoded = Get-Content -Raw -LiteralPath $UiJsonPath | ConvertFrom-Json
        $ui = @()
        foreach ($item in $decoded) { $ui += $item }
        $classificationLines = @($ClassificationLine)
    }

    foreach ($line in $classificationLines) {
        if ($line -match '(?i)\b(?:CONTINUE|OVERWRITE)\b') {
            Write-GateResult -Decision FAIL `
                -Reason 'occupied-or-overwrite-text-present' -Code 20
        }
        if ($line -notmatch '(?i)^SAVE_SLOT_2\b') {
            Write-GateResult -Decision HOLD `
                -Reason 'classification-is-not-right-slot' -Code 10
        }
        $confidenceMatch = [regex]::Match($line,
            '(?i)(?:^|\s)confidence=(?<value>\d+(?:\.\d+)?)\b')
        $confidence = 0.0
        if (-not $confidenceMatch.Success -or
            -not [double]::TryParse($confidenceMatch.Groups['value'].Value,
                [Globalization.NumberStyles]::Float,
                [Globalization.CultureInfo]::InvariantCulture,
                [ref]$confidence) -or $confidence -lt 0.90) {
            Write-GateResult -Decision HOLD `
                -Reason 'right-slot-confidence-is-too-low' -Code 10
        }
        if ($line -notmatch '(?i)(?:^|[; ])slot=2(?:;|\s|$)') {
            Write-GateResult -Decision HOLD `
                -Reason 'right-slot-diagnostic-missing' -Code 10
        }
    }

    $managers = @($ui | Where-Object { $_.Kind -eq 'Manager' })
    if ($managers.Count -ne 1) {
        Write-GateResult -Decision FAIL `
            -Reason 'manager-count-is-not-one' -Code 20
    }
    $manager = $managers[0]
    if ($manager.StableSnapshot -ne $true -or
        [int64]$manager.CaptureConsume -ne 1) {
        Write-GateResult -Decision HOLD `
            -Reason 'ui-manager-is-not-stable-and-consuming' -Code 10
    }

    $scenes = @($ui | Where-Object {
        $_.Kind -eq 'Scene' -and $_.Name -ceq 'AO3Screens.F13_Save'
    })
    if ($scenes.Count -ne 1) {
        Write-GateResult -Decision FAIL `
            -Reason 'f13-save-scene-count-is-not-one' -Code 20
    }
    $scene = $scenes[0]
    if ([int64]$scene.Open -ne 1 -or [int64]$scene.InputEligible -ne 1 -or
        $scene.Captured -ne $true) {
        Write-GateResult -Decision HOLD `
            -Reason 'f13-save-scene-is-not-open-eligible-captured' -Code 10
    }

    # Recheck after both visual samples and the guest-memory snapshot so an
    # occupied container appearing during evidence collection cannot inherit a
    # stale approval.
    if (-not (Test-JoinSlotStorageEmpty)) {
        Write-GateResult -Decision FAIL `
            -Reason 'right-slot-storage-became-occupied' -Code 20
    }

    Write-GateResult -Decision ALLOW `
        -Reason 'right-slot-empty-and-stable-f13-save-proved' -Code 0
} catch {
    Write-GateResult -Decision FAIL -Reason ("evidence-error={0}" -f
        ($_.Exception.Message -replace '\s+', '_')) -Code 20
}
