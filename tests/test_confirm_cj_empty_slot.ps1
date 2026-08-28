$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$gate = Join-Path $root 'tools\runtime\confirm_cj_empty_slot.ps1'
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) (
    'aot_cj_empty_slot_' + [guid]::NewGuid().ToString('N'))
$profileXuid = 'E000B2B252222222'
$titleId = '454108D8'
New-Item -ItemType Directory -Path $tempRoot | Out-Null
$uiPath = Join-Path $tempRoot 'ui.json'
$goodUi = @(
    [ordered]@{
        Kind = 'Manager'; StableSnapshot = $true; CaptureConsume = 1
    },
    [ordered]@{
        Kind = 'Scene'; Name = 'AO3Screens.F13_Save'; Open = 1
        InputEligible = 1; Captured = $true
    }
)
$goodUi | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $uiPath `
    -Encoding UTF8

function Invoke-Gate {
    param(
        [string]$Line,
        [string]$RigDir = $tempRoot,
        [string]$UiPath = $uiPath)
    $output = & powershell.exe -NoProfile -NonInteractive `
        -ExecutionPolicy Bypass -File $gate `
        -ClassificationLine $Line -RigDir $RigDir `
        -ProfileXuid $profileXuid -TitleId $titleId -Slot 2 `
        -UiJsonPath $UiPath 2>&1
    [pscustomobject]@{ Code = $LASTEXITCODE; Output = ($output -join ' ') }
}

function Assert-Decision {
    param([string]$Expected, [string]$Line, [string]$Label)
    $result = Invoke-Gate -Line $Line
    $expectedCode = @{ ALLOW = 0; HOLD = 10; FAIL = 20 }[$Expected]
    if ($result.Output -notmatch ('^' + [regex]::Escape($Expected) + '\b') -or
        $result.Code -ne $expectedCode) {
        throw ("${Label}: expected $Expected/$expectedCode, got " +
            "$($result.Output)/$($result.Code)")
    }
}

try {
    $right = "SAVE_SLOT_2 confidence=0.90 ocr='SELECT SAVE SLOT EMPTY' slotMode=classifier960-right;slot=2;rightTop=49;rightDrop=48"
    Assert-Decision ALLOW $right 'verified empty right slot'
    Assert-Decision HOLD "SAVE_SLOT_1 confidence=0.90 ocr='SELECT SAVE SLOT' slot=1" 'wrong slot'
    Assert-Decision HOLD "SAVE_SLOT_2 confidence=0.90 ocr='SELECT SAVE SLOT'" 'missing slot diagnostic'
    Assert-Decision HOLD "SAVE_SLOT_2 confidence=0.50 ocr='SELECT SAVE SLOT' slot=2" 'low confidence'
    Assert-Decision FAIL "SAVE_SLOT_2 confidence=0.90 ocr='SELECT SAVE SLOT CONTINUE' slot=2" 'occupied slot text'
    Assert-Decision FAIL "SAVE_SLOT_2 confidence=0.90 ocr='OVERWRITE' slot=2" 'overwrite text'

    $unstableUi = Join-Path $tempRoot 'unstable-ui.json'
    @(
        [ordered]@{
            Kind = 'Manager'; StableSnapshot = $false; CaptureConsume = 1
        },
        [ordered]@{
            Kind = 'Scene'; Name = 'AO3Screens.F13_Save'; Open = 1
            InputEligible = 1; Captured = $true
        }
    ) | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $unstableUi `
        -Encoding UTF8
    $unstable = Invoke-Gate -Line $right -UiPath $unstableUi
    if ($unstable.Code -ne 10 -or $unstable.Output -notmatch '^HOLD\b') {
        throw "unstable UI: expected HOLD/10, got $($unstable.Output)/$($unstable.Code)"
    }

    $container = Join-Path $tempRoot (
        'content\{0}\{1}\00000001\default_checkpoint_2.sav' -f
        $profileXuid, $titleId)
    New-Item -ItemType Directory -Path $container -Force | Out-Null
    Assert-Decision FAIL $right 'save container exists'
    Remove-Item -LiteralPath $container -Recurse -Force

    $header = Join-Path $tempRoot (
        'content\{0}\{1}\Headers\00000001\default_checkpoint_2.sav.header' -f
        $profileXuid, $titleId)
    New-Item -ItemType Directory -Path (Split-Path -Parent $header) `
        -Force | Out-Null
    Set-Content -LiteralPath $header -Value 'occupied' -Encoding ASCII
    Assert-Decision FAIL $right 'save header exists'

    Write-Host 'PASS: CJ gate requires stable right-slot identity and absent slot-2 storage'
} finally {
    Remove-Item -LiteralPath $tempRoot -Recurse -Force `
        -ErrorAction SilentlyContinue
}
