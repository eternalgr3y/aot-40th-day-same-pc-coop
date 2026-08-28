[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$launcher = Join-Path $root 'Start-AOT-Coop.ps1'
$tokens = $null
$parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile(
    $launcher, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count -ne 0) {
    throw "launcher parse failed: $($parseErrors -join '; ')"
}
foreach ($name in 'Assert-CjJoinSlotStorageEmpty', 'Invoke-GateProbe',
                  'Invoke-InteractiveGateProcess', 'Get-ClassifierState',
                  'Wait-CjArmedJoin') {
    $functionAst = $ast.Find({
        param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -ceq $name
    }, $true)
    if ($null -eq $functionAst) { throw "missing launcher function $name" }
    Invoke-Expression $functionAst.Extent.Text
}

$tempRoot = Join-Path ([IO.Path]::GetTempPath()) (
    'aot_cj_armed_join_' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tempRoot | Out-Null
$script:titleId = '454108D8'
$profileXuid = 'E000B2B252222222'
$config = @{
    Cj = @{
        RigDir = $tempRoot
        ProfileXuid = $profileXuid
    }
}
$sessionGate = Join-Path $tempRoot 'session_gate.ps1'
$classifier = Join-Path $tempRoot 'classifier.ps1'
$uiInspector = Join-Path $tempRoot 'ui.ps1'
$interactiveGate = Join-Path $tempRoot 'interactive_gate.ps1'
$feslLog = Join-Path $tempRoot 'fesl.txt'
$cjLog = Join-Path $tempRoot 'xenia.log'
$sessionQueue = Join-Path $tempRoot 'session.queue'
$classifierQueue = Join-Path $tempRoot 'classifier.queue'
$uiQueue = Join-Path $tempRoot 'ui.queue'
$interactiveQueue = Join-Path $tempRoot 'interactive.queue'

$sessionSource = @'
param(
    [string]$Mode,
    [int]$Samples,
    [string]$ExpectedDaddyHost,
    [string]$ExpectedDaddyMac,
    [string]$ExpectedDaddyXuid)
$items = @(Get-Content -LiteralPath $env:AOT_TEST_SESSION_QUEUE)
$item = if ($items.Count -gt 0) { $items[0] } else { 'FAIL' }
if ($items.Count -gt 1) {
    $items[1..($items.Count - 1)] | Set-Content -LiteralPath $env:AOT_TEST_SESSION_QUEUE
} else {
    Set-Content -LiteralPath $env:AOT_TEST_SESSION_QUEUE -Value @()
}
switch ($item) {
    'ALLOW' { Write-Output 'ALLOW xws_session mode=DaddySettled id=ae00111122223333 host=127.1.2.3 samples=3 max_ms=1'; exit 0 }
    'TWO' { Write-Output 'FAIL xws_session expected-one-daddy-session_count=2'; exit 20 }
    default { Write-Output 'FAIL xws_session sole-session-is-not-daddy'; exit 20 }
}
'@
$classifierSource = @'
param([int]$ProcId)
$items = @(Get-Content -LiteralPath $env:AOT_TEST_CLASSIFIER_QUEUE)
$item = if ($items.Count -gt 0) { $items[0] } else { 'SAVE_SLOT_2' }
if ($items.Count -gt 1) {
    $items[1..($items.Count - 1)] | Set-Content -LiteralPath $env:AOT_TEST_CLASSIFIER_QUEUE
} else {
    Set-Content -LiteralPath $env:AOT_TEST_CLASSIFIER_QUEUE -Value @()
}
switch ($item) {
    'SAVE_SLOT_2' { Write-Output "SAVE_SLOT_2 confidence=0.90 ocr='SELECT SAVE SLOT' slotMode=test;slot=2" }
    default { Write-Output "$item confidence=0.90 ocr='fixture'" }
}
'@
$uiSource = @'
param([int]$TargetPid)
$items = @(Get-Content -LiteralPath $env:AOT_TEST_UI_QUEUE)
$item = if ($items.Count -gt 0) { $items[0] } else { 'READY' }
if ($items.Count -gt 1) {
    $items[1..($items.Count - 1)] | Set-Content -LiteralPath $env:AOT_TEST_UI_QUEUE
} else {
    Set-Content -LiteralPath $env:AOT_TEST_UI_QUEUE -Value @()
}
if ($item -eq 'ERROR') { throw 'fixture snapshot raced UI teardown' }
[pscustomobject]@{
    Kind = 'Manager'; StableSnapshot = $true; CaptureConsume = 1
}
if ($item -eq 'CLOSED') { return }
[pscustomobject]@{
    Kind = 'Scene'; Name = 'AO3Screens.F13_Save'; Open = 1
    InputEligible = 1; Captured = $true
}
'@
$interactiveSource = @'
param([string]$Fixture)
$items = @(Get-Content -LiteralPath $env:AOT_TEST_GATE_QUEUE)
$item = if ($items.Count -gt 0) { $items[0] } else { 'ALLOW' }
if ($items.Count -gt 1) {
    $items[1..($items.Count - 1)] | Set-Content -LiteralPath $env:AOT_TEST_GATE_QUEUE
} else {
    Set-Content -LiteralPath $env:AOT_TEST_GATE_QUEUE -Value @()
}
if ($item -eq 'HOLD') { Write-Output 'HOLD fixture not-ready'; exit 10 }
Write-Output 'ALLOW fixture ready'; exit 0
'@

$sessionArgs = @('-Mode', 'DaddySettled', '-Samples', '3',
    '-ExpectedDaddyHost', '127.1.2.3',
    '-ExpectedDaddyMac', '001122334455',
    '-ExpectedDaddyXuid', '0009000011111111')
$savedSessionQueue = [Environment]::GetEnvironmentVariable(
    'AOT_TEST_SESSION_QUEUE', 'Process')
$savedClassifierQueue = [Environment]::GetEnvironmentVariable(
    'AOT_TEST_CLASSIFIER_QUEUE', 'Process')
$savedUiQueue = [Environment]::GetEnvironmentVariable(
    'AOT_TEST_UI_QUEUE', 'Process')
$savedGateQueue = [Environment]::GetEnvironmentVariable(
    'AOT_TEST_GATE_QUEUE', 'Process')

try {
    Set-Content -LiteralPath $sessionGate -Value $sessionSource -Encoding UTF8
    Set-Content -LiteralPath $classifier -Value $classifierSource -Encoding UTF8
    Set-Content -LiteralPath $uiInspector -Value $uiSource -Encoding UTF8
    Set-Content -LiteralPath $interactiveGate -Value $interactiveSource -Encoding UTF8
    Set-Content -LiteralPath $feslLog -Value '' -Encoding ASCII
    Set-Content -LiteralPath $cjLog -Value '' -Encoding ASCII
    [Environment]::SetEnvironmentVariable(
        'AOT_TEST_SESSION_QUEUE', $sessionQueue, 'Process')
    [Environment]::SetEnvironmentVariable(
        'AOT_TEST_CLASSIFIER_QUEUE', $classifierQueue, 'Process')
    [Environment]::SetEnvironmentVariable(
        'AOT_TEST_UI_QUEUE', $uiQueue, 'Process')
    [Environment]::SetEnvironmentVariable(
        'AOT_TEST_GATE_QUEUE', $interactiveQueue, 'Process')

    Set-Content -LiteralPath $sessionQueue -Value @('FAIL', 'FAIL', 'FAIL', 'ALLOW')
    Set-Content -LiteralPath $classifierQueue `
        -Value @('SAVE_SLOT_2', 'LOADING', 'LOADING')
    Set-Content -LiteralPath $uiQueue -Value @('READY', 'CLOSED', 'CLOSED')
    $joined = Wait-CjArmedJoin -TargetPid $PID `
        -SessionGate $sessionGate -SettledArguments $sessionArgs `
        -Classifier $classifier -UiInspector $uiInspector -Config $config `
        -Slot 2 -FeslLog $feslLog -CjLog $cjLog -TimeoutSeconds 15
    if ($joined -ne $true) { throw 'normal armed transition did not join' }

    Set-Content -LiteralPath $sessionQueue `
        -Value @('FAIL', 'FAIL', 'FAIL', 'FAIL', 'FAIL', 'FAIL', 'FAIL', 'ALLOW')
    Set-Content -LiteralPath $classifierQueue -Value @(
        'SAVE_SLOT_2', 'LOADING', 'LOADING', 'OTHER', 'OTHER',
        'SAVE_SLOT_2', 'SAVE_SLOT_2')
    Set-Content -LiteralPath $uiQueue -Value @(
        'READY', 'CLOSED', 'CLOSED', 'READY', 'READY', 'READY', 'READY')
    $rearmOutput = @(& {
        Wait-CjArmedJoin -TargetPid $PID -SessionGate $sessionGate `
            -SettledArguments $sessionArgs -Classifier $classifier `
            -UiInspector $uiInspector -Config $config -Slot 2 `
            -FeslLog $feslLog -CjLog $cjLog -TimeoutSeconds 15
    } 6>&1)
    $rearmText = ($rearmOutput | ForEach-Object { "$_" }) -join ' '
    if ($rearmOutput -notcontains $true -or $rearmText -notmatch
        'returned to verified empty slot 2') {
        throw "verified slot-2 return did not re-arm exactly monitored input: $rearmText"
    }

    Set-Content -LiteralPath $sessionQueue -Value @('TWO')
    Set-Content -LiteralPath $classifierQueue -Value @('SAVE_SLOT_2')
    Set-Content -LiteralPath $uiQueue -Value @('READY')
    try {
        Wait-CjArmedJoin -TargetPid $PID -SessionGate $sessionGate `
            -SettledArguments $sessionArgs -Classifier $classifier `
            -UiInspector $uiInspector -Config $config -Slot 2 `
            -FeslLog $feslLog -CjLog $cjLog -TimeoutSeconds 15 | Out-Null
        throw 'second XWS session was accepted'
    } catch {
        if ($_.Exception.Message -notmatch 'second XWS session') { throw }
    }

    Set-Content -LiteralPath $sessionQueue -Value @('FAIL')
    Set-Content -LiteralPath $classifierQueue `
        -Value @('SAVE_OPTIONS_CONTINUE')
    Set-Content -LiteralPath $uiQueue -Value @('READY')
    try {
        Wait-CjArmedJoin -TargetPid $PID -SessionGate $sessionGate `
            -SettledArguments $sessionArgs -Classifier $classifier `
            -UiInspector $uiInspector -Config $config -Slot 2 `
            -FeslLog $feslLog -CjLog $cjLog -TimeoutSeconds 15 | Out-Null
        throw 'occupied Continue transition was accepted'
    } catch {
        if ($_.Exception.Message -notmatch 'unsafe state') { throw }
    }

    $container = Join-Path $tempRoot (
        'content\{0}\{1}\00000001\default_checkpoint_2.sav' -f
        $profileXuid, $script:titleId)
    New-Item -ItemType Directory -Path $container -Force | Out-Null
    Set-Content -LiteralPath $sessionQueue -Value @('FAIL')
    Set-Content -LiteralPath $classifierQueue -Value @('SAVE_SLOT_2')
    Set-Content -LiteralPath $uiQueue -Value @('READY')
    try {
        Wait-CjArmedJoin -TargetPid $PID -SessionGate $sessionGate `
            -SettledArguments $sessionArgs -Classifier $classifier `
            -UiInspector $uiInspector -Config $config -Slot 2 `
            -FeslLog $feslLog -CjLog $cjLog -TimeoutSeconds 15 | Out-Null
        throw 'occupied slot storage was accepted while armed'
    } catch {
        if ($_.Exception.Message -notmatch 'slot 2 is occupied') { throw }
    }
    Remove-Item -LiteralPath $container -Recurse -Force

    # A guest-memory read can race normal save-scene teardown. It must become
    # non-ready evidence while exact-session monitoring continues.
    Set-Content -LiteralPath $sessionQueue -Value @('FAIL', 'ALLOW')
    Set-Content -LiteralPath $classifierQueue -Value @('LOADING')
    Set-Content -LiteralPath $uiQueue -Value @('ERROR')
    $joinedAfterUiRace = Wait-CjArmedJoin -TargetPid $PID `
        -SessionGate $sessionGate -SettledArguments $sessionArgs `
        -Classifier $classifier -UiInspector $uiInspector -Config $config `
        -Slot 2 -FeslLog $feslLog -CjLog $cjLog -TimeoutSeconds 15
    if ($joinedAfterUiRace -ne $true) {
        throw 'UI snapshot race interrupted exact-session monitoring'
    }

    $script:readHostCalls = 0
    function Read-Host {
        param([string]$Prompt)
        $script:readHostCalls++
        return ''
    }
    Set-Content -LiteralPath $interactiveQueue -Value @('HOLD', 'ALLOW')
    $interactive = Invoke-InteractiveGateProcess `
        -Script $interactiveGate -Arguments @('-Fixture', '1') -Label 'fixture' `
        -RetryPrompt 'retry'
    if ($interactive -notmatch '^ALLOW\b' -or $script:readHostCalls -ne 1) {
        throw 'interactive HOLD did not retry exactly once'
    }

    Write-Host 'PASS: CJ armed join monitor retries HOLD, re-arms only on verified slot 2, rejects self-host/occupied routes, and accepts exact-session transition'
} finally {
    [Environment]::SetEnvironmentVariable(
        'AOT_TEST_SESSION_QUEUE', $savedSessionQueue, 'Process')
    [Environment]::SetEnvironmentVariable(
        'AOT_TEST_CLASSIFIER_QUEUE', $savedClassifierQueue, 'Process')
    [Environment]::SetEnvironmentVariable(
        'AOT_TEST_UI_QUEUE', $savedUiQueue, 'Process')
    [Environment]::SetEnvironmentVariable(
        'AOT_TEST_GATE_QUEUE', $savedGateQueue, 'Process')
    Remove-Item -LiteralPath $tempRoot -Recurse -Force `
        -ErrorAction SilentlyContinue
}
