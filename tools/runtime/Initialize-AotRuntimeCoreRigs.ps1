[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$InstallRoot,

    [Parameter(Mandatory = $true)]
    [string]$CandidateXeniaPath,

    [string]$XeniaFileName = 'xenia_canary_netplay.exe',
    [string]$ProfileRoot = '',
    [switch]$SyntheticFixture,
    [string]$SyntheticProcessInventoryPath = '',
    [string]$SyntheticStagingName = '',

    [ValidateSet('None', 'CreateRigsDestination',
        'InjectUnknownStagingFileThenFail')]
    [string]$SyntheticBeforePublishAction = 'None',

    [ValidateSet('None', 'PrecreateDaddyDirectory',
        'PrecreateDaddyJunction')]
    [string]$SyntheticChildClaimAction = 'None',
    [string]$SyntheticChildHijackTarget = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (-not $SyntheticFixture) {
    throw 'PRODUCTION_RIG_SEEDING_CLOSURE_DEFERRED'
}
Import-Module Microsoft.PowerShell.Utility -ErrorAction Stop

$workspaceRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..')).TrimEnd('\')
$productionProfileRoot = [IO.Path]::GetFullPath((Join-Path $workspaceRoot `
    'profiles\b19-runtime-core-acceptance')).TrimEnd('\')
$profileRootWasExplicit = -not [string]::IsNullOrWhiteSpace($ProfileRoot)

function Initialize-AotRuntimeCoreNativeType {
    param([string]$CompilerTempRoot = '')
    if ($null -ne ('AotRuntimeCoreSeederNativeV1' -as [type])) { return }
    $oldTemp = $env:TEMP
    $oldTmp = $env:TMP
    try {
        if (-not [string]::IsNullOrWhiteSpace($CompilerTempRoot)) {
            $env:TEMP = $CompilerTempRoot
            $env:TMP = $CompilerTempRoot
        }
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class AotRuntimeCoreSeederNativeV1 {
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode,
        SetLastError = true, EntryPoint = "CreateDirectoryW")]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool CreateDirectory(
        string lpPathName, IntPtr lpSecurityAttributes);
}
'@
    } finally {
        if ($null -eq $oldTemp) {
            Remove-Item Env:TEMP -ErrorAction SilentlyContinue
        } else {
            $env:TEMP = $oldTemp
        }
        if ($null -eq $oldTmp) {
            Remove-Item Env:TMP -ErrorAction SilentlyContinue
        } else {
            $env:TMP = $oldTmp
        }
    }
}

function Resolve-SafeAbsolutePath {
    param(
        [Parameter(Mandatory = $true)][string]$Value,
        [Parameter(Mandatory = $true)][string]$Label
    )

    if ([string]::IsNullOrWhiteSpace($Value) -or $Value.Trim() -cne $Value -or
        $Value -match '[\x00\r\n"]' -or
        -not [IO.Path]::IsPathRooted($Value)) {
        throw "$Label must be a nonblank absolute path without unsafe text."
    }
    $segments = @($Value -split '[\\/]' | Where-Object { $_ -ne '' })
    if (@($segments | Where-Object { $_ -ceq '.' -or $_ -ceq '..' }).Count -ne 0) {
        throw "$Label may not contain dot traversal segments."
    }
    try {
        $fullPath = [IO.Path]::GetFullPath($Value).TrimEnd('\')
    } catch {
        throw "$Label is not a valid absolute path."
    }
    $volumeRoot = [IO.Path]::GetPathRoot($fullPath)
    if ([string]::IsNullOrWhiteSpace($volumeRoot)) {
        throw "$Label has no volume root."
    }
    $remainder = $fullPath.Substring($volumeRoot.TrimEnd('\').Length)
    if ($remainder.Contains(':')) {
        throw "$Label may not name an alternate data stream."
    }
    return $fullPath
}

function Test-IsUnderRoot {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Root
    )
    $prefix = $Root.TrimEnd('\') + '\'
    return $Path.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)
}

function Test-PathEntryExists {
    param([Parameter(Mandatory = $true)][string]$Path)
    try {
        $null = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
        return $true
    } catch [Management.Automation.ItemNotFoundException] {
        return $false
    }
}

function Assert-NoReparseInExistingPath {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Label
    )

    $cursor = $Path.TrimEnd('\')
    while (-not [string]::IsNullOrWhiteSpace($cursor)) {
        if (Test-PathEntryExists -Path $cursor) {
            $item = Get-Item -LiteralPath $cursor -Force -ErrorAction Stop
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "$Label may not traverse or name a reparse point: $cursor"
            }
        }
        $parent = [IO.Path]::GetDirectoryName($cursor)
        if ([string]::IsNullOrWhiteSpace($parent) -or
            [string]::Equals($parent.TrimEnd('\'), $cursor,
                [StringComparison]::OrdinalIgnoreCase)) {
            break
        }
        $cursor = $parent.TrimEnd('\')
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
        throw (('{0} keys differ from the inert-seed schema: missing=[{1}] ' +
            'unknown=[{2}]') -f $Label, ($missing -join ','),
            ($unknown -join ','))
    }
}

function Get-TextSha256 {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Text
    )
    $algorithm = [Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString($algorithm.ComputeHash(
            [Text.Encoding]::UTF8.GetBytes($Text)))) -replace '-', ''
    } finally {
        $algorithm.Dispose()
    }
}

function Get-StreamSha256 {
    param([Parameter(Mandatory = $true)][IO.Stream]$Stream)
    $Stream.Position = 0
    $algorithm = [Security.Cryptography.SHA256]::Create()
    try {
        $hash = ([BitConverter]::ToString($algorithm.ComputeHash($Stream))) `
            -replace '-', ''
    } finally {
        $algorithm.Dispose()
        $Stream.Position = 0
    }
    return $hash
}

function Read-LockedStreamText {
    param([Parameter(Mandatory = $true)][IO.Stream]$Stream)
    $Stream.Position = 0
    $reader = [IO.StreamReader]::new($Stream, [Text.Encoding]::UTF8,
        $true, 4096, $true)
    try {
        return $reader.ReadToEnd()
    } finally {
        $reader.Dispose()
        $Stream.Position = 0
    }
}

function Open-LockedSourceFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Label,
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [Collections.Generic.List[IDisposable]]$HandleList
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "$Label is missing: $Path"
    }
    Assert-NoReparseInExistingPath -Path $Path -Label $Label
    $stream = [IO.File]::Open($Path, [IO.FileMode]::Open,
        [IO.FileAccess]::Read, [IO.FileShare]::Read)
    $HandleList.Add($stream)
    return $stream
}

function Copy-LockedStreamToNewFile {
    param(
        [Parameter(Mandatory = $true)][IO.Stream]$Source,
        [Parameter(Mandatory = $true)][string]$Destination
    )
    $Source.Position = 0
    $output = [IO.File]::Open($Destination, [IO.FileMode]::CreateNew,
        [IO.FileAccess]::Write, [IO.FileShare]::None)
    try {
        $Source.CopyTo($output)
        $output.Flush($true)
    } finally {
        $output.Dispose()
        $Source.Position = 0
    }
}

