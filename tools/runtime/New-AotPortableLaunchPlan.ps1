[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('Daddy', 'Cj')]
    [string]$Side,

    [string]$ConfigPath = '',
    [string]$ProfileRoot = '',
    [switch]$SkipFileChecks,
    [switch]$VerifyGameHash,
    [switch]$RequireFrozenFingerprint,
    [switch]$RuntimeAcceptanceCandidate,
    [switch]$AsJson
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module Microsoft.PowerShell.Utility -ErrorAction Stop

$workspaceRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    $ConfigPath = Join-Path $workspaceRoot 'aot-coop.local.psd1'
}
if ([string]::IsNullOrWhiteSpace($ProfileRoot)) {
    $ProfileRoot = Join-Path $workspaceRoot 'profiles\b19'
}

function Get-TextSha256 {
    param([Parameter(Mandatory = $true)][string]$Text)
    $algorithm = [Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString(
            $algorithm.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text)))) -replace '-', ''
    } finally {
        $algorithm.Dispose()
    }
}

function Get-FileSha256 {
    param([Parameter(Mandatory = $true)][string]$Path)
    return (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash
}

function Get-EnabledPatchNames {
    param([Parameter(Mandatory = $true)][string]$PatchDirectory)
    if (-not (Test-Path -LiteralPath $PatchDirectory -PathType Container)) {
        throw "Patch directory is missing: $PatchDirectory"
    }
    $names = [Collections.Generic.List[string]]::new()
    foreach ($patchFile in @(Get-ChildItem -LiteralPath $PatchDirectory `
            -Filter '*.patch.toml' -File)) {
        $text = Get-Content -Raw -LiteralPath $patchFile.FullName
        if ($text -notmatch '(?m)^\s*title_id\s*=\s*"454108D8"\s*$') {
            continue
        }
        $blocks = @([regex]::Split($text,
            '(?m)^\s*\[\[patch\]\]\s*\r?\n') | Select-Object -Skip 1)
        foreach ($body in $blocks) {
            if ($body -notmatch '(?m)^\s*is_enabled\s*=\s*true\s*$') {
                continue
            }
            $nameMatch = [regex]::Match($body,
                '(?m)^\s*name\s*=\s*"(?<name>[^"]+)"\s*$')
            if (-not $nameMatch.Success) {
                throw "Enabled patch lacks a plain name: $($patchFile.FullName)"
            }
            $names.Add($nameMatch.Groups['name'].Value)
        }
    }
    return @($names)
}

function Assert-PlainValue {
    param([Parameter(Mandatory = $true)][string]$Value,
          [Parameter(Mandatory = $true)][string]$Label)
    if ([string]::IsNullOrWhiteSpace($Value) -or
        $Value -match '<[^>]+>|[\r\n"]') {
        throw "$Label is empty, unconfigured, or contains an unsupported quote/newline."
    }
}

function Assert-ExactKeys {
    param(
        [Parameter(Mandatory = $true)][Collections.IDictionary]$Table,
        [Parameter(Mandatory = $true)][string[]]$Expected,
        [Parameter(Mandatory = $true)][string]$Label
    )
    $actual = @($Table.Keys | ForEach-Object { [string]$_ })
    $unknown = @($actual | Where-Object { $_ -notin $Expected })
    $missing = @($Expected | Where-Object { $_ -notin $actual })
    if ($unknown.Count -ne 0 -or $missing.Count -ne 0) {
        throw (("{0} keys differ from SchemaVersion 2: missing=[{1}] " +
            "unknown=[{2}]") -f $Label, ($missing -join ','),
            ($unknown -join ','))
    }
}

function Resolve-ConfigPath {
    param([Parameter(Mandatory = $true)][string]$Value,
          [Parameter(Mandatory = $true)][string]$BasePath,
          [Parameter(Mandatory = $true)][string]$Label)
    Assert-PlainValue -Value $Value -Label $Label
    if ([IO.Path]::IsPathRooted($Value)) {
        $fullPath = [IO.Path]::GetFullPath($Value)
    } else {
        $fullPath = [IO.Path]::GetFullPath((Join-Path $BasePath $Value))
    }
    if ($fullPath.TrimEnd('\') -ceq
        ([IO.Path]::GetPathRoot($fullPath)).TrimEnd('\')) {
        throw "$Label may not be a volume root."
    }
    return $fullPath.TrimEnd('\')
}

function Normalize-CpuMask {
    param([Parameter(Mandatory = $true)][string]$Value,
          [Parameter(Mandatory = $true)][string]$Label)
    $text = $Value.Trim() -replace '^(?i:0x)', ''
    if ($text -notmatch '^[0-9A-Fa-f]{1,16}$') {
        throw "$Label must be a nonzero hexadecimal processor mask up to 64 bits."
    }
    $number = [Convert]::ToUInt64($text, 16)
    if ($number -eq 0) { throw "$Label must be nonzero." }
    $width = if ($number -le [uint32]::MaxValue) { 8 } else { 16 }
    return [pscustomobject]@{
        Text = $number.ToString("X$width")
        Value = $number
    }
}

function Normalize-OptionalCpuMask {
    param([Parameter(Mandatory = $true)][string]$Value,
          [Parameter(Mandatory = $true)][string]$Label)
    $text = $Value.Trim() -replace '^(?i:0x)', ''
    if ($text -notmatch '^[0-9A-Fa-f]{1,16}$') {
        throw "$Label must be a hexadecimal processor mask up to 64 bits."
    }
    $number = [Convert]::ToUInt64($text, 16)
    $width = if ($number -le [uint32]::MaxValue) { 8 } else { 16 }
    return [pscustomobject]@{
        Text = $number.ToString("X$width")
        Value = $number
    }
}

function ConvertTo-WindowsArgument {
    param([Parameter(Mandatory = $true)][string]$Value)
    if ($Value -notmatch '[\s"]') { return $Value }
    if ($Value.Contains('"')) {
        throw 'Portable launch arguments may not contain a literal double quote.'
    }
    return '"' + $Value + '"'
}

function Get-NormalizedConfig {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Config is missing: $Path"
    }
    $config = Import-PowerShellDataFile -LiteralPath $Path
    if ($config.SchemaVersion -notin @(1, 2)) {
        throw "Unsupported config SchemaVersion: $($config.SchemaVersion)"
    }

    if ([int]$config.SchemaVersion -eq 1) {
        $installRoot = Resolve-ConfigPath -Value ([string]$config.WorkspaceRoot) `
            -BasePath $workspaceRoot -Label 'WorkspaceRoot'
        $gamePath = Resolve-ConfigPath -Value ([string]$config.GamePath) `
            -BasePath $installRoot -Label 'GamePath'
        $apiAddress = 'http://127.0.0.1:36000/'
        $xeniaFileName = 'xenia_canary_netplay.exe'
        $saveSlot = [int]$config.SaveSlot
        $daddy = $config.Daddy
        $cj = $config.Cj
        $daddyInvert = $true
        $cjInvert = $false
        $xwsRoot = Resolve-ConfigPath -Value ([string]$config.XwsRoot) `
            -BasePath $installRoot -Label 'XwsRoot'
        $nodeExe = Resolve-ConfigPath -Value ([string]$config.NodeExe) `
            -BasePath $installRoot -Label 'NodeExe'
        $pythonExe = Resolve-ConfigPath -Value ([string]$config.PythonExe) `
            -BasePath $installRoot -Label 'PythonExe'
        $xwsMask = Normalize-CpuMask -Value ([string]$config.XwsCpuMask) `
            -Label 'XwsCpuMask'
        $feslMask = Normalize-CpuMask -Value ([string]$config.FeslCpuMask) `
            -Label 'FeslCpuMask'
        $feslSeconds = [int]$config.FeslSeconds
        $cpuAllocationPolicy = 'FrozenB19'
        $cpuTopologySignature = ''
        $reservedMask = Normalize-OptionalCpuMask -Value '0' `
            -Label 'ReservedCpuMask'
    } else {
        Assert-ExactKeys -Table $config -Label 'Portable config' -Expected @(
            'SchemaVersion', 'InstallRoot', 'GamePath', 'ApiAddress',
            'XeniaFileName', 'SaveSlot', 'XwsRoot', 'NodeExe',
            'PythonExe', 'XwsCpuMask', 'FeslCpuMask', 'FeslSeconds',
            'CpuAllocationPolicy', 'CpuTopologySignature', 'ReservedCpuMask',
            'Daddy', 'Cj')
        $installRoot = Resolve-ConfigPath -Value ([string]$config.InstallRoot) `
            -BasePath (Split-Path -Parent ([IO.Path]::GetFullPath($Path))) `
            -Label 'InstallRoot'
        $gamePath = Resolve-ConfigPath -Value ([string]$config.GamePath) `
            -BasePath $installRoot -Label 'GamePath'
        $apiAddress = [string]$config.ApiAddress
        $xeniaFileName = [string]$config.XeniaFileName
        $saveSlot = [int]$config.SaveSlot
        $daddy = $config.Daddy
        $cj = $config.Cj
        $daddyInvert = $null
        $cjInvert = $null
        $xwsRoot = Resolve-ConfigPath -Value ([string]$config.XwsRoot) `
            -BasePath $installRoot -Label 'XwsRoot'
        $nodeExe = Resolve-ConfigPath -Value ([string]$config.NodeExe) `
            -BasePath $installRoot -Label 'NodeExe'
        $pythonExe = Resolve-ConfigPath -Value ([string]$config.PythonExe) `
            -BasePath $installRoot -Label 'PythonExe'
        $xwsMask = Normalize-CpuMask -Value ([string]$config.XwsCpuMask) `
            -Label 'XwsCpuMask'
        $feslMask = Normalize-CpuMask -Value ([string]$config.FeslCpuMask) `
            -Label 'FeslCpuMask'
        $feslSeconds = [int]$config.FeslSeconds
        $cpuAllocationPolicy = [string]$config.CpuAllocationPolicy
        $cpuTopologySignature = ([string]$config.CpuTopologySignature).ToUpperInvariant()
        $reservedMask = Normalize-OptionalCpuMask `
            -Value ([string]$config.ReservedCpuMask) -Label 'ReservedCpuMask'
        if ($cpuAllocationPolicy -cne 'WholeCoreTierSplitV1') {
            throw 'CpuAllocationPolicy must be WholeCoreTierSplitV1.'
        }
        if ($cpuTopologySignature -notmatch '^[0-9A-F]{64}$') {
            throw 'CpuTopologySignature must be the 64-hex setup signature.'
        }
    }

    Assert-PlainValue -Value $xeniaFileName -Label 'XeniaFileName'
    if ([IO.Path]::GetFileName($xeniaFileName) -cne $xeniaFileName -or
        $xeniaFileName -notmatch '(?i)^xenia[A-Za-z0-9._-]{0,95}\.exe$') {
        throw 'XeniaFileName must be a plain xenia*.exe file name.'
    }
    $apiUri = $null
    if ($apiAddress -cne 'http://127.0.0.1:36000/' -or
        $apiAddress -notmatch '^http://127\.0\.0\.1:[1-9]\d{0,4}/$' -or
        -not [Uri]::TryCreate($apiAddress, [UriKind]::Absolute,
            [ref]$apiUri) -or
        $apiUri.Scheme -cne 'http' -or
        $apiUri.Host -cne '127.0.0.1' -or
        $apiUri.AbsolutePath -cne '/' -or
        -not [string]::IsNullOrEmpty($apiUri.Query) -or
        -not [string]::IsNullOrEmpty($apiUri.Fragment) -or
        -not [string]::IsNullOrEmpty($apiUri.UserInfo) -or
        $apiUri.Port -lt 1 -or $apiUri.Port -gt 65535) {
        throw 'The B19 profile requires ApiAddress=http://127.0.0.1:36000/.'
    }
    if ($saveSlot -ne 1) {
        throw 'The current B19 profile supports only Daddy host SaveSlot=1; CJ joins from verified-empty slot 2.'
    }
    if ($feslSeconds -lt 600 -or $feslSeconds -gt 86400) {
        throw 'FeslSeconds must be from 600 through 86400.'
    }

    $normalizedSides = [ordered]@{}
    foreach ($entry in @(
        @{ Name = 'Daddy'; Value = $daddy; Invert = $daddyInvert },
        @{ Name = 'Cj'; Value = $cj; Invert = $cjInvert })) {
        $requiredSideKeys = @('RigDir', 'ProfileXuid', 'Controller', 'CpuMask')
        if ([int]$config.SchemaVersion -eq 2) {
            $requiredSideKeys += @(
                'OnlineXuid', 'MacAddress', 'HostAddress', 'InvertRightX')
        }
        if ($null -eq $entry.Value -or
            -not ($entry.Value -is [Collections.IDictionary])) {
            throw "$($entry.Name) config must be a data-file hashtable."
        }
        if ([int]$config.SchemaVersion -eq 2) {
            Assert-ExactKeys -Table $entry.Value -Expected $requiredSideKeys `
                -Label "$($entry.Name) config"
        }
        foreach ($key in $requiredSideKeys) {
            if (-not $entry.Value.ContainsKey($key)) {
                throw "$($entry.Name) config is missing $key"
            }
        }
        if ([int]$config.SchemaVersion -eq 2) {
            if (-not ($entry.Value.InvertRightX -is [bool])) {
                throw "$($entry.Name).InvertRightX must be a Boolean `$true or `$false."
            }
            $invertRightX = [bool]$entry.Value.InvertRightX
        } else {
            $invertRightX = [bool]$entry.Invert
        }
        $rigDir = Resolve-ConfigPath -Value ([string]$entry.Value.RigDir) `
            -BasePath $installRoot -Label "$($entry.Name).RigDir"
        $xuid = ([string]$entry.Value.ProfileXuid).ToUpperInvariant()
        $xuidPattern = if ([int]$config.SchemaVersion -eq 2) {
            '^E000[0-9A-F]{12}$'
        } else { '^E[0-9A-F]{15}$' }
        if ($xuid -notmatch $xuidPattern) {
            throw "$($entry.Name).ProfileXuid does not match a persisted Xenia offline XUID."
        }
        $controller = ([string]$entry.Value.Controller).ToUpperInvariant()
        if ($controller -notmatch '^0X[0-9A-F]{4}/0X[0-9A-F]{4}$') {
            throw "$($entry.Name).Controller must use 0xVVVV/0xPPPP form."
        }
        $controller = $controller.Replace('0X', '0x')
        $mask = Normalize-CpuMask -Value ([string]$entry.Value.CpuMask) `
            -Label "$($entry.Name).CpuMask"
        $onlineXuid = ''
        $macAddress = ''
        $hostAddress = ''
        $playerPort = 0
        if ([int]$config.SchemaVersion -eq 2) {
            $onlineXuid = ([string]$entry.Value.OnlineXuid).ToUpperInvariant()
            $macAddress = ([string]$entry.Value.MacAddress).ToUpperInvariant()
            $hostAddress = [string]$entry.Value.HostAddress
            if ($onlineXuid -notmatch '^0009[0-9A-F]{12}$') {
                throw "$($entry.Name).OnlineXuid must be a persisted 0009 plus 12-hex XUID."
            }
            if ($macAddress -notmatch '^7C1E52[0-9A-F]{6}$') {
                throw "$($entry.Name).MacAddress must be a fresh Xenia 7C1E52 plus 6-hex MAC."
            }
            if ($xuid.Substring(8, 8) -cne $macAddress.Substring(4, 8)) {
                throw "$($entry.Name) offline XUID and Xenia MAC suffixes do not match."
            }
            $lastThree = $macAddress.Substring(6, 6)
            $derivedHostAddress = '127.{0}.{1}.{2}' -f
                [Convert]::ToByte($lastThree.Substring(0, 2), 16),
                [Convert]::ToByte($lastThree.Substring(2, 2), 16),
                [Convert]::ToByte($lastThree.Substring(4, 2), 16)
            if ($hostAddress -cne $derivedHostAddress) {
                throw "$($entry.Name).HostAddress must equal the address derived from its Xenia MAC: $derivedHostAddress"
            }
            $playerPort = 36001 +
                ([Convert]::ToUInt64($macAddress, 16) -band 0x3FF)
        }
        $normalizedSides[$entry.Name] = [pscustomobject]@{
            RigDir = $rigDir
            ProfileXuid = $xuid
            Controller = $controller
            CpuMask = $mask.Text
            CpuMaskValue = $mask.Value
            InvertRightX = $invertRightX
            OnlineXuid = $onlineXuid
            MacAddress = $macAddress
            HostAddress = $hostAddress
            PlayerPort = $playerPort
        }
    }
    if ($normalizedSides.Daddy.ProfileXuid -ceq $normalizedSides.Cj.ProfileXuid) {
        throw 'Daddy and CJ must use distinct offline profile XUIDs.'
    }
    if ($normalizedSides.Daddy.RigDir -ieq $normalizedSides.Cj.RigDir) {
        throw 'Daddy and CJ must use distinct rig directories.'
    }
    if ($normalizedSides.Daddy.Controller -ceq $normalizedSides.Cj.Controller) {
        throw 'The first portable alpha requires controllers with distinct VID/PID routes.'
    }
    if (($normalizedSides.Daddy.CpuMaskValue -band
         $normalizedSides.Cj.CpuMaskValue) -ne 0) {
        throw 'Daddy and CJ CPU masks overlap.'
    }
    if ([int]$config.SchemaVersion -eq 2) {
        if ($normalizedSides.Daddy.OnlineXuid -ceq
            $normalizedSides.Cj.OnlineXuid) {
            throw 'Daddy and CJ must use distinct persisted online XUIDs.'
        }
        if ($normalizedSides.Daddy.MacAddress -ceq
            $normalizedSides.Cj.MacAddress -or
            $normalizedSides.Daddy.HostAddress -ceq
            $normalizedSides.Cj.HostAddress) {
            throw 'Daddy and CJ generated network identities must be distinct.'
        }
        if ([int]$normalizedSides.Daddy.PlayerPort -eq
            [int]$normalizedSides.Cj.PlayerPort) {
            throw ("Daddy and CJ MAC addresses collide on synthetic UDP " +
                "player port $($normalizedSides.Daddy.PlayerPort); generate a different identity.")
        }
        $rigRoot = [IO.Path]::GetFullPath((Join-Path $installRoot 'rigs')).TrimEnd('\')
        foreach ($sideName in 'Daddy', 'Cj') {
            $parent = [IO.Path]::GetDirectoryName(
                [string]$normalizedSides[$sideName].RigDir).TrimEnd('\')
            if (-not [string]::Equals($parent, $rigRoot,
                    [StringComparison]::OrdinalIgnoreCase)) {
                throw "$sideName.RigDir must be a direct child of InstallRoot\rigs."
            }
        }
        $gameMask = $normalizedSides.Daddy.CpuMaskValue -bor
            $normalizedSides.Cj.CpuMaskValue
        if (($gameMask -band $xwsMask.Value) -ne 0 -or
            ($gameMask -band $feslMask.Value) -ne 0) {
            throw 'Backend CPU masks must not overlap either Xenia CPU mask.'
        }
        if (($feslMask.Value -band $xwsMask.Value) -ne $feslMask.Value) {
            throw 'FeslCpuMask must be a subset of XwsCpuMask reserved service cores.'
        }
        $managedMask = $gameMask -bor $xwsMask.Value
        if (($managedMask -band $reservedMask.Value) -ne 0) {
            throw 'ReservedCpuMask must not overlap either rig or service masks.'
        }
    }

    return [pscustomobject]@{
        SchemaVersion = [int]$config.SchemaVersion
        InstallRoot = $installRoot
        GamePath = $gamePath
        ApiAddress = $apiAddress
        XeniaFileName = $xeniaFileName
        SaveSlot = $saveSlot
        XwsRoot = $xwsRoot
        NodeExe = $nodeExe
        PythonExe = $pythonExe
        XwsCpuMask = $xwsMask.Text
        XwsCpuMaskValue = $xwsMask.Value
        FeslCpuMask = $feslMask.Text
        FeslCpuMaskValue = $feslMask.Value
        FeslSeconds = $feslSeconds
        CpuAllocationPolicy = $cpuAllocationPolicy
        CpuTopologySignature = $cpuTopologySignature
        ReservedCpuMask = $reservedMask.Text
        ReservedCpuMaskValue = $reservedMask.Value
        Daddy = $normalizedSides.Daddy
        Cj = $normalizedSides.Cj
    }
}

$profileManifestPath = Join-Path $ProfileRoot 'profile.psd1'
if (-not (Test-Path -LiteralPath $profileManifestPath -PathType Leaf)) {
    throw "B19 profile manifest is missing: $profileManifestPath"
}
$profile = Import-PowerShellDataFile -LiteralPath $profileManifestPath
if ($profile.SchemaVersion -ne 2 -or $profile.Name -cne 'B19') {
    throw 'Unsupported or malformed launch-profile manifest.'
}

$frozenProfilePatches = @($profile.FrozenProfileCoopPatches)
if ($frozenProfilePatches.Count -ne 3) {
    throw 'The B19 profile must declare exactly three frozen-profile co-op patches.'
}
foreach ($patchEntry in $frozenProfilePatches) {
    foreach ($key in 'FileName', 'Sha256', 'PatchName', 'Type', 'Address', 'Value') {
        if (-not $patchEntry.ContainsKey($key)) {
            throw "Frozen-profile co-op patch manifest entry is missing $key."
        }
    }
    $canonicalPatchPath = Join-Path (Join-Path $ProfileRoot 'patches') `
        ([string]$patchEntry.FileName)
    if (-not (Test-Path -LiteralPath $canonicalPatchPath -PathType Leaf)) {
        throw "Canonical B19 patch is missing: $canonicalPatchPath"
    }
    if ((Get-FileSha256 $canonicalPatchPath) -cne [string]$patchEntry.Sha256) {
        throw "Canonical B19 patch hash mismatch: $($patchEntry.FileName)"
    }
    $patchText = Get-Content -Raw -LiteralPath $canonicalPatchPath
    if ([regex]::Matches($patchText,
            '(?m)^\s*is_enabled\s*=\s*true\s*$').Count -ne 1 -or
        $patchText -notmatch '(?m)^\s*title_id\s*=\s*"454108D8"\s*$' -or
        $patchText -notmatch [regex]::Escape('"7C5F016EA6A81E95"') -or
        $patchText -notmatch
            [regex]::Escape("[[patch.$($patchEntry.Type)]]") -or
        $patchText -notmatch ("(?im)^\s*address\s*=\s*{0}\s*$" -f
            [regex]::Escape([string]$patchEntry.Address)) -or
        $patchText -notmatch ("(?im)^\s*value\s*=\s*{0}\s*$" -f
            [regex]::Escape([string]$patchEntry.Value))) {
        throw "Canonical B19 patch semantics mismatch: $($patchEntry.FileName)"
    }
}

$config = Get-NormalizedConfig -Path $ConfigPath
$sideConfig = $config.$Side
$peerConfig = if ($Side -eq 'Daddy') { $config.Cj } else { $config.Daddy }
$sideProfile = $profile.$Side
$templatePath = Join-Path $ProfileRoot ([string]$sideProfile.Template)
if (-not (Test-Path -LiteralPath $templatePath -PathType Leaf)) {
    throw "B19 $Side launch template is missing: $templatePath"
}
$templateSha256 = Get-FileSha256 $templatePath
if ($templateSha256 -cne [string]$sideProfile.TemplateSha256) {
    throw "B19 $Side launch template hash mismatch: $templateSha256"
}
$template = (Get-Content -Raw -LiteralPath $templatePath).TrimEnd("`r", "`n")
if ([regex]::Matches($template,
        '"xenia_canary_netplay\.exe"').Count -ne 1) {
    throw "$Side B19 template lost its single executable token."
}
$template = $template.Replace('"xenia_canary_netplay.exe"',
    '"{{XENIA_FILE_NAME}}"')

$injectPath = Join-Path $sideConfig.RigDir 'inject.txt'
$xeniaPath = Join-Path $sideConfig.RigDir $config.XeniaFileName
$rightXArg = if ($sideConfig.InvertRightX) {
    '--hid_sdl_invert_right_x=true'
} else { '' }
$replacements = [ordered]@{
    '"{{XENIA_FILE_NAME}}"' = '"' + $config.XeniaFileName + '"'
    '{{CPU_MASK}}' = $sideConfig.CpuMask
    '{{CONTROLLER_ARG}}' = "--hid_sdl_allowed_devices=$($sideConfig.Controller)"
    '{{RIGHT_X_ARG}}' = $rightXArg
    '{{PROFILE_XUID_ARG}}' = "--logged_profile_slot_0_xuid=$($sideConfig.ProfileXuid)"
    '{{PEER_PROFILE_XUID_ARG}}' = "--aot_peer_offline_xuid=0x$($peerConfig.ProfileXuid)"
    '{{INJECT_ARG}}' = ConvertTo-WindowsArgument "--aot_inject_keys=$injectPath"
    '{{API_ARG}}' = "--api_address=$($config.ApiAddress)"
    '{{GAME_ARG}}' = ConvertTo-WindowsArgument $config.GamePath
}
$templateTokens = @([regex]::Matches($template, '(?:"[^"]*"|\S+)') |
    ForEach-Object { $_.Value })
$resolvedTokens = [Collections.Generic.List[string]]::new()
foreach ($templateToken in $templateTokens) {
    if ($replacements.Contains($templateToken)) {
        $replacement = [string]$replacements[$templateToken]
        if (-not [string]::IsNullOrEmpty($replacement)) {
            $resolvedTokens.Add($replacement)
        }
    } else {
        $resolvedTokens.Add($templateToken)
    }
}
foreach ($entry in $replacements.GetEnumerator()) {
    $count = @($templateTokens | Where-Object { $_ -ceq [string]$entry.Key }).Count
    if ($count -ne 1) {
        throw "$Side template requires exactly one $($entry.Key); found $count."
    }
}
$line = $resolvedTokens -join ' '
if ($line -match '\{\{[^}]+\}\}') {
    throw "$Side launch plan retained an unresolved template placeholder."
}

$parsed = [regex]::Match($line,
    '^start "" /affinity (?<aff>[0-9A-Fa-f]{1,16}) /high "(?<exe>[^"]+)" (?<args>.+)$')
if (-not $parsed.Success) { throw "$Side launch plan has an invalid process shape." }
if ($parsed.Groups['aff'].Value -cne $sideConfig.CpuMask -or
    $parsed.Groups['exe'].Value -cne $config.XeniaFileName) {
    throw "$Side launch plan changed the configured mask or executable."
}

foreach ($required in @(
    '--aot_xnet_secassoc=true',
    '--aot_leg_fix_dest=true',
    '--aot_xport_probe=true',
    '--network_synthetic_loopback=true',
    '--aot_sp_join=false',
    '--aot_sp_force_listen=false',
    '--aot_hero_sync=false',
    '--aot_net_travel=false')) {
    if ([regex]::Matches($line,
        '(?<!\S)' + [regex]::Escape($required) + '(?=\s|$)').Count -ne 1) {
        throw "$Side launch plan requires exactly one $required"
    }
}
if ($line -match '(?i)82c8a0ac|--aot_(?:sp_join|sp_force_listen|hero_sync|net_travel)=true') {
    throw "$Side launch plan contains a forbidden fallback or death-wait trap."
}
foreach ($requiredDynamic in @(
    "--logged_profile_slot_0_xuid=$($sideConfig.ProfileXuid)",
    "--aot_peer_offline_xuid=0x$($peerConfig.ProfileXuid)",
    "--hid_sdl_allowed_devices=$($sideConfig.Controller)")) {
    if ([regex]::Matches($line,
        '(?<!\S)' + [regex]::Escape($requiredDynamic) + '(?=\s|$)').Count -ne 1) {
        throw "$Side launch plan requires exactly one $requiredDynamic"
    }
}
if ($sideConfig.InvertRightX -and
    $line -notmatch '(?<!\S)--hid_sdl_invert_right_x=true(?=\s|$)') {
    throw "$Side right-X correction was requested but is absent."
}
if (-not $sideConfig.InvertRightX -and
    $line -match '(?<!\S)--hid_sdl_invert_right_x=') {
    throw "$Side launch plan has an unrequested right-X correction."
}

$lineSha256 = Get-TextSha256 $line
if ($RequireFrozenFingerprint -and
    $lineSha256 -cne [string]$sideProfile.FrozenLineSha256) {
    throw "$Side portable plan differs from the frozen B19 line: $lineSha256"
}
if (-not $SkipFileChecks) {
    foreach ($file in $xeniaPath, $injectPath, $config.GamePath) {
        if (-not (Test-Path -LiteralPath $file -PathType Leaf)) {
            throw "Portable launch input is missing: $file"
        }
    }
    [string[]]$acceptedRuntimeHashes = @(if ($profile.ContainsKey(
            'AcceptedRuntimeXeniaSha256')) {
        $profile.AcceptedRuntimeXeniaSha256 | ForEach-Object {
            ([string]$_).ToUpperInvariant()
        }
    } else {
        ([string]$profile.XeniaSha256).ToUpperInvariant()
    })
    if ($acceptedRuntimeHashes.Count -eq 0 -or
        @($acceptedRuntimeHashes | Where-Object {
            $_ -notmatch '^[0-9A-F]{64}$'
        }).Count -ne 0) {
        throw 'B19 profile has no valid runtime-accepted Xenia hash.'
    }
    $actualXeniaSha256 = Get-FileSha256 $xeniaPath
    if ($RuntimeAcceptanceCandidate) {
        if (-not $profile.ContainsKey('PortableRuntimeCandidate') -or
            -not $profile.PortableRuntimeCandidate.ContainsKey(
                'SourceBuiltXeniaSha256')) {
            throw 'B19 profile has no declared source-built acceptance candidate.'
        }
        $candidateRuntimeHash = ([string]$profile.PortableRuntimeCandidate.SourceBuiltXeniaSha256).ToUpperInvariant()
        if ($candidateRuntimeHash -notmatch '^[0-9A-F]{64}$') {
            throw 'B19 profile has an invalid source-built acceptance candidate hash.'
        }
        if ($actualXeniaSha256 -cne $candidateRuntimeHash) {
            throw ("$Side Xenia executable does not match the declared " +
                "source-built acceptance candidate: $actualXeniaSha256")
        }
    } elseif ($actualXeniaSha256 -notin $acceptedRuntimeHashes) {
        throw "$Side Xenia executable is not runtime-accepted by the B19 profile: $actualXeniaSha256"
    }
    if ((Get-Content -Raw -LiteralPath $injectPath).Trim() -cne 'NONE') {
        throw "$Side inject.txt must contain exactly NONE."
    }
    $xeniaConfigPath = Join-Path $sideConfig.RigDir `
        ([string]$profile.XeniaConfigFileName)
    if (-not (Test-Path -LiteralPath $xeniaConfigPath -PathType Leaf)) {
        throw "$Side Xenia config is missing: $xeniaConfigPath"
    }
    $xeniaConfigText = Get-Content -Raw -LiteralPath $xeniaConfigPath
    if ($xeniaConfigText -notmatch
        '(?m)^\s*apply_patches\s*=\s*true\s*(?:#.*)?$') {
        throw "$Side Xenia config must set apply_patches=true."
    }
    foreach ($patchEntry in $frozenProfilePatches) {
        $rigPatchPath = Join-Path (Join-Path $sideConfig.RigDir 'patches') `
            ([string]$patchEntry.FileName)
        $acceptedPatchHashes = @([string]$patchEntry.Sha256)
        if ($patchEntry.ContainsKey('FrozenRigSha256')) {
            $acceptedPatchHashes += [string]$patchEntry.FrozenRigSha256
        }
        if (-not (Test-Path -LiteralPath $rigPatchPath -PathType Leaf) -or
            (Get-FileSha256 $rigPatchPath) -notin $acceptedPatchHashes) {
            throw "$Side frozen-profile co-op patch is missing or changed: $($patchEntry.FileName)"
        }
    }
    $enabledPatchNames = @(Get-EnabledPatchNames -PatchDirectory `
        (Join-Path $sideConfig.RigDir 'patches'))
    $requiredPatchNames = @($frozenProfilePatches | ForEach-Object {
        [string]$_.PatchName
    })
    $visualPatchNames = @($profile.FrozenVisualPatch.EnabledNames |
        ForEach-Object { [string]$_ })
    $allowedPatchNames = @($requiredPatchNames) + @($visualPatchNames)
    $unexpectedPatchNames = @($enabledPatchNames | Where-Object {
        $_ -notin $allowedPatchNames
    })
    $missingPatchNames = @($requiredPatchNames | Where-Object {
        $_ -notin $enabledPatchNames
    })
    $duplicatePatchNames = @($enabledPatchNames | Group-Object |
        Where-Object Count -gt 1)
    if ($unexpectedPatchNames.Count -ne 0 -or
        $missingPatchNames.Count -ne 0 -or
        $duplicatePatchNames.Count -ne 0) {
        throw (("{0} enabled patch set is unsafe: missing=[{1}] " +
            "unexpected=[{2}] duplicates=[{3}]") -f $Side,
            ($missingPatchNames -join ','),
            ($unexpectedPatchNames -join ','),
            (@($duplicatePatchNames | ForEach-Object Name) -join ','))
    }
    $enabledVisualPatchNames = @($enabledPatchNames | Where-Object {
        $_ -in $visualPatchNames
    })
    if ($enabledVisualPatchNames.Count -ne 0) {
        $visualPatchPath = Join-Path (Join-Path $sideConfig.RigDir 'patches') `
            ([string]$profile.FrozenVisualPatch.FileName)
        if (-not (Test-Path -LiteralPath $visualPatchPath -PathType Leaf) -or
            (Get-FileSha256 $visualPatchPath) -cne
                [string]$profile.FrozenVisualPatch.Sha256) {
            throw "$Side enabled visual patch does not match the frozen B19 manifest."
        }
    }
    if ($VerifyGameHash) {
        $gameInfo = Get-Item -LiteralPath $config.GamePath
        if ($gameInfo.Length -ne [int64]$profile.SupportedGame.IsoBytes -or
            (Get-FileSha256 $config.GamePath) -cne
                [string]$profile.SupportedGame.IsoSha256) {
            throw 'The user-supplied game image does not match the supported base disc.'
        }
    }
}

$argumentTokens = @([regex]::Matches($parsed.Groups['args'].Value,
    '(?:"[^"]*"|\S+)') | ForEach-Object { $_.Value })
$tokenCount = $argumentTokens.Count
$normalizedArgumentTokens = @($argumentTokens | ForEach-Object {
    if ($_.Length -ge 2 -and $_[0] -eq '"' -and $_[$_.Length - 1] -eq '"') {
        $_.Substring(1, $_.Length - 2)
    } else { $_ }
})
$optionTokens = @($normalizedArgumentTokens |
    Where-Object { $_ -match '^--[^=]+=' })
$optionNames = @($optionTokens | ForEach-Object {
    ([regex]::Match($_, '^--(?<name>[^=]+)=').Groups['name'].Value)
})
$duplicateNames = @($optionNames | Group-Object | Where-Object Count -gt 1)
$breakToken = @($optionTokens | Where-Object { $_ -match '^--aot_p2_breaks=' })
if ($breakToken.Count -ne 1) {
    throw "$Side B19 plan must contain exactly one aot_p2_breaks option."
}
$breakValue = $breakToken[0].Substring('--aot_p2_breaks='.Length)
$breakPcCount = @($breakValue -split ',').Count
$invertDelta = [int]$sideConfig.InvertRightX -
    [int][bool]$sideProfile.FrozenInvertRightX
$expectedTokenCount = [int]$sideProfile.FrozenTokenCount + $invertDelta
$expectedOptionCount = [int]$sideProfile.FrozenOptionCount + $invertDelta
if ($tokenCount -ne $expectedTokenCount -or
    $optionTokens.Count -ne $expectedOptionCount -or
    $breakPcCount -ne [int]$sideProfile.FrozenBreakPcCount -or
    $duplicateNames.Count -ne 0) {
    throw (("{0} B19 structure mismatch: tokens={1}, options={2}, " +
        "break_pcs={3}, duplicate_names={4}") -f $Side, $tokenCount,
        $optionTokens.Count, $breakPcCount, $duplicateNames.Count)
}
$result = [pscustomobject][ordered]@{
    SchemaVersion = 1
    Profile = 'B19'
    Side = $Side
    WorkingDirectory = $sideConfig.RigDir
    FilePath = $xeniaPath
    XeniaSha256 = if ($SkipFileChecks) { '' } else { $actualXeniaSha256 }
    Affinity = $sideConfig.CpuMask
    Priority = 'High'
    ArgumentList = $parsed.Groups['args'].Value
    CommandLine = $line
    CommandLineSha256 = $lineSha256
    TemplateSha256 = $templateSha256
    TokenCount = $tokenCount
    OptionCount = $optionTokens.Count
    BreakPcCount = $breakPcCount
    FrozenProfilePatchCount = $frozenProfilePatches.Count
    GamePath = $config.GamePath
    SaveSlot = $config.SaveSlot
    InstallRoot = $config.InstallRoot
    XwsRoot = $config.XwsRoot
    NodeExe = $config.NodeExe
    PythonExe = $config.PythonExe
    XwsCpuMask = $config.XwsCpuMask
    FeslCpuMask = $config.FeslCpuMask
    FeslSeconds = $config.FeslSeconds
    CpuAllocationPolicy = $config.CpuAllocationPolicy
    CpuTopologySignature = $config.CpuTopologySignature
    ReservedCpuMask = $config.ReservedCpuMask
    ProfileXuid = $sideConfig.ProfileXuid
    OnlineXuid = $sideConfig.OnlineXuid
    MacAddress = $sideConfig.MacAddress
    HostAddress = $sideConfig.HostAddress
    PlayerPort = $sideConfig.PlayerPort
    Controller = $sideConfig.Controller
    InvertRightX = $sideConfig.InvertRightX
    RuntimeAcceptanceCandidate = [bool]$RuntimeAcceptanceCandidate
    RuntimeProof = if ($RuntimeAcceptanceCandidate) {
        'SOURCE-BUILT CANDIDATE - RUNTIME ACCEPTANCE PENDING'
    } else {
        'NOT RUNTIME-TESTED AS A PORTABLE LAUNCHER'
    }
}

if ($AsJson) {
    $result | ConvertTo-Json -Depth 5
} else {
    Write-Output $result
}
