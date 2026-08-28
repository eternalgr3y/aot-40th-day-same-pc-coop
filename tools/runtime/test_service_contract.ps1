[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('PreReset', 'PreDaddyLaunch', 'PreCompletion')]
    [string]$Stage,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$ExpectedFeslLogPath,

    [string]$BaseUri = 'http://127.0.0.1:36000',

    [ValidateRange(100, 5000)]
    [int]$MaxLatencyMs = 250,

    [ValidateRange(1, 10)]
    [int]$HealthSamples = 3,

    [string]$FixturePath = '',

    [string]$ExpectedNodePath = [IO.Path]::Combine(
        [Environment]::GetFolderPath([Environment+SpecialFolder]::ProgramFiles),
        'nodejs', 'node.exe'),
    [string]$ExpectedFeslScriptPath = '',
    [string]$ExpectedXwsAffinity = '08200000',
    [string]$ExpectedFeslAffinity = '00200000'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
if ([string]::IsNullOrWhiteSpace($ExpectedFeslScriptPath)) {
    $ExpectedFeslScriptPath = Join-Path $root 'tools\runtime\fesl_server.py'
}
$xwsPort = 36000
$feslPorts = @(18131, 18275, 13505)
$fixture = $null
$client = $null

function ConvertTo-ResultToken {
    param([AllowEmptyString()][string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return 'unknown' }
    return ($Text.Trim() -replace '[^A-Za-z0-9_.:=/\\-]+', '_')
}

function Write-GateResult {
    param([string]$Decision, [string]$Reason, [int]$Code)
    $renderedReason = if ($Decision -ceq 'ALLOW') {
        $Reason.Trim()
    } else {
        ConvertTo-ResultToken $Reason
    }
    Write-Output ('{0} aot_services stage={1} {2}' -f
        $Decision, $Stage, $renderedReason)
    exit $Code
}

function Normalize-Affinity {
    param([Parameter(Mandatory = $true)][object]$Value)
    $text = ([string]$Value).Trim() -replace '^(?i:0x)', ''
    if ($text -notmatch '^[0-9A-Fa-f]{1,16}$') {
        throw "invalid-affinity=$Value"
    }
    [uint64]$number = [Convert]::ToUInt64($text, 16)
    $width = if ($number -le [uint32]::MaxValue) { 8 } else { 16 }
    return $number.ToString("X$width")
}

$expectedXwsAffinity = Normalize-Affinity $ExpectedXwsAffinity
$expectedFeslAffinity = Normalize-Affinity $ExpectedFeslAffinity

function Normalize-LocalPath {
    param([Parameter(Mandatory = $true)][string]$Value)
    $text = $Value.Trim().Trim('"').Trim("'")
    if ($text -match '^/([A-Za-z])/(.*)$') {
        $text = ('{0}:\{1}' -f $Matches[1], $Matches[2])
    }
    $text = $text.Replace('/', '\')
    try {
        return [IO.Path]::GetFullPath($text).TrimEnd('\')
    } catch {
        throw "invalid-path=$Value"
    }
}

function Get-CommandOptionValue {
    param(
        [Parameter(Mandatory = $true)][string]$CommandLine,
        [Parameter(Mandatory = $true)][string]$Name)
    $pattern = '(?i)(?:^|\s)--' + [regex]::Escape($Name) +
        '(?:=|\s+)(?:"(?<dq>[^"]+)"|''(?<sq>[^'']+)''|(?<raw>\S+))'
    $match = [regex]::Match($CommandLine, $pattern)
    if (-not $match.Success) { return '' }
    foreach ($groupName in 'dq', 'sq', 'raw') {
        if ($match.Groups[$groupName].Success) {
            return $match.Groups[$groupName].Value
        }
    }
    return ''
}

function Get-UniqueListenerOwner {
    param(
        [Parameter(Mandatory = $true)][object[]]$Listeners,
        [Parameter(Mandatory = $true)][int]$Port,
        [Parameter(Mandatory = $true)][string]$Role)
    $owners = @($Listeners |
        Where-Object { [int]$_.LocalPort -eq $Port } |
        ForEach-Object { [int]$_.OwningProcess } |
        Where-Object { $_ -gt 0 } |
        Sort-Object -Unique)
    if ($owners.Count -ne 1) {
        throw "$Role-listener-owner-count=$($owners.Count)-port=$Port"
    }
    return [int]$owners[0]
}

function Get-ProcessRecord {
    param([Parameter(Mandatory = $true)][int]$ProcessId)

    if ($null -ne $fixture) {
        $matches = @($fixture.Processes | Where-Object { [int]$_.Id -eq $ProcessId })
        if ($matches.Count -ne 1) {
            throw "process-record-count=$($matches.Count)-pid=$ProcessId"
        }
        return $matches[0]
    }

    $cim = Get-CimInstance Win32_Process -Filter "ProcessId = $ProcessId"
    $process = Get-Process -Id $ProcessId -ErrorAction Stop
    if ($null -eq $cim -or [string]::IsNullOrWhiteSpace($cim.CommandLine) -or
        [string]::IsNullOrWhiteSpace($cim.ExecutablePath)) {
        throw "process-identity-unavailable-pid=$ProcessId"
    }
    $process.Refresh()
    [uint64]$affinityBits = [BitConverter]::ToUInt64(
        [BitConverter]::GetBytes($process.ProcessorAffinity.ToInt64()), 0)
    return [pscustomobject]@{
        Id = $ProcessId
        Name = $process.ProcessName
        Path = $cim.ExecutablePath
        CommandLine = $cim.CommandLine
        PriorityClass = [string]$process.PriorityClass
        Affinity = '0x' + (Normalize-Affinity (
            $affinityBits.ToString('X16')))
    }
}

function Assert-XwsProcess {
    param([Parameter(Mandatory = $true)][object]$Record)
    $exeName = [IO.Path]::GetFileName([string]$Record.Path)
    if ($exeName -cnotmatch '(?i)^node\.exe$' -or
        -not [string]::Equals((Normalize-LocalPath ([string]$Record.Path)),
            (Normalize-LocalPath $ExpectedNodePath),
            [StringComparison]::OrdinalIgnoreCase) -or
        [string]$Record.CommandLine -notmatch
            '(?i)(?:^|[\s"''])dist[\\/]main(?:\.js)?(?=[\s"'']|$)') {
        throw "xws-process-identity-mismatch-pid=$($Record.Id)"
    }
    if ([string]$Record.PriorityClass -cne 'Normal') {
        throw "xws-priority=$($Record.PriorityClass)-expected=Normal"
    }
    $actualAffinity = Normalize-Affinity $Record.Affinity
    if ($actualAffinity -cne $expectedXwsAffinity) {
        throw "xws-affinity=0x$actualAffinity-expected=0x$expectedXwsAffinity"
    }
}

function Assert-FeslProcess {
    param([Parameter(Mandatory = $true)][object]$Record)
    $exeName = [IO.Path]::GetFileName([string]$Record.Path)
    $commandLine = [string]$Record.CommandLine
    $feslScriptPattern = '(?i)(?:^|[\s"''])' +
        [regex]::Escape((Normalize-LocalPath $ExpectedFeslScriptPath)) +
        '(?=[\s"'']|$)'
    if ($exeName -cnotmatch '(?i)^python(?:w|3(?:\.\d+)?)?\.exe$' -or
        $commandLine -notmatch $feslScriptPattern -or
        $commandLine -notmatch '(?i)(?:^|\s)--memcheck(?:=|\s+)c0(?=\s|$)') {
        throw "fesl-process-identity-mismatch-pid=$($Record.Id)"
    }
    $actualLog = Get-CommandOptionValue -CommandLine $commandLine -Name log
    if ([string]::IsNullOrWhiteSpace($actualLog) -or
        -not [string]::Equals((Normalize-LocalPath $actualLog),
            (Normalize-LocalPath $ExpectedFeslLogPath),
            [StringComparison]::OrdinalIgnoreCase)) {
        throw "fesl-log-mismatch-pid=$($Record.Id)"
    }
    if ([string]$Record.PriorityClass -cne 'High') {
        throw "fesl-priority=$($Record.PriorityClass)-expected=High"
    }
    $actualAffinity = Normalize-Affinity $Record.Affinity
    if ($actualAffinity -cne $expectedFeslAffinity) {
        throw "fesl-affinity=0x$actualAffinity-expected=0x$expectedFeslAffinity"
    }
}

function Get-HealthSample {
    param([Parameter(Mandatory = $true)][int]$Index)
    if ($null -ne $fixture) {
        $samples = @($fixture.HealthSamples)
        if ($Index -ge $samples.Count) {
            throw "fixture-health-sample-missing-index=$Index"
        }
        return $samples[$Index]
    }

    $uri = $BaseUri.TrimEnd('/') + '/title/454108D8/sessions/search'
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $response = $client.GetAsync($uri).GetAwaiter().GetResult()
    try {
        $body = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
        return [pscustomobject]@{
            StatusCode = [int]$response.StatusCode
            LatencyMs = [int64]$watch.ElapsedMilliseconds
            Body = $body
        }
    } finally {
        $watch.Stop()
        $response.Dispose()
    }
}

try {
    if (-not [string]::IsNullOrWhiteSpace($FixturePath)) {
        if (-not (Test-Path -LiteralPath $FixturePath -PathType Leaf)) {
            throw "fixture-missing=$FixturePath"
        }
        $fixture = Get-Content -Raw -LiteralPath $FixturePath | ConvertFrom-Json
        $listeners = @($fixture.Listeners)
    } else {
        $expectedLogWindowsPath = Normalize-LocalPath $ExpectedFeslLogPath
        if (-not (Test-Path -LiteralPath $expectedLogWindowsPath -PathType Leaf)) {
            throw "fesl-log-missing=$expectedLogWindowsPath"
        }
        $listeners = @(Get-NetTCPConnection -State Listen -ErrorAction Stop |
            Where-Object { [int]$_.LocalPort -in @($xwsPort) + $feslPorts })
        Add-Type -AssemblyName System.Net.Http
        $client = [Net.Http.HttpClient]::new()
        $client.Timeout = [TimeSpan]::FromMilliseconds($MaxLatencyMs + 250)
        $client.DefaultRequestHeaders.UserAgent.ParseAdd('aot-service-gate/1.0')
    }

    $xwsPid = Get-UniqueListenerOwner -Listeners $listeners -Port $xwsPort -Role xws
    $feslOwners = @($feslPorts | ForEach-Object {
        Get-UniqueListenerOwner -Listeners $listeners -Port $_ -Role fesl
    } | Sort-Object -Unique)
    if ($feslOwners.Count -ne 1) {
        throw "fesl-shared-owner-count=$($feslOwners.Count)"
    }
    $feslPid = [int]$feslOwners[0]
    if ($xwsPid -eq $feslPid) {
        throw "service-pids-not-distinct-pid=$xwsPid"
    }

    $xws = Get-ProcessRecord -ProcessId $xwsPid
    $fesl = Get-ProcessRecord -ProcessId $feslPid
    Assert-XwsProcess -Record $xws
    Assert-FeslProcess -Record $fesl

    $maxObserved = 0L
    for ($sampleIndex = 0; $sampleIndex -lt $HealthSamples; $sampleIndex++) {
        $sample = Get-HealthSample -Index $sampleIndex
        $statusCode = [int]$sample.StatusCode
        $latency = [int64]$sample.LatencyMs
        $body = [string]$sample.Body
        if ($statusCode -lt 200 -or $statusCode -ge 300) {
            throw "xws-health-http=$statusCode-sample=$($sampleIndex + 1)"
        }
        if ($latency -gt $MaxLatencyMs) {
            throw "xws-health-slow-ms=$latency-sample=$($sampleIndex + 1)"
        }
        $trimmedBody = $body.Trim()
        if (-not $trimmedBody.StartsWith('[') -or -not $trimmedBody.EndsWith(']')) {
            throw "xws-health-not-json-array-sample=$($sampleIndex + 1)"
        }
        try { $null = $trimmedBody | ConvertFrom-Json } catch {
            throw "xws-health-invalid-json-sample=$($sampleIndex + 1)"
        }
        if ($latency -gt $maxObserved) { $maxObserved = $latency }
    }

    Write-GateResult ALLOW (('xws_pid={0} xws_affinity=0x{1} xws_priority=Normal ' +
        'fesl_pid={2} fesl_affinity=0x{3} fesl_priority=High samples={4} ' +
        'max_ms={5} mongo=unmanaged') -f
        $xwsPid, $expectedXwsAffinity, $feslPid, $expectedFeslAffinity,
        $HealthSamples, $maxObserved) 0
} catch {
    Write-GateResult FAIL "reason=$($_.Exception.Message)" 20
} finally {
    if ($null -ne $client) { $client.Dispose() }
}