function Write-NewFileBytes {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [byte[]]$Bytes
    )
    $output = [IO.File]::Open($Path, [IO.FileMode]::CreateNew,
        [IO.FileAccess]::Write, [IO.FileShare]::None)
    try {
        if ($Bytes.Length -ne 0) {
            $output.Write($Bytes, 0, $Bytes.Length)
        }
        $output.Flush($true)
    } finally {
        $output.Dispose()
    }
}

function Assert-CanonicalPatchText {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [Parameter(Mandatory = $true)][Collections.IDictionary]$Expected
    )
    if ([regex]::Matches($Text,
            '(?m)^\s*is_enabled\s*=\s*true\s*$').Count -ne 1 -or
        $Text -notmatch '(?m)^\s*title_id\s*=\s*"454108D8"\s*$' -or
        $Text -notmatch [regex]::Escape('"7C5F016EA6A81E95"') -or
        $Text -notmatch [regex]::Escape([string]$Expected.PatchName) -or
        $Text -notmatch [regex]::Escape("[[patch.$($Expected.Type)]]") -or
        $Text -notmatch ("(?im)^\s*address\s*=\s*{0}\s*$" -f
            [regex]::Escape([string]$Expected.Address)) -or
        $Text -notmatch ("(?im)^\s*value\s*=\s*{0}\s*$" -f
            [regex]::Escape([string]$Expected.Value))) {
        throw "Canonical runtime-core patch semantics mismatch: $($Expected.FileName)"
    }
}

function Assert-PathAbsent {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Label
    )
    if (Test-PathEntryExists -Path $Path) {
        throw "$Label already exists; inert seeding never overwrites it: $Path"
    }
}

function Get-NonReparseTreeEntries {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$Label
    )
    $pending = [Collections.Generic.Queue[string]]::new()
    $entries = [Collections.Generic.List[object]]::new()
    $pending.Enqueue($Root)
    while ($pending.Count -ne 0) {
        $directory = $pending.Dequeue()
        foreach ($item in @(Get-ChildItem -LiteralPath $directory -Force)) {
            if (($item.Attributes -band
                    [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "$Label contains a reparse point: $($item.FullName)"
            }
            $entries.Add($item)
            if ($item.PSIsContainer) {
                $pending.Enqueue($item.FullName)
            }
        }
    }
    return @($entries)
}

function New-CryptographicOwnerToken {
    $token = New-Object byte[] 32
    $generator = [Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        $generator.GetBytes($token)
    } finally {
        $generator.Dispose()
    }
    return $token
}

function New-AtomicStagingDirectory {
    param([Parameter(Mandatory = $true)][string]$Path)
    $created = [AotRuntimeCoreSeederNativeV1]::CreateDirectory(
        $Path, [IntPtr]::Zero)
    if (-not $created) {
        $errorCode = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
        throw ("Atomic CreateDirectoryW staging claim failed; no existing " +
            "entry is run-owned (Win32=$errorCode): $Path")
    }
}

function Assert-AtomicStagingOwnership {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$ExpectedParent,
        [Parameter(Mandatory = $true)][string]$ExpectedName
    )
    if (-not [string]::Equals([IO.Path]::GetDirectoryName($Path),
            $ExpectedParent, [StringComparison]::OrdinalIgnoreCase) -or
        [IO.Path]::GetFileName($Path) -cne $ExpectedName -or
        $ExpectedName -notmatch '^\.aot-runtime-core-rigs-staging-[0-9a-f]{32}$') {
        throw 'Atomically created staging directory is not the expected direct child.'
    }
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if (-not $item.PSIsContainer -or
        ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw 'Atomically created staging claim is not a normal directory.'
    }
    Assert-NoReparseInExistingPath -Path $Path `
        -Label 'Atomically created staging directory'
    [IO.File]::SetAttributes($Path,
        ($item.Attributes -bor [IO.FileAttributes]::Hidden))
}

function New-AtomicValidatedChildDirectory {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$ExpectedParent,
        [Parameter(Mandatory = $true)][string]$ExpectedName,
        [Parameter(Mandatory = $true)][string]$Label
    )
    if ([IO.Path]::GetFileName($ExpectedName) -cne $ExpectedName -or
        [string]::IsNullOrWhiteSpace($ExpectedName) -or
        -not [string]::Equals([IO.Path]::GetDirectoryName($Path),
            $ExpectedParent, [StringComparison]::OrdinalIgnoreCase) -or
        [IO.Path]::GetFileName($Path) -cne $ExpectedName) {
        throw "$Label is not the expected direct-child path."
    }
    $created = [AotRuntimeCoreSeederNativeV1]::CreateDirectory(
        $Path, [IntPtr]::Zero)
    if (-not $created) {
        $errorCode = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
        throw ("Atomic descendant CreateDirectoryW claim failed for $Label; " +
            "no existing entry is run-owned (Win32=$errorCode): $Path")
    }
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if (-not $item.PSIsContainer -or
        ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
        -not [string]::Equals([IO.Path]::GetDirectoryName($item.FullName),
            $ExpectedParent, [StringComparison]::OrdinalIgnoreCase) -or
        $item.Name -cne $ExpectedName) {
        throw "$Label claim is not a normal direct-child directory."
    }
    Assert-NoReparseInExistingPath -Path $Path -Label "$Label claim"
}

function Clear-VerifiedStagingHiddenAttribute {
    param([Parameter(Mandatory = $true)][string]$Path)
    Assert-NoReparseInExistingPath -Path $Path `
        -Label 'Verified staging directory before Hidden-bit clear'
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if (-not $item.PSIsContainer -or
        ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw 'Verified staging path changed before Hidden-bit clear.'
    }
    $attributes = [IO.FileAttributes]([int]$item.Attributes -band
        (-bnot [int][IO.FileAttributes]::Hidden))
    [IO.File]::SetAttributes($Path, $attributes)
    $verified = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if (($verified.Attributes -band [IO.FileAttributes]::Hidden) -ne 0 -or
        ($verified.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw 'Staging root did not become a normal visible directory before publish.'
    }
}

function Open-NewOwnerMarker {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][byte[]]$Token
    )
    $stream = [IO.File]::Open($Path, [IO.FileMode]::CreateNew,
        [IO.FileAccess]::ReadWrite, [IO.FileShare]::Read)
    try {
        $stream.Write($Token, 0, $Token.Length)
        $stream.Flush($true)
        [IO.File]::SetAttributes($Path, [IO.FileAttributes]::Hidden)
        $stream.Position = 0
        return $stream
    } catch {
        $stream.Dispose()
        throw
    }
}

