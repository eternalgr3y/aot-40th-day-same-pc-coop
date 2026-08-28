[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('Empty', 'DaddyJoin', 'DaddySettled', 'DaddyGameplay')]
    [string]$Mode,

    [string]$BaseUri = 'http://127.0.0.1:36000',

    [ValidateRange(100, 5000)]
    [int]$MaxLatencyMs = 750,

    [ValidateRange(1, 10)]
    [int]$Samples = 3,

    [string]$FixtureSearchJsonPath = '',
    [string]$FixtureLookupJsonPath = '',

    [ValidateRange(0, 60000)]
    [int]$FixtureLatencyMs = 0,

    [string]$ExpectedDaddyHost = '',
    [string]$ExpectedDaddyMac = '',
    [string]$ExpectedDaddyXuid = ''
)

$ErrorActionPreference = 'Stop'
$title = '454108D8'
$lookupId = '000000000000007f'
$client = $null

function Write-GateResult {
    param([string]$Decision, [string]$Reason, [int]$Code)
    Write-Output ("{0} xws_session {1}" -f $Decision, $Reason)
    exit $Code
}

function Convert-JsonArray([string]$Text) {
    $decoded = $Text | ConvertFrom-Json
    $items = @()
    foreach ($item in $decoded) { $items += $item }
    return $items
}

function Get-JsonResponse {
    param([string]$RelativePath, [string]$FixturePath)

    if (-not [string]::IsNullOrWhiteSpace($FixturePath)) {
        if (-not (Test-Path -LiteralPath $FixturePath -PathType Leaf)) {
            throw "fixture missing: $FixturePath"
        }
        return [pscustomobject]@{
            Text = Get-Content -Raw -LiteralPath $FixturePath
            LatencyMs = $FixtureLatencyMs
        }
    }

    $uri = $BaseUri.TrimEnd('/') + $RelativePath
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $response = $client.GetAsync($uri).GetAwaiter().GetResult()
    $text = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
    $watch.Stop()
    if (-not $response.IsSuccessStatusCode) {
        throw "HTTP $([int]$response.StatusCode) from $RelativePath"
    }
    return [pscustomobject]@{ Text = $text; LatencyMs = $watch.ElapsedMilliseconds }
}

try {
    if ($Mode -ne 'Empty') {
        if ($ExpectedDaddyHost -notmatch '^127(?:\.\d{1,3}){3}$' -or
            $ExpectedDaddyMac -notmatch '^[0-9A-Fa-f]{12}$' -or
            $ExpectedDaddyXuid -notmatch '^[0-9A-Fa-f]{16}$') {
            Write-GateResult FAIL 'expected-daddy-identity-invalid-or-missing' 20
        }
    }
    $usingFixtures = -not [string]::IsNullOrWhiteSpace($FixtureSearchJsonPath)
    if (-not $usingFixtures) {
        Add-Type -AssemblyName System.Net.Http
        $client = [Net.Http.HttpClient]::new()
        $client.Timeout = [TimeSpan]::FromMilliseconds($MaxLatencyMs + 250)
        $client.DefaultRequestHeaders.UserAgent.ParseAdd('aot-samepc-gate/1.0')
    }

    $search = Get-JsonResponse -RelativePath "/title/$title/sessions/search" `
        -FixturePath $FixtureSearchJsonPath
    if ($search.LatencyMs -gt $MaxLatencyMs) {
        Write-GateResult FAIL "search-slow_ms=$($search.LatencyMs)" 20
    }
    $sessions = @(Convert-JsonArray $search.Text)

    if ($Mode -eq 'Empty') {
        if ($sessions.Count -ne 0) {
            Write-GateResult FAIL "expected-zero-sessions_count=$($sessions.Count)" 20
        }
        Write-GateResult ALLOW "mode=Empty count=0 search_ms=$($search.LatencyMs)" 0
    }

    if ($sessions.Count -ne 1) {
        Write-GateResult FAIL "expected-one-daddy-session_count=$($sessions.Count)" 20
    }
    $daddy = $sessions[0]
    $expectedFilledPublic = if ($Mode -in 'DaddySettled', 'DaddyGameplay') { 2 } else { 1 }
    $expectedOpenPublic = if ($Mode -in 'DaddySettled', 'DaddyGameplay') { 0 } else { 1 }
    # The retail title's post-Start XSessionModify changes host flags from
    # 0x42F to 0x52F, adding INVITES_DISABLED while retaining the same host,
    # session id, route, and full two-player roster.
    $expectedFlags = if ($Mode -eq 'DaddyGameplay') { 1327 } else { 1071 }
    if ($daddy.hostAddress -cne $ExpectedDaddyHost -or
        $daddy.macAddress -cne $ExpectedDaddyMac -or
        $daddy.xuid -cne $ExpectedDaddyXuid -or
        [string]$daddy.id -notmatch '^[0-9a-f]{16}$' -or
        [int]$daddy.port -le 0 -or
        [int]$daddy.flags -ne $expectedFlags -or
        [int]$daddy.publicSlotsCount -ne 2 -or
        [int]$daddy.filledPublicSlotsCount -ne $expectedFilledPublic -or
        [int]$daddy.openPublicSlotsCount -ne $expectedOpenPublic -or
        [int]$daddy.privateSlotsCount -ne 0 -or
        [int]$daddy.filledPrivateSlotsCount -ne 0 -or
        [int]$daddy.openPrivateSlotsCount -ne 0) {
        Write-GateResult FAIL 'sole-session-is-not-daddy' 20
    }

    $maxObserved = [int64]$search.LatencyMs
    foreach ($sample in 1..$Samples) {
        $lookup = Get-JsonResponse -RelativePath "/title/$title/sessions/$lookupId" `
            -FixturePath $FixtureLookupJsonPath
        if ($lookup.LatencyMs -gt $MaxLatencyMs) {
            Write-GateResult FAIL "lookup-slow_sample=$sample`_ms=$($lookup.LatencyMs)" 20
        }
        if ($lookup.LatencyMs -gt $maxObserved) { $maxObserved = $lookup.LatencyMs }
        $resolved = $lookup.Text | ConvertFrom-Json
        if ($resolved.id -cne $daddy.id -or
            $resolved.hostAddress -cne $daddy.hostAddress -or
            $resolved.macAddress -cne $daddy.macAddress -or
            [int]$resolved.port -ne [int]$daddy.port -or
            [int]$resolved.flags -ne [int]$daddy.flags -or
            [int]$resolved.publicSlotsCount -ne [int]$daddy.publicSlotsCount -or
            [int]$resolved.filledPublicSlotsCount -ne [int]$daddy.filledPublicSlotsCount -or
            [int]$resolved.openPublicSlotsCount -ne [int]$daddy.openPublicSlotsCount -or
            [int]$resolved.privateSlotsCount -ne [int]$daddy.privateSlotsCount -or
            [int]$resolved.filledPrivateSlotsCount -ne [int]$daddy.filledPrivateSlotsCount -or
            [int]$resolved.openPrivateSlotsCount -ne [int]$daddy.openPrivateSlotsCount) {
            Write-GateResult FAIL "lookup-mismatch_sample=$sample" 20
        }
    }

    Write-GateResult ALLOW ("mode={0} id={1} host={2} samples={3} max_ms={4}" -f
        $Mode, $daddy.id, $daddy.hostAddress, $Samples, $maxObserved) 0
} catch {
    Write-GateResult FAIL ("request-error={0}" -f
        ($_.Exception.Message -replace '\s+', '_')) 20
} finally {
    if ($null -ne $client) { $client.Dispose() }
}
