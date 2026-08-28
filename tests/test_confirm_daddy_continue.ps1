$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$gate = Join-Path $root 'tools\runtime\confirm_daddy_continue.ps1'
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('aot_continue_gate_' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tempRoot | Out-Null

function New-UiFixture {
    param(
        [string]$Name = 'AO3Screens.F13_Save',
        [bool]$Stable = $true,
        [int]$CaptureConsume = 1,
        [int]$Open = 1,
        [int]$InputEligible = 1,
        [bool]$Captured = $true,
        [int]$ManagerCopies = 1,
        [int]$SceneCopies = 1
    )
    $items = @()
    if ($ManagerCopies -gt 0) {
        1..$ManagerCopies | ForEach-Object {
            $items += [pscustomobject]@{
                Kind = 'Manager'; StableSnapshot = $Stable; CaptureConsume = $CaptureConsume
            }
        }
    }
    if ($SceneCopies -gt 0) {
        1..$SceneCopies | ForEach-Object {
            $items += [pscustomobject]@{
                Kind = 'Scene'; Name = $Name; Open = $Open
                InputEligible = $InputEligible; Captured = $Captured
            }
        }
    }
    $path = Join-Path $tempRoot (([guid]::NewGuid().ToString('N')) + '.json')
    $items | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $path -Encoding UTF8
    return $path
}

function Invoke-Gate {
    param([string]$Line, [string]$UiPath)
    $output = & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass `
        -File $gate -ClassificationLine $Line -UiJsonPath $UiPath 2>&1
    return [pscustomobject]@{ Code = $LASTEXITCODE; Output = ($output -join ' ') }
}

function Assert-Decision {
    param([string]$Expected, [string]$Line, [string]$UiPath, [string]$Label)
    $result = Invoke-Gate -Line $Line -UiPath $UiPath
    if ($result.Output -notmatch ('^' + [regex]::Escape($Expected) + '\b')) {
        throw "${Label}: expected $Expected, got code=$($result.Code) output=$($result.Output)"
    }
    if ($Expected -eq 'ALLOW' -and $result.Code -ne 0) {
        throw "${Label}: ALLOW returned $($result.Code)"
    }
    $expectedCode = @{ ALLOW = 0; HOLD = 10; FAIL = 20 }[$Expected]
    if ($result.Code -ne $expectedCode) {
        throw "${Label}: $Expected returned $($result.Code), expected $expectedCode"
    }
}

try {
    $goodUi = New-UiFixture
    $blindSpot = "SAVE_SLOT_1 confidence=0.90 ocr='SELECT SAVE SLOT CONTINUE' slotMode=classifier960;slot=1;middleTop=139"
    $properOptions = "SAVE_OPTIONS_CONTINUE confidence=0.90 ocr='SELECT SAVE SLOT CONTINUE' option=CONTINUE;slot=1"

    Assert-Decision ALLOW $blindSpot $goodUi 'blind-spot form'
    Assert-Decision ALLOW $properOptions $goodUi 'proper options form'
    Assert-Decision HOLD "SAVE_SLOT_1 confidence=0.90 ocr='SELECT SAVE SLOT EMPTY' slot=1" $goodUi 'missing Continue'
    Assert-Decision FAIL "SAVE_SLOT_1 confidence=0.90 ocr='WARNING OVERWRITE CONTINUE' slot=1" $goodUi 'overwrite text'
    Assert-Decision HOLD "SAVE_SLOT_0 confidence=0.90 ocr='SELECT SAVE SLOT CONTINUE' slot=0" $goodUi 'wrong slot'
    Assert-Decision HOLD "SAVE_OPTIONS_CONTINUE confidence=0.90 ocr='SELECT SAVE SLOT CONTINUE' slot=2" $goodUi 'wrong option slot'
    Assert-Decision HOLD $blindSpot (New-UiFixture -Stable $false) 'unstable manager'
    Assert-Decision HOLD $blindSpot (New-UiFixture -CaptureConsume 0) 'manager not consuming'
    Assert-Decision FAIL $blindSpot (New-UiFixture -ManagerCopies 2) 'duplicate manager'
    Assert-Decision FAIL $blindSpot (New-UiFixture -ManagerCopies 0) 'missing manager'
    Assert-Decision FAIL $blindSpot (New-UiFixture -Name 'AO3Screens.F12_Save') 'wrong scene'
    Assert-Decision FAIL $blindSpot (New-UiFixture -SceneCopies 2) 'duplicate scene'
    Assert-Decision FAIL $blindSpot (New-UiFixture -SceneCopies 0) 'missing scene'
    Assert-Decision HOLD $blindSpot (New-UiFixture -Open 0) 'scene closed'
    Assert-Decision HOLD $blindSpot (New-UiFixture -InputEligible 0) 'scene ineligible'
    Assert-Decision HOLD $blindSpot (New-UiFixture -Captured $false) 'scene not captured'

    $daddyImage = Join-Path $root '_runs\native_postjoin_probe_20260824T041929Z\screens\daddy_attempt2_pre_hostwait.png'
    $cjImage = Join-Path $root '_runs\native_postjoin_probe_20260824T041929Z\screens\cj_attempt2_middle_before_first_a.png'
    if ((Test-Path -LiteralPath $daddyImage) -and (Test-Path -LiteralPath $cjImage)) {
        $classifier = Join-Path $root 'classify_screen.ps1'
        $daddyLine = (& powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass `
            -File $classifier -ImagePath $daddyImage) -join ' '
        $cjLine = (& powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass `
            -File $classifier -ImagePath $cjImage) -join ' '
        Assert-Decision ALLOW $daddyLine $goodUi 'retained Daddy Continue frame'
        Assert-Decision HOLD $cjLine $goodUi 'retained CJ EMPTY frame'
    }

    Write-Host 'PASS: Daddy Continue requires fresh middle-slot OCR and stable captured F13_Save evidence'
} finally {
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}