function Assert-OwnerMarkerMatchesToken {
    param(
        [Parameter(Mandatory = $true)][string]$MarkerPath,
        [Parameter(Mandatory = $true)][byte[]]$Token,
        [Parameter(Mandatory = $true)][IO.FileStream]$MarkerStream
    )
    if (-not [string]::Equals($MarkerStream.Name, $MarkerPath,
            [StringComparison]::OrdinalIgnoreCase) -or
        $MarkerStream.Length -ne $Token.Length) {
        throw 'Run-owner marker handle does not match the expected marker.'
    }
    $item = Get-Item -LiteralPath $MarkerPath -Force -ErrorAction Stop
    if ($item.PSIsContainer -or
        ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
        $item.Length -ne $Token.Length) {
        throw 'Run-owner marker path is not the retained plain token file.'
    }
    $actual = New-Object byte[] $Token.Length
    $MarkerStream.Position = 0
    $offset = 0
    while ($offset -lt $actual.Length) {
        $read = $MarkerStream.Read($actual, $offset, $actual.Length - $offset)
        if ($read -le 0) { throw 'Run-owner marker ended before its token.' }
        $offset += $read
    }
    $MarkerStream.Position = 0
    $difference = 0
    for ($index = 0; $index -lt $Token.Length; $index++) {
        $difference = $difference -bor ($actual[$index] -bxor $Token[$index])
    }
    if ($difference -ne 0) {
        throw 'Run-owner marker token does not match this seeder run.'
    }
}

