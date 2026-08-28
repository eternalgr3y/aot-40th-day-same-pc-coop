[CmdletBinding(DefaultParameterSetName = 'Live')]
param(
    [Parameter(Mandatory = $true, ParameterSetName = 'Live')]
    [ValidateRange(1, [int]::MaxValue)]
    [int]$TargetPid,

    [Parameter(Mandatory = $true, ParameterSetName = 'Fixture')]
    [string]$ClassificationLine,

    [Parameter(Mandatory = $true, ParameterSetName = 'Fixture')]
    [string]$UiJsonPath
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)

function Write-GateResult {
    param(
        [Parameter(Mandatory = $true)][ValidateSet('ALLOW', 'HOLD', 'FAIL')][string]$Decision,
        [Parameter(Mandatory = $true)][string]$Reason,
        [Parameter(Mandatory = $true)][int]$Code
    )
    Write-Output ("{0} daddy_continue {1}" -f $Decision, $Reason)
    exit $Code
}

try {
    if ($PSCmdlet.ParameterSetName -eq 'Live') {
        $ClassificationLine = ((& (Join-Path $root 'classify_screen.ps1') `
            -ProcId $TargetPid) -join ' ').Trim()
        $ui = @(& (Join-Path $root 'dump_aot_ui.ps1') -TargetPid $TargetPid)
        $secondClassificationLine = ((& (Join-Path $root 'classify_screen.ps1') `
            -ProcId $TargetPid) -join ' ').Trim()
        $classificationLines = @($ClassificationLine, $secondClassificationLine)
    } else {
        if (-not (Test-Path -LiteralPath $UiJsonPath -PathType Leaf)) {
            Write-GateResult -Decision FAIL -Reason 'fixture-ui-json-missing' -Code 20
        }
        $decoded = Get-Content -Raw -LiteralPath $UiJsonPath | ConvertFrom-Json
        $ui = @()
        foreach ($item in $decoded) { $ui += $item }
        $classificationLines = @($ClassificationLine)
    }

    # The known blind spot reports SAVE_SLOT_1 even after the embedded options
    # panel appears. A future classifier may correctly report
    # SAVE_OPTIONS_CONTINUE. Both forms must still prove the middle slot.
    foreach ($line in $classificationLines) {
        if ($line -match '(?i)\bOVERWRITE\b') {
            Write-GateResult -Decision FAIL -Reason 'overwrite-text-present' -Code 20
        }
        if ($line -notmatch "(?i)\bocr='[^']*\bCONTINUE\b[^']*'") {
            Write-GateResult -Decision HOLD -Reason 'fresh-ocr-lacks-continue' -Code 10
        }
        if ($line -notmatch '(?i)^SAVE_(?:SLOT_1|OPTIONS_CONTINUE)\b') {
            Write-GateResult -Decision HOLD -Reason 'classification-is-not-continue-on-middle-slot' -Code 10
        }
        if ($line -notmatch '(?i)(?:^|[; ])slot=1(?:;|\s|$)') {
            Write-GateResult -Decision HOLD -Reason 'middle-slot-diagnostic-missing' -Code 10
        }
    }

    $managers = @($ui | Where-Object { $_.Kind -eq 'Manager' })
    if ($managers.Count -ne 1) {
        Write-GateResult -Decision FAIL -Reason 'manager-count-is-not-one' -Code 20
    }
    $manager = $managers[0]
    if ($manager.StableSnapshot -ne $true -or [int64]$manager.CaptureConsume -ne 1) {
        Write-GateResult -Decision HOLD -Reason 'ui-manager-is-not-stable-and-consuming' -Code 10
    }

    $scenes = @($ui | Where-Object {
        $_.Kind -eq 'Scene' -and $_.Name -ceq 'AO3Screens.F13_Save'
    })
    if ($scenes.Count -ne 1) {
        Write-GateResult -Decision FAIL -Reason 'f13-save-scene-count-is-not-one' -Code 20
    }
    $scene = $scenes[0]
    if ([int64]$scene.Open -ne 1 -or [int64]$scene.InputEligible -ne 1 -or
        $scene.Captured -ne $true) {
        Write-GateResult -Decision HOLD -Reason 'f13-save-scene-is-not-open-eligible-captured' -Code 10
    }

    Write-GateResult -Decision ALLOW -Reason 'middle-slot-continue-and-stable-f13-save-proved' -Code 0
} catch {
    Write-GateResult -Decision FAIL -Reason ("evidence-error={0}" -f
        ($_.Exception.Message -replace '\s+', '_')) -Code 20
}
