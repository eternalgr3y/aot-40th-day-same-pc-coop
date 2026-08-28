$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$gate = Join-Path $root 'tools\runtime\test_xws_session_gate.ps1'
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('aot_xws_gate_' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tempRoot | Out-Null

$daddy = [ordered]@{
    title = 'Army of TWO'; version = '0.0.0.2'; mediaId = '44388CF4'
    xuid = '0009000011111111'; id = 'ae00111122223333'; flags = 1071
    hostAddress = '127.10.20.30'; macAddress = '001122334455'
    publicSlotsCount = 2; privateSlotsCount = 0; openPublicSlotsCount = 1
    openPrivateSlotsCount = 0; filledPublicSlotsCount = 1
    filledPrivateSlotsCount = 0; port = 36792
}
$cj = [ordered]@{
    xuid = '0009000022222222'; id = 'ae00444455556666'; flags = 1071
    hostAddress = '127.40.50.60'; macAddress = '006655443322'; port = 36987
}

function Write-JsonFixture([object]$Value) {
    $path = Join-Path $tempRoot (([guid]::NewGuid().ToString('N')) + '.json')
    ConvertTo-Json -InputObject $Value -Depth 5 | Set-Content -LiteralPath $path -Encoding UTF8
    return $path
}

function Invoke-Gate {
    param([string]$Mode, [string]$Search, [string]$Lookup = '', [int]$Latency = 0)
    $args = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
        '-File', $gate, '-Mode', $Mode, '-FixtureSearchJsonPath', $Search,
        '-FixtureLatencyMs', $Latency,
        '-ExpectedDaddyHost', $daddy.hostAddress,
        '-ExpectedDaddyMac', $daddy.macAddress,
        '-ExpectedDaddyXuid', $daddy.xuid)
    if ($Lookup) { $args += @('-FixtureLookupJsonPath', $Lookup) }
    $output = & powershell.exe @args 2>&1
    return [pscustomobject]@{ Code = $LASTEXITCODE; Output = ($output -join ' ') }
}

function Assert-Decision {
    param([string]$Expected, $Result, [string]$Label)
    if ($Result.Output -notmatch ('^' + $Expected + '\b')) {
        throw "${Label}: expected $Expected, got code=$($Result.Code) output=$($Result.Output)"
    }
    $expectedCode = if ($Expected -eq 'ALLOW') { 0 } else { 20 }
    if ($Result.Code -ne $expectedCode) {
        throw "${Label}: expected exit $expectedCode, got $($Result.Code)"
    }
}

try {
    $empty = Write-JsonFixture @()
    $one = Write-JsonFixture @($daddy)
    $two = Write-JsonFixture @($daddy, $cj)
    $lookup = Write-JsonFixture $daddy
    $wrongLookup = [ordered]@{} + $daddy
    $wrongLookup.id = 'ae00999999999999'
    $wrongLookupPath = Write-JsonFixture $wrongLookup
    $wrongDaddy = [ordered]@{} + $daddy
    $wrongDaddy.hostAddress = '127.0.0.1'
    $wrongDaddyPath = Write-JsonFixture @($wrongDaddy)
    $fullDaddy = [ordered]@{} + $daddy
    $fullDaddy.openPublicSlotsCount = 0
    $fullDaddy.filledPublicSlotsCount = 2
    $fullDaddyPath = Write-JsonFixture @($fullDaddy)
    $fullLookupPath = Write-JsonFixture $fullDaddy
    $gameplayDaddy = [ordered]@{} + $fullDaddy
    $gameplayDaddy.flags = 1327
    $gameplayDaddyPath = Write-JsonFixture @($gameplayDaddy)
    $gameplayLookupPath = Write-JsonFixture $gameplayDaddy

    Assert-Decision ALLOW (Invoke-Gate Empty $empty) 'empty preflight'
    Assert-Decision FAIL (Invoke-Gate Empty $one) 'stale session rejected'
    Assert-Decision ALLOW (Invoke-Gate DaddyJoin $one $lookup) 'exact Daddy route'
    Assert-Decision FAIL (Invoke-Gate DaddyJoin $two $lookup) 'CJ self-host residue rejected'
    Assert-Decision FAIL (Invoke-Gate DaddyJoin $wrongDaddyPath $lookup) 'wrong sole host rejected'
    Assert-Decision FAIL (Invoke-Gate DaddyJoin $fullDaddyPath $fullLookupPath) 'full Daddy session rejected'
    Assert-Decision FAIL (Invoke-Gate DaddyJoin $one $wrongLookupPath) '0x7f mismatch rejected'
    Assert-Decision FAIL (Invoke-Gate DaddyJoin $one $lookup 1000) 'slow service rejected'
    Assert-Decision ALLOW (Invoke-Gate DaddySettled $fullDaddyPath $fullLookupPath) 'exact settled Daddy route'
    Assert-Decision FAIL (Invoke-Gate DaddySettled $one $lookup) 'pre-join slots rejected after settle'
    Assert-Decision FAIL (Invoke-Gate DaddySettled $two $fullLookupPath) 'CJ self-host residue rejected after settle'
    Assert-Decision FAIL (Invoke-Gate DaddySettled $wrongDaddyPath $fullLookupPath) 'wrong settled host rejected'
    Assert-Decision FAIL (Invoke-Gate DaddySettled $fullDaddyPath $wrongLookupPath) 'settled 0x7f mismatch rejected'
    Assert-Decision ALLOW (Invoke-Gate DaddyGameplay $gameplayDaddyPath $gameplayLookupPath) 'exact gameplay Daddy route'
    Assert-Decision FAIL (Invoke-Gate DaddyGameplay $fullDaddyPath $fullLookupPath) 'pre-Start flags rejected during gameplay'
    Assert-Decision FAIL (Invoke-Gate DaddySettled $gameplayDaddyPath $gameplayLookupPath) 'gameplay flags rejected before Start'

    Write-Host 'PASS: Xenia-WebServices gate requires one fast exact Daddy route at each requested lifecycle phase'
} finally {
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}