function Get-ExactTreeReceipt {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$SeededXeniaFileName,
        [Parameter(Mandatory = $true)][int64]$XeniaLength,
        [Parameter(Mandatory = $true)][string]$XeniaHash,
        [Parameter(Mandatory = $true)][object[]]$Patches,
        [string]$OwnerMarkerName = '',
        [string]$OwnerMarkerSha256 = '',
        [IO.FileStream]$OwnerMarkerStream = $null
    )

    if (-not (Test-Path -LiteralPath $Root -PathType Container)) {
        throw "Seed tree is missing: $Root"
    }
    Assert-NoReparseInExistingPath -Path $Root -Label 'Seed tree'
    $expectedDirectories = @('cj', 'cj\patches', 'daddy', 'daddy\patches')
    $expectedFiles = [Collections.Generic.List[string]]::new()
    foreach ($side in 'daddy', 'cj') {
        $expectedFiles.Add("$side\$SeededXeniaFileName")
        $expectedFiles.Add("$side\portable.txt")
        $expectedFiles.Add("$side\inject.txt")
        foreach ($patch in $Patches) {
            $expectedFiles.Add("$side\patches\$($patch.FileName)")
        }
    }
    if (-not [string]::IsNullOrWhiteSpace($OwnerMarkerName)) {
        if ($OwnerMarkerName -cne '.aot-runtime-core-owner' -or
            $OwnerMarkerSha256 -notmatch '^[0-9A-F]{64}$' -or
            $null -eq $OwnerMarkerStream) {
            throw 'Owner marker closure arguments are invalid.'
        }
        $expectedFiles.Add($OwnerMarkerName)
    }
    $expectedDirectories = @($expectedDirectories | Sort-Object)
    $expectedFileNames = @($expectedFiles | Sort-Object)
    $actualDirectories = [Collections.Generic.List[string]]::new()
    $actualFiles = [Collections.Generic.List[string]]::new()
    foreach ($item in @(Get-NonReparseTreeEntries -Root $Root `
            -Label 'Seed tree')) {
        $relative = $item.FullName.Substring($Root.Length).TrimStart('\')
        if ($item.PSIsContainer) {
            $actualDirectories.Add($relative)
        } else {
            $actualFiles.Add($relative)
        }
    }
    $actualDirectoryNames = @($actualDirectories | Sort-Object)
    $actualFileNames = @($actualFiles | Sort-Object)
    if (@(Compare-Object -ReferenceObject $expectedDirectories `
            -DifferenceObject $actualDirectoryNames -SyncWindow 0).Count -ne 0 -or
        @(Compare-Object -ReferenceObject $expectedFileNames `
            -DifferenceObject $actualFileNames -SyncWindow 0).Count -ne 0) {
        throw 'Seed tree closure differs from the exact inert two-rig layout.'
    }

    $emptyHash = Get-TextSha256 -Text ''
    $injectHash = Get-TextSha256 -Text 'NONE'
    $receipt = [Collections.Generic.List[object]]::new()
    foreach ($relative in $expectedFileNames) {
        $path = Join-Path $Root $relative
        $info = Get-Item -LiteralPath $path -Force -ErrorAction Stop
        $hash = if ($relative -ceq $OwnerMarkerName) {
            Get-StreamSha256 -Stream $OwnerMarkerStream
        } else {
            (Get-FileHash -Algorithm SHA256 -LiteralPath $path).Hash
        }
        $leaf = [IO.Path]::GetFileName($relative)
        $expectedLength = $null
        $expectedHash = $null
        $includeInReceipt = $true
        if ($relative -ceq $OwnerMarkerName) {
            $expectedLength = 32
            $expectedHash = $OwnerMarkerSha256
            $includeInReceipt = $false
        } elseif ($leaf -ceq $SeededXeniaFileName) {
            $expectedLength = $XeniaLength
            $expectedHash = $XeniaHash
        } elseif ($leaf -ceq 'portable.txt') {
            $expectedLength = 0
            $expectedHash = $emptyHash
        } elseif ($leaf -ceq 'inject.txt') {
            $expectedLength = 4
            $expectedHash = $injectHash
        } else {
            $patch = @($Patches | Where-Object {
                [string]$_.FileName -ceq $leaf
            })
            if ($patch.Count -ne 1) {
                throw "Seed tree contains an undeclared file: $relative"
            }
            $expectedLength = [int64]$patch[0].Length
            $expectedHash = [string]$patch[0].Sha256
        }
        if ($info.Length -ne $expectedLength -or $hash -cne $expectedHash) {
            throw "Seeded file verification failed: $relative"
        }
        if ($includeInReceipt) {
            $receipt.Add([pscustomobject][ordered]@{
                RelativePath = $relative
                Length = [int64]$info.Length
                SHA256 = $hash
            })
        }
    }
    return @($receipt)
}

function Remove-ValidatedRunOwnedStagingTree {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$ExpectedPath,
        [Parameter(Mandatory = $true)][string]$ExpectedName,
        [Parameter(Mandatory = $true)][string]$ExpectedParent,
        [Parameter(Mandatory = $true)][string]$OwnerMarkerPath,
        [Parameter(Mandatory = $true)][byte[]]$OwnerToken,
        [Parameter(Mandatory = $true)][IO.FileStream]$OwnerMarkerStream,
        [Parameter(Mandatory = $true)][string]$SeededXeniaFileName,
        [Parameter(Mandatory = $true)][string[]]$PatchFileNames
    )
    if (-not (Test-PathEntryExists -Path $Path)) { return }
    if (-not [string]::Equals($Path, $ExpectedPath,
            [StringComparison]::OrdinalIgnoreCase) -or
        -not [string]::Equals([IO.Path]::GetDirectoryName($Path),
            $ExpectedParent, [StringComparison]::OrdinalIgnoreCase) -or
        [IO.Path]::GetFileName($Path) -cne $ExpectedName -or
        $ExpectedName -notmatch '^\.aot-runtime-core-rigs-staging-[0-9a-f]{32}$') {
        throw 'Refusing cleanup because the staging path is not this run-owned direct child.'
    }
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        throw 'Refusing cleanup because the run-owned staging path is not a directory.'
    }
    Assert-NoReparseInExistingPath -Path $Path -Label 'Run-owned staging tree'
    if (-not [string]::Equals([IO.Path]::GetDirectoryName($OwnerMarkerPath),
            $Path, [StringComparison]::OrdinalIgnoreCase) -or
        [IO.Path]::GetFileName($OwnerMarkerPath) -cne
            '.aot-runtime-core-owner') {
        throw 'Refusing cleanup because the owner marker is not a direct child.'
    }
    Assert-OwnerMarkerMatchesToken -MarkerPath $OwnerMarkerPath `
        -Token $OwnerToken -MarkerStream $OwnerMarkerStream
    $allowedDirectories = @('cj', 'cj\patches', 'daddy', 'daddy\patches')
    $allowedFiles = [Collections.Generic.List[string]]::new()
    $allowedFiles.Add('.aot-runtime-core-owner')
    foreach ($side in 'daddy', 'cj') {
        $allowedFiles.Add("$side\$SeededXeniaFileName")
        $allowedFiles.Add("$side\portable.txt")
        $allowedFiles.Add("$side\inject.txt")
        foreach ($patchFileName in $PatchFileNames) {
            $allowedFiles.Add("$side\patches\$patchFileName")
        }
    }
    $observedFiles = [Collections.Generic.List[string]]::new()
    $observedDirectories = [Collections.Generic.List[string]]::new()
    foreach ($item in @(Get-NonReparseTreeEntries -Root $Path `
            -Label 'Refusing cleanup because staging')) {
        $relative = $item.FullName.Substring($Path.Length).TrimStart('\')
        if ($item.PSIsContainer) {
            if ($allowedDirectories -cnotcontains $relative) {
                throw "Refusing cleanup because staging contains an unknown directory: $relative"
            }
            $observedDirectories.Add($relative)
        } else {
            if (@($allowedFiles) -cnotcontains $relative) {
                throw "Refusing cleanup because staging contains an unknown file: $relative"
            }
            $observedFiles.Add($relative)
        }
    }
    foreach ($relative in $observedFiles) {
        if ($relative -cne '.aot-runtime-core-owner') {
            [IO.File]::Delete((Join-Path $Path $relative))
        }
    }
    foreach ($relative in @($observedDirectories |
            Sort-Object { ($_ -split '\\').Count } -Descending)) {
        $directoryPath = Join-Path $Path $relative
        if ([IO.Directory]::Exists($directoryPath)) {
            [IO.Directory]::Delete($directoryPath, $false)
        }
    }
    $remaining = @(Get-ChildItem -LiteralPath $Path -Force)
    if ($remaining.Count -ne 1 -or $remaining[0].PSIsContainer -or
        $remaining[0].Name -cne '.aot-runtime-core-owner' -or
        -not [string]::Equals($remaining[0].FullName, $OwnerMarkerPath,
            [StringComparison]::OrdinalIgnoreCase) -or
        ($remaining[0].Attributes -band
            [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw 'Refusing cleanup because the owner marker is not the only remaining root entry.'
    }
    Assert-OwnerMarkerMatchesToken -MarkerPath $OwnerMarkerPath `
        -Token $OwnerToken -MarkerStream $OwnerMarkerStream
    $OwnerMarkerStream.Dispose()
    [IO.File]::Delete($OwnerMarkerPath)
    [IO.Directory]::Delete($Path, $false)
}

$trustedSyntheticRoot = $null

$InstallRoot = Resolve-SafeAbsolutePath -Value $InstallRoot -Label 'InstallRoot'
$CandidateXeniaPath = Resolve-SafeAbsolutePath -Value $CandidateXeniaPath `
    -Label 'CandidateXeniaPath'
if ([string]::IsNullOrWhiteSpace($ProfileRoot)) {
    $ProfileRoot = $productionProfileRoot
} else {
    $ProfileRoot = Resolve-SafeAbsolutePath -Value $ProfileRoot -Label 'ProfileRoot'
}
if (-not [string]::IsNullOrWhiteSpace($SyntheticProcessInventoryPath)) {
    $SyntheticProcessInventoryPath = Resolve-SafeAbsolutePath `
        -Value $SyntheticProcessInventoryPath `
        -Label 'SyntheticProcessInventoryPath'
}
if (-not [string]::IsNullOrWhiteSpace($SyntheticChildHijackTarget)) {
    $SyntheticChildHijackTarget = Resolve-SafeAbsolutePath `
        -Value $SyntheticChildHijackTarget `
        -Label 'SyntheticChildHijackTarget'
}

if ($profileRootWasExplicit -and -not $SyntheticFixture) {
    throw 'ProfileRoot overrides are reserved for SyntheticFixture tests.'
}
if ($SyntheticFixture) {
    $localApplicationDataValue = [Environment]::GetFolderPath(
        [Environment+SpecialFolder]::LocalApplicationData)
    if ([string]::IsNullOrWhiteSpace($localApplicationDataValue)) {
        throw 'Windows LocalApplicationData Known Folder could not be resolved.'
    }
    $localApplicationDataRoot = Resolve-SafeAbsolutePath `
        -Value $localApplicationDataValue `
        -Label 'LocalApplicationData Known Folder'
    if ([string]::Equals($localApplicationDataRoot.TrimEnd('\'),
            ([IO.Path]::GetPathRoot($localApplicationDataRoot)).TrimEnd('\'),
            [StringComparison]::OrdinalIgnoreCase) -or
        -not (Test-Path -LiteralPath $localApplicationDataRoot `
            -PathType Container)) {
        throw 'LocalApplicationData Known Folder must be an existing non-root directory.'
    }
    Assert-NoReparseInExistingPath -Path $localApplicationDataRoot `
        -Label 'LocalApplicationData Known Folder'
    $trustedSyntheticRoot = [IO.Path]::GetFullPath((Join-Path `
        $localApplicationDataRoot 'Temp')).TrimEnd('\')
    if (-not [string]::Equals(
            [IO.Path]::GetDirectoryName($trustedSyntheticRoot),
            $localApplicationDataRoot,
            [StringComparison]::OrdinalIgnoreCase) -or
        -not (Test-Path -LiteralPath $trustedSyntheticRoot `
            -PathType Container)) {
        throw 'Trusted synthetic root must be the existing direct LocalApplicationData\Temp child.'
    }
    Assert-NoReparseInExistingPath -Path $trustedSyntheticRoot `
        -Label 'Trusted LocalApplicationData\Temp synthetic root'
    if (-not $profileRootWasExplicit) {
        throw 'SyntheticFixture requires an explicit ProfileRoot under the trusted synthetic root.'
    }
    if ([string]::IsNullOrWhiteSpace($SyntheticProcessInventoryPath)) {
        throw 'SyntheticFixture requires an explicit process-inventory fixture under the trusted synthetic root.'
    }
    $syntheticPaths = @(
        @{ Path = $InstallRoot; Label = 'InstallRoot' },
        @{ Path = $CandidateXeniaPath; Label = 'CandidateXeniaPath' },
        @{ Path = $ProfileRoot; Label = 'ProfileRoot' },
        @{ Path = $SyntheticProcessInventoryPath; Label =
            'SyntheticProcessInventoryPath' })
    if (-not [string]::IsNullOrWhiteSpace($SyntheticChildHijackTarget)) {
        $syntheticPaths += @{
            Path = $SyntheticChildHijackTarget
            Label = 'SyntheticChildHijackTarget'
        }
    }
    foreach ($entry in $syntheticPaths) {
        if (-not (Test-IsUnderRoot -Path $entry.Path `
                -Root $trustedSyntheticRoot)) {
            throw ("$($entry.Label) must stay under trusted " +
                'LocalApplicationData\Temp for SyntheticFixture.')
        }
    }
} else {
    if (-not [string]::IsNullOrWhiteSpace($SyntheticProcessInventoryPath) -or
        -not [string]::IsNullOrWhiteSpace($SyntheticStagingName) -or
        $SyntheticBeforePublishAction -cne 'None' -or
        $SyntheticChildClaimAction -cne 'None' -or
        -not [string]::IsNullOrWhiteSpace($SyntheticChildHijackTarget)) {
        throw 'Synthetic inventory, staging names, and race actions require SyntheticFixture.'
    }
    if (-not [string]::Equals($ProfileRoot, $productionProfileRoot,
            [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Production seeding uses only the reviewed runtime-core profile.'
    }
}
if ($SyntheticChildClaimAction -ceq 'PrecreateDaddyJunction') {
    if ([string]::IsNullOrWhiteSpace($SyntheticChildHijackTarget)) {
        throw 'PrecreateDaddyJunction requires a synthetic hijack target.'
    }
} elseif (-not [string]::IsNullOrWhiteSpace($SyntheticChildHijackTarget)) {
    throw 'SyntheticChildHijackTarget is valid only for PrecreateDaddyJunction.'
}
if (-not [string]::IsNullOrWhiteSpace($SyntheticStagingName) -and
    $SyntheticStagingName -notmatch
        '^\.aot-runtime-core-rigs-staging-[0-9a-f]{32}$') {
    throw 'SyntheticStagingName must use the exact hidden staging-name shape.'
}
if ([string]::Equals($InstallRoot, $ProfileRoot,
        [StringComparison]::OrdinalIgnoreCase)) {
    throw 'InstallRoot and ProfileRoot must be distinct directories.'
}
if ([IO.Path]::GetFileName($XeniaFileName) -cne $XeniaFileName -or
    $XeniaFileName.Contains('..') -or
    $XeniaFileName -notmatch '(?i)^xenia[A-Za-z0-9._-]{0,95}\.exe$') {
    throw 'XeniaFileName must be one safe, non-nested xenia*.exe file name.'
}
if ([IO.Path]::GetFileName($CandidateXeniaPath) -notmatch
        '(?i)^xenia[A-Za-z0-9._-]{0,95}\.exe$') {
    throw 'CandidateXeniaPath must name a plain xenia*.exe source file.'
}

if (-not (Test-Path -LiteralPath $InstallRoot -PathType Container)) {
    throw "InstallRoot must be an existing directory: $InstallRoot"
}
if ([string]::Equals($InstallRoot.TrimEnd('\'),
        ([IO.Path]::GetPathRoot($InstallRoot)).TrimEnd('\'),
        [StringComparison]::OrdinalIgnoreCase)) {
    throw 'InstallRoot may not be a volume root.'
}
Assert-NoReparseInExistingPath -Path $InstallRoot -Label 'InstallRoot'
if (-not (Test-Path -LiteralPath $ProfileRoot -PathType Container)) {
    throw "Runtime-core profile directory is missing: $ProfileRoot"
}
Assert-NoReparseInExistingPath -Path $ProfileRoot -Label 'ProfileRoot'
Assert-NoReparseInExistingPath -Path $CandidateXeniaPath `
    -Label 'CandidateXeniaPath'
if ($SyntheticChildClaimAction -ceq 'PrecreateDaddyJunction') {
    if (-not (Test-Path -LiteralPath $SyntheticChildHijackTarget `
            -PathType Container)) {
        throw 'Synthetic child-junction hijack target must be an existing directory.'
    }
    Assert-NoReparseInExistingPath -Path $SyntheticChildHijackTarget `
        -Label 'Synthetic child-junction hijack target'
    if ([string]::Equals($SyntheticChildHijackTarget, $InstallRoot,
            [StringComparison]::OrdinalIgnoreCase) -or
        (Test-IsUnderRoot -Path $SyntheticChildHijackTarget `
            -Root $InstallRoot) -or
        (Test-IsUnderRoot -Path $InstallRoot `
            -Root $SyntheticChildHijackTarget)) {
        throw 'Synthetic child-junction hijack target must be separate from InstallRoot.'
    }
}

$rigsRoot = [IO.Path]::GetFullPath((Join-Path $InstallRoot 'rigs')).TrimEnd('\')
if (-not [string]::Equals([IO.Path]::GetDirectoryName($rigsRoot),
        $InstallRoot, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'The rigs destination must be a direct child of InstallRoot.'
}
Assert-PathAbsent -Path $rigsRoot -Label 'The entire InstallRoot\rigs path'

$expectedPatches = @(
    @{
        FileName = '454108D8 - coop-bind-6000.patch.toml'
        Sha256 = 'BCD3F9A62106424908DA3AD8B543D1A482D4C4561DCCBF26D8EBE99A8CFBE295'
        PatchName = 'Coop - bind real UDP :6000 (same-PC loopback shim)'
        Type = 'be32'; Address = '0x82322AF8'; Value = '0x4800003C'
    },
    @{
        FileName = '454108D8 - coop-cod-unaddressed.patch.toml'
        Sha256 = 'F5CC6083791194E48106E4DE7D6D31C061BAFB43FA90EE935A56698398BC5036'
        PatchName = 'Coop - force unaddressed COd framing (same-PC handshake shim)'
        Type = 'be32'; Address = '0x8239D6C0'; Value = '0x39600000'
    },
    @{
        FileName = '454108D8 - coop-hold-connecting-v2.patch.toml'
        Sha256 = 'F01126934D5CE6E7DBC9D3C51D3F119DA7C50684B83AF838B4C3C8ED22497440'
        PatchName = 'Coop - HOLD at CONNECTING v2 (branch-scoped give-up no-op)'
        Type = 'be32'; Address = '0x82C86A48'; Value = '0x480001C8'
    })

$sourceHandles = [Collections.Generic.List[IDisposable]]::new()
$patchSources = [Collections.Generic.List[object]]::new()
$stagingName = if ($SyntheticFixture -and
    -not [string]::IsNullOrWhiteSpace($SyntheticStagingName)) {
    $SyntheticStagingName
} else {
    '.aot-runtime-core-rigs-staging-' + [Guid]::NewGuid().ToString('N')
}
$stagingRoot = [IO.Path]::GetFullPath((Join-Path $InstallRoot $stagingName))
$ownerMarkerPath = Join-Path $stagingRoot '.aot-runtime-core-owner'
$ownerToken = New-CryptographicOwnerToken
$ownerHashAlgorithm = [Security.Cryptography.SHA256]::Create()
try {
    $ownerTokenHash = ([BitConverter]::ToString(
        $ownerHashAlgorithm.ComputeHash($ownerToken))) -replace '-', ''
} finally {
    $ownerHashAlgorithm.Dispose()
}
$ownerMarkerStream = $null
$ownerTokenArmed = $false
$stagingCreated = $false
$published = $false
$processCheckCount = 0
$atomicChildClaimCount = 0
$receipt = $null

try {
    $profilePath = Join-Path $ProfileRoot 'profile.psd1'
    $profileStream = Open-LockedSourceFile -Path $profilePath `
        -Label 'Runtime-core profile' -HandleList $sourceHandles
    $profileText = Read-LockedStreamText -Stream $profileStream
    $normalizedProfileText = $profileText.Replace("`r`n", "`n").Replace("`r", "`n")
    $profileSha256 = Get-TextSha256 -Text $normalizedProfileText
    if (-not $SyntheticFixture -and $profileSha256 -cne
            '87987BECC70800C3D7CA3434E7BE15365A8E3053185E04121AE38525BFA5E891') {
        throw "Reviewed runtime-core profile hash mismatch: $profileSha256"
    }
    $profile = Import-PowerShellDataFile -LiteralPath $profilePath
    if ($null -eq $profile -or
        -not ($profile -is [Collections.IDictionary])) {
        throw 'Runtime-core profile must be a PowerShell data-file hashtable.'
    }
    Assert-ExactKeys -Table $profile -Label 'Runtime-core profile' -Expected @(
        'SchemaVersion', 'Name', 'ArtifactClass', 'PlayerKitReady',
        'RuntimeTested', 'LaunchCapable', 'SourceCommit', 'SourceTree',
        'XeniaBytes', 'XeniaSha256', 'TitleId', 'MediaId', 'TitleModuleHash',
        'SupportedGame', 'AllowedAotOptions', 'RequiredPatches',
        'PendingRuntimeGates', 'RequiredSa2AcceptanceMarkers', 'Daddy', 'Cj')
    if ([int]$profile.SchemaVersion -ne 1 -or
        [string]$profile.Name -cne 'B19-Runtime-Core-Acceptance' -or
        [string]$profile.ArtifactClass -cne
            'OFFLINE_ACCEPTANCE_PLAN_NOT_PLAYER_KIT' -or
        -not ($profile.PlayerKitReady -is [bool]) -or
        -not ($profile.RuntimeTested -is [bool]) -or
        -not ($profile.LaunchCapable -is [bool]) -or
        [bool]$profile.PlayerKitReady -or [bool]$profile.RuntimeTested -or
        [bool]$profile.LaunchCapable) {
        throw 'Runtime-core profile is malformed or overstates readiness.'
    }
    if ([string]$profile.SourceCommit -cne
            'b8c0c49520e841a97309e7c742570c0a8769c4f6' -or
        [string]$profile.SourceTree -cne
            '1194169c7723b1bbf314105c5255a7ea2e2e7c97' -or
        [int64]$profile.XeniaBytes -le 0 -or
        [string]$profile.XeniaSha256 -notmatch '^[0-9A-F]{64}$') {
        throw 'Runtime-core profile lost its reviewed source or executable pins.'
    }
    $declaredPatches = @($profile.RequiredPatches)
    if ($declaredPatches.Count -ne $expectedPatches.Count) {
        throw 'Runtime-core profile must declare exactly three canonical patches.'
    }
    for ($index = 0; $index -lt $expectedPatches.Count; $index++) {
        $declared = $declaredPatches[$index]
        $expected = $expectedPatches[$index]
        if ($null -eq $declared -or
            -not ($declared -is [Collections.IDictionary])) {
            throw "Runtime-core patch declaration $index is malformed."
        }
        Assert-ExactKeys -Table $declared -Label "Runtime-core patch $index" `
            -Expected @('FileName', 'Sha256', 'PatchName', 'Type',
                'Address', 'Value')
        foreach ($key in 'FileName', 'Sha256', 'PatchName', 'Type',
                'Address', 'Value') {
            if ([string]$declared[$key] -cne [string]$expected[$key]) {
                throw "Runtime-core patch declaration mismatch at $index field $key."
            }
        }
    }

    $candidateStream = Open-LockedSourceFile -Path $CandidateXeniaPath `
        -Label 'Runtime-core candidate executable' -HandleList $sourceHandles
    $candidateLength = [int64]$candidateStream.Length
    if ($candidateLength -ne [int64]$profile.XeniaBytes) {
        throw 'Runtime-core candidate executable size does not match the profile pin.'
    }
    $candidateSha256 = Get-StreamSha256 -Stream $candidateStream
    if ($candidateSha256 -cne [string]$profile.XeniaSha256) {
        throw 'Runtime-core candidate executable hash does not match the profile pin.'
    }

    $patchDirectory = Join-Path $ProfileRoot 'patches'
    if (-not (Test-Path -LiteralPath $patchDirectory -PathType Container)) {
        throw "Runtime-core patch directory is missing: $patchDirectory"
    }
    Assert-NoReparseInExistingPath -Path $patchDirectory `
        -Label 'Runtime-core patch directory'
    $patchDirectoryEntries = @(Get-ChildItem -LiteralPath $patchDirectory -Force)
    if ($patchDirectoryEntries.Count -ne 3 -or
        @($patchDirectoryEntries | Where-Object { $_.PSIsContainer }).Count -ne 0) {
        throw 'Runtime-core patch directory must contain exactly three plain files.'
    }
    $actualPatchNames = @($patchDirectoryEntries.Name | Sort-Object)
    $expectedPatchNames = @($expectedPatches.FileName | Sort-Object)
    if (@(Compare-Object -ReferenceObject $expectedPatchNames `
            -DifferenceObject $actualPatchNames -SyncWindow 0).Count -ne 0) {
        throw 'Runtime-core patch directory closure differs from the profile.'
    }
    foreach ($expected in $expectedPatches) {
        $patchPath = Join-Path $patchDirectory ([string]$expected.FileName)
        $patchStream = Open-LockedSourceFile -Path $patchPath `
            -Label "Runtime-core patch $($expected.FileName)" `
            -HandleList $sourceHandles
        $patchHash = Get-StreamSha256 -Stream $patchStream
        if ($patchHash -cne [string]$expected.Sha256) {
            throw "Runtime-core patch hash mismatch: $($expected.FileName)"
        }
        Assert-CanonicalPatchText -Text (Read-LockedStreamText `
            -Stream $patchStream) -Expected $expected
        $patchSources.Add([pscustomobject][ordered]@{
            FileName = [string]$expected.FileName
            Length = [int64]$patchStream.Length
            Sha256 = $patchHash
            Stream = $patchStream
        })
    }

    $processInventory = $null
    if ($SyntheticFixture) {
        $inventoryStream = Open-LockedSourceFile `
            -Path $SyntheticProcessInventoryPath `
            -Label 'Synthetic process inventory' -HandleList $sourceHandles
        $null = Get-StreamSha256 -Stream $inventoryStream
        $processInventory = Import-PowerShellDataFile `
            -LiteralPath $SyntheticProcessInventoryPath
        if ($null -eq $processInventory -or
            -not ($processInventory -is [Collections.IDictionary])) {
            throw 'Synthetic process inventory must be a data-file hashtable.'
        }
        Assert-ExactKeys -Table $processInventory `
            -Label 'Synthetic process inventory' `
            -Expected @('SchemaVersion', 'BeforeFirstWrite',
                'BeforePublishPreparation', 'FinalBeforePublish')
        if ([int]$processInventory.SchemaVersion -ne 1) {
            throw 'Synthetic process inventory requires SchemaVersion 1.'
        }
        foreach ($phase in 'BeforeFirstWrite', 'BeforePublishPreparation',
                'FinalBeforePublish') {
            foreach ($imageName in @($processInventory[$phase])) {
                if (-not ($imageName -is [string]) -or
                    [string]$imageName -notmatch
                        '^[A-Za-z0-9][A-Za-z0-9._-]{0,127}\.exe$') {
                    throw "Synthetic process inventory $phase contains an invalid image name."
                }
            }
        }
    }

    function Assert-ZeroLiveXenia {
        param([Parameter(Mandatory = $true)][ValidateSet(
            'BeforeFirstWrite', 'BeforePublishPreparation',
            'FinalBeforePublish')][string]$Phase)
        if ($SyntheticFixture) {
            $imageNames = @($processInventory[$Phase] | ForEach-Object {
                [string]$_
            })
        } else {
            try {
                $imageNames = @(Get-CimInstance Win32_Process `
                    -ErrorAction Stop | ForEach-Object {
                    [string]$_.Name
                })
            } catch {
                throw "Could not obtain a complete process inventory for $Phase."
            }
        }
        $liveXenia = @($imageNames | Where-Object {
            $_ -like 'xenia*.exe'
        })
        if ($liveXenia.Count -ne 0) {
            throw ("ZERO_LIVE_XENIA_PROCESSES gate failed at {0}: {1}" -f
                $Phase, ($liveXenia -join ','))
        }
        $script:processCheckCount++
    }

    Assert-ZeroLiveXenia -Phase BeforeFirstWrite

    if ($SyntheticFixture) {
        Initialize-AotRuntimeCoreNativeType `
            -CompilerTempRoot $trustedSyntheticRoot
    } else {
        Initialize-AotRuntimeCoreNativeType
    }

    New-AtomicStagingDirectory -Path $stagingRoot
    $stagingCreated = $true
    Assert-AtomicStagingOwnership -Path $stagingRoot `
        -ExpectedParent $InstallRoot -ExpectedName $stagingName
    if ($SyntheticChildClaimAction -ceq 'PrecreateDaddyDirectory') {
        $foreignDaddyRoot = Join-Path $stagingRoot 'daddy'
        [void][IO.Directory]::CreateDirectory($foreignDaddyRoot)
        Write-NewFileBytes -Path (Join-Path $foreignDaddyRoot `
            'foreign-child-sentinel.txt') `
            -Bytes ([Text.Encoding]::ASCII.GetBytes('foreign-child'))
    } elseif ($SyntheticChildClaimAction -ceq 'PrecreateDaddyJunction') {
        $null = New-Item -ItemType Junction `
            -Path (Join-Path $stagingRoot 'daddy') `
            -Target $SyntheticChildHijackTarget
    }
    $sideRoots = @{}
    foreach ($side in 'daddy', 'cj') {
        $sideRoot = Join-Path $stagingRoot $side
        New-AtomicValidatedChildDirectory -Path $sideRoot `
            -ExpectedParent $stagingRoot -ExpectedName $side `
            -Label "$side rig directory"
        $atomicChildClaimCount++
        $sideRoots[$side] = $sideRoot
    }
    foreach ($side in 'daddy', 'cj') {
        $sideRoot = [string]$sideRoots[$side]
        New-AtomicValidatedChildDirectory `
            -Path (Join-Path $sideRoot 'patches') `
            -ExpectedParent $sideRoot -ExpectedName 'patches' `
            -Label "$side patch directory"
        $atomicChildClaimCount++
    }
    if ($atomicChildClaimCount -ne 4) {
        throw 'All four descendant directories must be atomically claimed before file creation.'
    }
    $ownerMarkerStream = Open-NewOwnerMarker -Path $ownerMarkerPath `
        -Token $ownerToken
    $ownerTokenArmed = $true
    foreach ($side in 'daddy', 'cj') {
        $sideRoot = [string]$sideRoots[$side]
        Copy-LockedStreamToNewFile -Source $candidateStream `
            -Destination (Join-Path $sideRoot $XeniaFileName)
        Write-NewFileBytes -Path (Join-Path $sideRoot 'portable.txt') `
            -Bytes ([byte[]]@())
        Write-NewFileBytes -Path (Join-Path $sideRoot 'inject.txt') `
            -Bytes ([Text.Encoding]::ASCII.GetBytes('NONE'))
        foreach ($patchSource in $patchSources) {
            Copy-LockedStreamToNewFile -Source $patchSource.Stream `
                -Destination (Join-Path (Join-Path $sideRoot 'patches') `
                    $patchSource.FileName)
        }
    }

    $stagedEntries = @(Get-ExactTreeReceipt -Root $stagingRoot `
        -SeededXeniaFileName $XeniaFileName -XeniaLength $candidateLength `
        -XeniaHash $candidateSha256 -Patches @($patchSources) `
        -OwnerMarkerName '.aot-runtime-core-owner' `
        -OwnerMarkerSha256 $ownerTokenHash `
        -OwnerMarkerStream $ownerMarkerStream)
    if ($candidateStream.Length -ne $candidateLength -or
        (Get-StreamSha256 -Stream $candidateStream) -cne $candidateSha256) {
        throw 'Locked candidate source changed during staging.'
    }
    foreach ($patchSource in $patchSources) {
        if ($patchSource.Stream.Length -ne $patchSource.Length -or
            (Get-StreamSha256 -Stream $patchSource.Stream) -cne
                $patchSource.Sha256) {
            throw "Locked patch source changed during staging: $($patchSource.FileName)"
        }
    }

    Assert-ZeroLiveXenia -Phase BeforePublishPreparation
    Assert-NoReparseInExistingPath -Path $InstallRoot -Label 'InstallRoot'
    Assert-NoReparseInExistingPath -Path $stagingRoot `
        -Label 'Run-owned staging directory before publish'
    Assert-PathAbsent -Path $rigsRoot -Label 'The entire InstallRoot\rigs path'
    if ($SyntheticBeforePublishAction -ceq 'CreateRigsDestination') {
        [void][IO.Directory]::CreateDirectory($rigsRoot)
    } elseif ($SyntheticBeforePublishAction -ceq
            'InjectUnknownStagingFileThenFail') {
        Write-NewFileBytes -Path (Join-Path $stagingRoot `
            'foreign-injected.txt') `
            -Bytes ([Text.Encoding]::ASCII.GetBytes('foreign'))
        throw 'Synthetic unknown staging-file injection requested a cleanup refusal.'
    }
    Assert-OwnerMarkerMatchesToken -MarkerPath $ownerMarkerPath `
        -Token $ownerToken -MarkerStream $ownerMarkerStream
    $ownerMarkerStream.Dispose()
    $ownerMarkerStream = $null
    Remove-Item -LiteralPath $ownerMarkerPath -Force
    $ownerTokenArmed = $false
    $stagedEntries = @(Get-ExactTreeReceipt -Root $stagingRoot `
        -SeededXeniaFileName $XeniaFileName -XeniaLength $candidateLength `
        -XeniaHash $candidateSha256 -Patches @($patchSources))
    Clear-VerifiedStagingHiddenAttribute -Path $stagingRoot

    Assert-ZeroLiveXenia -Phase FinalBeforePublish
    try {
        [IO.Directory]::Move($stagingRoot, $rigsRoot)
    } catch {
        throw "Atomic rigs publish failed without overwrite: $($_.Exception.Message)"
    }
    $published = $true
    $stagingCreated = $false

    $publishedRootInfo = Get-Item -LiteralPath $rigsRoot -Force `
        -ErrorAction Stop
    if (-not $publishedRootInfo.PSIsContainer -or
        ($publishedRootInfo.Attributes -band
            [IO.FileAttributes]::ReparsePoint) -ne 0 -or
        ($publishedRootInfo.Attributes -band
            [IO.FileAttributes]::Hidden) -ne 0) {
        throw 'Published rigs root is not a normal visible non-reparse directory.'
    }

    $publishedEntries = @(Get-ExactTreeReceipt -Root $rigsRoot `
        -SeededXeniaFileName $XeniaFileName -XeniaLength $candidateLength `
        -XeniaHash $candidateSha256 -Patches @($patchSources))
    if ($publishedEntries.Count -ne $stagedEntries.Count) {
        throw 'Published tree receipt count changed after the atomic directory move.'
    }
    for ($index = 0; $index -lt $publishedEntries.Count; $index++) {
        if ($publishedEntries[$index].RelativePath -cne
                $stagedEntries[$index].RelativePath -or
            $publishedEntries[$index].Length -ne $stagedEntries[$index].Length -or
            $publishedEntries[$index].SHA256 -cne
                $stagedEntries[$index].SHA256) {
            throw 'Published tree differs from its pre-publish verified staging receipt.'
        }
    }

    $receipt = [pscustomobject][ordered]@{
        SchemaVersion = 1
        Operation = 'INERT_FIRST_TIME_RUNTIME_CORE_RIG_SEED'
        Published = $true
        AtomicPublish = 'System.IO.Directory.Move same-volume direct-child rename'
        InstallRoot = $InstallRoot
        RigsRoot = $rigsRoot
        DaddyRoot = Join-Path $rigsRoot 'daddy'
        CjRoot = Join-Path $rigsRoot 'cj'
        XeniaFileName = $XeniaFileName
        XeniaBytes = $candidateLength
        XeniaSha256 = $candidateSha256
        ProfileSha256 = $profileSha256
        SourceCommit = [string]$profile.SourceCommit
        SourceTree = [string]$profile.SourceTree
        ProductionProfileVerified = -not [bool]$SyntheticFixture
        SourceLocksHeldThroughPublish = $true
        AtomicDescendantDirectoryClaims = $atomicChildClaimCount
        ProcessInventoryChecks = $processCheckCount
        FinalProcessInventoryPhase = 'FinalBeforePublish'
        OwnerTokenDisarmedBeforePublish = $true
        PublishedRigsRootHidden = $false
        PublishedRigsRootReparsePoint = $false
        FileCount = $publishedEntries.Count
        PatchCountPerSide = $expectedPatches.Count
        PlayerKitReady = $false
        RuntimeTested = $false
        LaunchCapable = $false
        SeededFiles = @($publishedEntries)
    }
} catch {
    $originalFailure = $_
    if ($stagingCreated -and -not $published) {
        if ($ownerTokenArmed -and $null -ne $ownerMarkerStream) {
            try {
                Remove-ValidatedRunOwnedStagingTree -Path $stagingRoot `
                    -ExpectedPath $stagingRoot -ExpectedName $stagingName `
                    -ExpectedParent $InstallRoot `
                    -OwnerMarkerPath $ownerMarkerPath -OwnerToken $ownerToken `
                    -OwnerMarkerStream $ownerMarkerStream `
                    -SeededXeniaFileName $XeniaFileName `
                    -PatchFileNames @($expectedPatches | ForEach-Object {
                        [string]$_.FileName
                    })
                $ownerMarkerStream = $null
                $ownerTokenArmed = $false
                $stagingCreated = $false
            } catch {
                throw ("Inert seeding failed; run-owner cleanup was refused and " +
                    "the staging tree was intentionally retained at " +
                    "$stagingRoot. Cleanup failure: $($_.Exception.Message) " +
                    "Original failure: $($originalFailure.Exception.Message)")
            }
        } else {
            throw ("Inert seeding stopped after its cryptographic owner token " +
                "was unavailable or disarmed. The staging tree was " +
                "intentionally retained at $stagingRoot rather than risk " +
                "deleting foreign state. Original failure: " +
                $originalFailure.Exception.Message)
        }
    }
    throw $originalFailure
} finally {
    if ($null -ne $ownerMarkerStream) {
        $ownerMarkerStream.Dispose()
    }
    for ($index = $sourceHandles.Count - 1; $index -ge 0; $index--) {
        $sourceHandles[$index].Dispose()
    }
}

Write-Output $receipt
