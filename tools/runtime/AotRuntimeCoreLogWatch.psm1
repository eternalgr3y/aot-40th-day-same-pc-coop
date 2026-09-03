Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$evidenceModulePath = Join-Path $PSScriptRoot 'AotRuntimeCoreEvidence.psm1'
if (-not (Test-Path -LiteralPath $evidenceModulePath -PathType Leaf)) {
    throw "Runtime-core evidence module is missing: $evidenceModulePath"
}
Import-Module -Force $evidenceModulePath

if ($null -eq ('AotRuntimeCoreLogWatchNative' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;

public static class AotRuntimeCoreLogWatchNative {
  [StructLayout(LayoutKind.Sequential)]
  private struct FILETIME {
    public uint Low;
    public uint High;
  }

  [StructLayout(LayoutKind.Sequential)]
  private struct BY_HANDLE_FILE_INFORMATION {
    public uint FileAttributes;
    public FILETIME CreationTime;
    public FILETIME LastAccessTime;
    public FILETIME LastWriteTime;
    public uint VolumeSerialNumber;
    public uint FileSizeHigh;
    public uint FileSizeLow;
    public uint NumberOfLinks;
    public uint FileIndexHigh;
    public uint FileIndexLow;
  }

  [DllImport("kernel32.dll", SetLastError = true)]
  private static extern bool GetFileInformationByHandle(
      SafeFileHandle file, out BY_HANDLE_FILE_INFORMATION information);

  [DllImport("kernel32.dll", CharSet = CharSet.Unicode,
      SetLastError = true)]
  private static extern uint GetFinalPathNameByHandleW(
      SafeFileHandle file, StringBuilder path, uint pathLength, uint flags);

  public static string GetFileId(SafeFileHandle file) {
    BY_HANDLE_FILE_INFORMATION information;
    if (!GetFileInformationByHandle(file, out information)) {
      throw new Win32Exception(Marshal.GetLastWin32Error());
    }
    ulong index = ((ulong)information.FileIndexHigh << 32) |
                  information.FileIndexLow;
    return information.VolumeSerialNumber.ToString("X8") + ":" +
           index.ToString("X16");
  }

  public static string GetFinalPath(SafeFileHandle file) {
    uint capacity = 1024;
    while (capacity <= 32768) {
      StringBuilder path = new StringBuilder((int)capacity);
      uint length = GetFinalPathNameByHandleW(file, path, capacity, 0);
      if (length == 0) {
        throw new Win32Exception(Marshal.GetLastWin32Error());
      }
      if (length < capacity) {
        return path.ToString();
      }
      capacity = length + 1;
    }
    throw new InvalidOperationException("Final file path exceeded 32768 characters.");
  }
}
'@
}

$script:MarkerPrefix = '[AOT-RUNTIME-SA2][ACCEPT]'
$script:PendingEvidenceCodes = @(
    'CJ_STAGE2_MISSING',
    'DADDY_STAGE2_MISSING',
    'NO_COMPLETE_SAME_SIDE_CHAIN')
$script:StrictUtf8 = [Text.UTF8Encoding]::new($false, $true)
$script:ReadBufferBytes = 65536
$script:MaximumLineBytes = 1MB
$script:MaximumCandidateLines = 16
$script:BaselineTimeoutMilliseconds = 500
$script:BaselinePollMilliseconds = 25
$script:FinalSnapshotAttempts = 8

function Throw-AotLogWatchFailure {
    param(
        [Parameter(Mandatory = $true)][string]$Code,
        [Parameter(Mandatory = $true)][string]$Message,
        [AllowNull()][string]$Side = $null
    )

    $exception = [InvalidOperationException]::new($Message)
    $exception.Data['AotWatchCode'] = $Code
    if ($null -ne $Side) { $exception.Data['AotWatchSide'] = $Side }
    throw $exception
}

function Get-AotWatchFailure {
    param([Parameter(Mandatory = $true)][Exception]$Exception)

    $current = $Exception
    while ($null -ne $current) {
        if ($current.Data.Contains('AotWatchCode')) {
            return [pscustomobject]@{
                Code = [string]$current.Data['AotWatchCode']
                Side = if ($current.Data.Contains('AotWatchSide')) {
                    [string]$current.Data['AotWatchSide']
                } else { $null }
                Message = $current.Message
            }
        }
        $current = $current.InnerException
    }
    return [pscustomobject]@{
        Code = 'INTERNAL_ERROR'
        Side = $null
        Message = $Exception.Message
    }
}

function Get-AotWatchElapsedMilliseconds {
    param(
        [Parameter(Mandatory = $true)][bool]$SyntheticFixture,
        [AllowNull()][Collections.IDictionary]$TestHooks = $null,
        [AllowNull()][Diagnostics.Stopwatch]$Stopwatch = $null
    )

    if ($SyntheticFixture) {
        return [int64](& $TestHooks['GetElapsedMilliseconds'])
    }
    return [int64]$Stopwatch.ElapsedMilliseconds
}

function Invoke-AotWatchSleep {
    param(
        [Parameter(Mandatory = $true)][int]$Milliseconds,
        [Parameter(Mandatory = $true)][bool]$SyntheticFixture,
        [AllowNull()][Collections.IDictionary]$TestHooks = $null
    )

    if ($SyntheticFixture) {
        $null = & $TestHooks['Sleep'] $Milliseconds
    } else {
        Start-Sleep -Milliseconds $Milliseconds
    }
}

function Get-AotObjectProperty {
    param(
        [Parameter(Mandatory = $true)][object]$InputObject,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Label
    )

    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value) {
        Throw-AotLogWatchFailure -Code 'WATCH_INPUT_INVALID' `
            -Message "$Label is missing $Name."
    }
    return $property.Value
}

function ConvertTo-AotFullPath {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Label
    )

    if ([string]::IsNullOrWhiteSpace($Path) -or
        -not [IO.Path]::IsPathRooted($Path)) {
        Throw-AotLogWatchFailure -Code 'WATCH_INPUT_INVALID' `
            -Message "$Label must be an absolute path."
    }
    try { return [IO.Path]::GetFullPath($Path) } catch {
        Throw-AotLogWatchFailure -Code 'WATCH_INPUT_INVALID' `
            -Message "$Label is not a valid Windows path."
    }
}

function ConvertFrom-AotHandlePath {
    param([Parameter(Mandatory = $true)][string]$Path)

    $normalized = $Path
    if ($normalized.StartsWith('\\?\UNC\',
            [StringComparison]::OrdinalIgnoreCase)) {
        $normalized = '\\' + $normalized.Substring(8)
    } elseif ($normalized.StartsWith('\\?\',
            [StringComparison]::OrdinalIgnoreCase)) {
        $normalized = $normalized.Substring(4)
    }
    return [IO.Path]::GetFullPath($normalized)
}

function Test-AotSamePath {
    param(
        [Parameter(Mandatory = $true)][string]$Left,
        [Parameter(Mandatory = $true)][string]$Right
    )
    return [string]::Equals(
        [IO.Path]::GetFullPath($Left), [IO.Path]::GetFullPath($Right),
        [StringComparison]::OrdinalIgnoreCase)
}

function Test-AotPathUnderRoot {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Root
    )

    $rootFull = [IO.Path]::GetFullPath($Root).TrimEnd('\', '/') + '\'
    $pathFull = [IO.Path]::GetFullPath($Path)
    return $pathFull.StartsWith($rootFull,
        [StringComparison]::OrdinalIgnoreCase)
}

function Assert-AotPathHasNoReparsePoints {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$Label,
        [switch]$AllowMissingLeaf
    )

    $pathFull = [IO.Path]::GetFullPath($Path)
    $rootFull = [IO.Path]::GetFullPath($Root).TrimEnd('\', '/')
    if (-not (Test-AotSamePath $pathFull $rootFull) -and
        -not (Test-AotPathUnderRoot $pathFull $rootFull)) {
        Throw-AotLogWatchFailure -Code 'WATCH_INPUT_INVALID' `
            -Message "$Label escaped the trusted synthetic root."
    }

    $current = $pathFull
    $isLeaf = $true
    while ($true) {
        if (-not [IO.File]::Exists($current) -and
            -not [IO.Directory]::Exists($current)) {
            if (-not $isLeaf -or -not $AllowMissingLeaf) {
                Throw-AotLogWatchFailure -Code 'WATCH_INPUT_INVALID' `
                    -Message "$Label contains a missing path component."
            }
        } else {
            try {
                $attributes = [IO.File]::GetAttributes($current)
            } catch {
                Throw-AotLogWatchFailure -Code 'WATCH_INPUT_INVALID' `
                    -Message "$Label attributes could not be verified."
            }
            if (($attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                Throw-AotLogWatchFailure -Code 'WATCH_INPUT_INVALID' `
                    -Message "$Label contains a reparse point."
            }
        }
        if (Test-AotSamePath $current $rootFull) { break }
        $parent = [IO.Directory]::GetParent($current)
        if ($null -eq $parent) {
            Throw-AotLogWatchFailure -Code 'WATCH_INPUT_INVALID' `
                -Message "$Label could not be traced to the trusted synthetic root."
        }
        $current = $parent.FullName
        $isLeaf = $false
    }
}

function Get-AotTrustedSyntheticAnchor {
    $localAppData = [Environment]::GetFolderPath(
        [Environment+SpecialFolder]::LocalApplicationData)
    if ([string]::IsNullOrWhiteSpace($localAppData)) {
        Throw-AotLogWatchFailure -Code 'WATCH_INPUT_INVALID' `
            -Message 'The Windows LocalApplicationData known folder is unavailable.'
    }

    try {
        $localFull = [IO.Path]::GetFullPath($localAppData).TrimEnd('\', '/')
        $volumeRoot = [IO.Path]::GetPathRoot($localFull)
        $anchor = [IO.Path]::GetFullPath((Join-Path $localFull 'Temp'))
        $anchor = $anchor.TrimEnd('\', '/')
    } catch {
        Throw-AotLogWatchFailure -Code 'WATCH_INPUT_INVALID' `
            -Message 'The trusted synthetic anchor path is invalid.'
    }
    if ([string]::IsNullOrWhiteSpace($volumeRoot) -or
        (Test-AotSamePath $localFull $volumeRoot) -or
        -not (Test-AotPathUnderRoot $anchor $localFull)) {
        Throw-AotLogWatchFailure -Code 'WATCH_INPUT_INVALID' `
            -Message 'The trusted synthetic anchor resolved to an unsafe root.'
    }
    foreach ($directory in $localFull, $anchor) {
        if (-not [IO.Directory]::Exists($directory)) {
            Throw-AotLogWatchFailure -Code 'WATCH_INPUT_INVALID' `
                -Message 'The trusted synthetic anchor directory is unavailable.'
        }
        try {
            $attributes = [IO.File]::GetAttributes($directory)
        } catch {
            Throw-AotLogWatchFailure -Code 'WATCH_INPUT_INVALID' `
                -Message 'The trusted synthetic anchor attributes could not be verified.'
        }
        if (($attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            Throw-AotLogWatchFailure -Code 'WATCH_INPUT_INVALID' `
                -Message 'The trusted synthetic anchor contains a reparse point.'
        }
    }
    return $anchor
}

function ConvertTo-AotUtcDateTime {
    param(
        [Parameter(Mandatory = $true)][object]$Value,
        [Parameter(Mandatory = $true)][string]$Label
    )

    try {
        if ($Value -is [DateTime]) {
            return ([DateTime]$Value).ToUniversalTime()
        }
        return [DateTime]::Parse(
            [string]$Value, [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime()
    } catch {
        Throw-AotLogWatchFailure -Code 'WATCH_INPUT_INVALID' `
            -Message "$Label must be a round-trip UTC timestamp."
    }
}

function Get-AotFileIdentity {
    param(
        [Parameter(Mandatory = $true)][IO.FileStream]$Stream,
        [Parameter(Mandatory = $true)][string]$FailureCode,
        [Parameter(Mandatory = $true)][string]$Label,
        [AllowNull()][string]$Side = $null
    )

    try {
        return [string][AotRuntimeCoreLogWatchNative]::GetFileId(
            $Stream.SafeFileHandle)
    } catch {
        Throw-AotLogWatchFailure -Code $FailureCode `
            -Message "$Label file identity query failed: $($_.Exception.Message)" `
            -Side $Side
    }
}

function Get-AotFinalFilePath {
    param(
        [Parameter(Mandatory = $true)][IO.FileStream]$Stream,
        [Parameter(Mandatory = $true)][string]$FailureCode,
        [Parameter(Mandatory = $true)][string]$Label,
        [AllowNull()][string]$Side = $null
    )

    try {
        $nativePath = [AotRuntimeCoreLogWatchNative]::GetFinalPath(
            $Stream.SafeFileHandle)
        return ConvertFrom-AotHandlePath -Path $nativePath
    } catch {
        Throw-AotLogWatchFailure -Code $FailureCode `
            -Message "$Label final-path query failed: $($_.Exception.Message)" `
            -Side $Side
    }
}

function Get-AotStreamSha256 {
    param([Parameter(Mandatory = $true)][IO.FileStream]$Stream)

    $position = $Stream.Position
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $Stream.Position = 0
        return ([BitConverter]::ToString($sha.ComputeHash($Stream))) -replace '-', ''
    } finally {
        $Stream.Position = $position
        $sha.Dispose()
    }
}

function Open-AotReadStream {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][IO.FileShare]$Share,
        [Parameter(Mandatory = $true)][string]$FailureCode,
        [Parameter(Mandatory = $true)][string]$Label,
        [AllowNull()][string]$Side = $null,
        [AllowNull()][string]$NotFoundCode = $null
    )

    try {
        return [IO.FileStream]::new(
            $Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, $Share,
            $script:ReadBufferBytes, $false)
    } catch [IO.FileNotFoundException] {
        $code = if ([string]::IsNullOrWhiteSpace($NotFoundCode)) {
            $FailureCode
        } else { $NotFoundCode }
        Throw-AotLogWatchFailure -Code $code `
            -Message "$Label was not found." -Side $Side
    } catch [IO.DirectoryNotFoundException] {
        $code = if ([string]::IsNullOrWhiteSpace($NotFoundCode)) {
            $FailureCode
        } else { $NotFoundCode }
        Throw-AotLogWatchFailure -Code $code `
            -Message "$Label was not found." -Side $Side
    } catch {
        Throw-AotLogWatchFailure -Code $FailureCode `
            -Message "$Label could not be opened for retained reading: $($_.Exception.Message)" `
            -Side $Side
    }
}

function Assert-AotReceiptShape {
    param(
        [Parameter(Mandatory = $true)][object]$Receipt,
        [Parameter(Mandatory = $true)][ValidateSet('Daddy', 'CJ')]
        [string]$ExpectedSide,
        [switch]$SyntheticFixture,
        [AllowNull()][string]$SyntheticRoot = $null
    )

    $expectedKeys = @(
        'Side', 'ProcessId', 'StartTimeUtc', 'FilePath', 'XeniaBytes',
        'XeniaSha256', 'WorkingDirectory', 'ArgumentListSha256', 'RunId')
    $actualKeys = @($Receipt.PSObject.Properties | ForEach-Object Name)
    $missing = @($expectedKeys | Where-Object { $_ -notin $actualKeys })
    $extra = @($actualKeys | Where-Object { $_ -notin $expectedKeys })
    if ($missing.Count -ne 0 -or $extra.Count -ne 0) {
        Throw-AotLogWatchFailure -Code 'WATCH_INPUT_INVALID' `
            -Message ("$ExpectedSide receipt schema mismatch: missing=[{0}] extra=[{1}]" -f
                ($missing -join ','), ($extra -join ','))
    }

    $side = [string](Get-AotObjectProperty $Receipt Side "$ExpectedSide receipt")
    if ($side -cne $ExpectedSide) {
        Throw-AotLogWatchFailure -Code 'WATCH_INPUT_INVALID' `
            -Message "$ExpectedSide receipt has Side='$side'."
    }
    [int64]$processId = 0
    if (-not [int64]::TryParse([string]$Receipt.ProcessId, [ref]$processId) -or
        $processId -le 0 -or $processId -gt [int]::MaxValue) {
        Throw-AotLogWatchFailure -Code 'WATCH_INPUT_INVALID' `
            -Message "$ExpectedSide receipt ProcessId is invalid."
    }
    $startTimeUtc = ConvertTo-AotUtcDateTime $Receipt.StartTimeUtc `
        "$ExpectedSide receipt StartTimeUtc"
    $filePath = ConvertTo-AotFullPath ([string]$Receipt.FilePath) `
        "$ExpectedSide receipt FilePath"
    $workingDirectory = ConvertTo-AotFullPath `
        ([string]$Receipt.WorkingDirectory) `
        "$ExpectedSide receipt WorkingDirectory"
    if (-not (Test-AotSamePath (Split-Path -Parent $filePath) $workingDirectory)) {
        Throw-AotLogWatchFailure -Code 'WATCH_INPUT_INVALID' `
            -Message "$ExpectedSide executable must be a direct child of WorkingDirectory."
    }
    [int64]$xeniaBytes = 0
    if (-not [int64]::TryParse([string]$Receipt.XeniaBytes, [ref]$xeniaBytes) -or
        $xeniaBytes -le 0) {
        Throw-AotLogWatchFailure -Code 'WATCH_INPUT_INVALID' `
            -Message "$ExpectedSide receipt XeniaBytes is invalid."
    }
    $xeniaSha256 = ([string]$Receipt.XeniaSha256).ToUpperInvariant()
    $argumentHash = ([string]$Receipt.ArgumentListSha256).ToUpperInvariant()
    if ($xeniaSha256 -cnotmatch '^[0-9A-F]{64}$' -or
        $argumentHash -cnotmatch '^[0-9A-F]{64}$' -or
        [string]::IsNullOrWhiteSpace([string]$Receipt.RunId)) {
        Throw-AotLogWatchFailure -Code 'WATCH_INPUT_INVALID' `
            -Message "$ExpectedSide receipt hashes or RunId are invalid."
    }

    $logPath = [IO.Path]::GetFullPath((Join-Path $workingDirectory 'xenia.log'))
    if ($SyntheticFixture) {
        foreach ($path in $workingDirectory, $filePath, $logPath) {
            if (-not (Test-AotPathUnderRoot $path $SyntheticRoot)) {
                Throw-AotLogWatchFailure -Code 'WATCH_INPUT_INVALID' `
                    -Message "$ExpectedSide synthetic path escaped TestHooks.TempRoot."
            }
        }
        Assert-AotPathHasNoReparsePoints -Path $workingDirectory `
            -Root $SyntheticRoot -Label "$ExpectedSide synthetic working directory"
        Assert-AotPathHasNoReparsePoints -Path $filePath `
            -Root $SyntheticRoot -Label "$ExpectedSide synthetic executable" `
            -AllowMissingLeaf
        Assert-AotPathHasNoReparsePoints -Path $logPath `
            -Root $SyntheticRoot -Label "$ExpectedSide synthetic log" `
            -AllowMissingLeaf
    }

    return [pscustomobject][ordered]@{
        Side = $ExpectedSide
        ProcessId = [int]$processId
        StartTimeUtc = $startTimeUtc
        FilePath = $filePath
        XeniaBytes = $xeniaBytes
        XeniaSha256 = $xeniaSha256
        WorkingDirectory = $workingDirectory
        LogPath = $logPath
        ArgumentListSha256 = $argumentHash
        RunId = [string]$Receipt.RunId
    }
}

function Assert-AotReceiptPair {
    param(
        [Parameter(Mandatory = $true)][object]$Daddy,
        [Parameter(Mandatory = $true)][object]$CJ
    )

    if ($Daddy.RunId -cne $CJ.RunId) {
        Throw-AotLogWatchFailure -Code 'WATCH_INPUT_INVALID' `
            -Message 'Daddy and CJ launch receipts use different RunId values.'
    }
    if ($Daddy.XeniaBytes -ne $CJ.XeniaBytes -or
        $Daddy.XeniaSha256 -cne $CJ.XeniaSha256) {
        Throw-AotLogWatchFailure -Code 'WATCH_INPUT_INVALID' `
            -Message 'Daddy and CJ launch receipts identify different Xenia builds.'
    }
    if ($Daddy.ProcessId -eq $CJ.ProcessId) {
        Throw-AotLogWatchFailure -Code 'WATCH_INPUT_INVALID' `
            -Message 'Daddy and CJ launch receipts reuse one ProcessId.'
    }
    if (Test-AotSamePath $Daddy.WorkingDirectory $CJ.WorkingDirectory) {
        Throw-AotLogWatchFailure -Code 'WATCH_INPUT_INVALID' `
            -Message 'Daddy and CJ launch receipts reuse one WorkingDirectory.'
    }
    if (Test-AotSamePath $Daddy.FilePath $CJ.FilePath) {
        Throw-AotLogWatchFailure -Code 'WATCH_INPUT_INVALID' `
            -Message 'Daddy and CJ launch receipts reuse one executable path.'
    }
    if (Test-AotSamePath $Daddy.LogPath $CJ.LogPath) {
        Throw-AotLogWatchFailure -Code 'WATCH_INPUT_INVALID' `
            -Message 'Daddy and CJ launch receipts reuse one xenia.log path.'
    }
    if ($Daddy.ArgumentListSha256 -ceq $CJ.ArgumentListSha256) {
        Throw-AotLogWatchFailure -Code 'WATCH_INPUT_INVALID' `
            -Message 'Daddy and CJ launch receipts reuse one argument-list identity.'
    }
}

function Get-AotProductionProcessSnapshot {
    param(
        [Parameter(Mandatory = $true)][Diagnostics.Process]$Process,
        [Parameter(Mandatory = $true)][string]$Side
    )

    try {
        $Process.Refresh()
        if ($Process.HasExited) {
            return [pscustomobject]@{
                Exists = $true; HasExited = $true; ProcessId = $Process.Id
                StartTimeUtc = $null; ExecutablePath = $null
            }
        }
        $path = $null
        try { $path = [string]$Process.Path } catch { $path = $null }
        if ([string]::IsNullOrWhiteSpace($path)) {
            $path = [string]$Process.MainModule.FileName
        }
        return [pscustomobject]@{
            Exists = $true
            HasExited = $false
            ProcessId = $Process.Id
            StartTimeUtc = $Process.StartTime.ToUniversalTime()
            ExecutablePath = $path
        }
    } catch {
        Throw-AotLogWatchFailure -Code 'PROCESS_QUERY_FAILED' `
            -Message "$Side process query failed: $($_.Exception.Message)" `
            -Side $Side
    }
}

function Get-AotProcessSnapshot {
    param(
        [Parameter(Mandatory = $true)][object]$Binding,
        [Parameter(Mandatory = $true)][bool]$SyntheticFixture,
        [AllowNull()][Collections.IDictionary]$TestHooks = $null,
        [int]$PollIndex = -1
    )

    if ($SyntheticFixture) {
        try {
            $snapshot = & $TestHooks['GetProcessSnapshot'] `
                $Binding.Side $Binding.ProcessId $PollIndex
        } catch {
            Throw-AotLogWatchFailure -Code 'PROCESS_QUERY_FAILED' `
                -Message "$($Binding.Side) synthetic process query failed: $($_.Exception.Message)" `
                -Side $Binding.Side
        }
        if ($null -eq $snapshot) {
            Throw-AotLogWatchFailure -Code 'PROCESS_QUERY_FAILED' `
                -Message "$($Binding.Side) synthetic process query returned null." `
                -Side $Binding.Side
        }
        return $snapshot
    }
    return Get-AotProductionProcessSnapshot -Process $Binding.ProcessObject `
        -Side $Binding.Side
}

function Assert-AotProcessSnapshot {
    param(
        [Parameter(Mandatory = $true)][object]$Binding,
        [Parameter(Mandatory = $true)][object]$Snapshot
    )

    $side = $Binding.Side
    foreach ($propertyName in 'Exists', 'HasExited', 'ProcessId',
            'StartTimeUtc', 'ExecutablePath') {
        if ($null -eq $Snapshot.PSObject.Properties[$propertyName]) {
            Throw-AotLogWatchFailure -Code 'PROCESS_QUERY_FAILED' `
                -Message "$side process snapshot lacks $propertyName." -Side $side
        }
    }
    if (-not [bool]$Snapshot.Exists) {
        Throw-AotLogWatchFailure -Code 'PROCESS_NOT_FOUND' `
            -Message "$side process no longer exists." -Side $side
    }
    if ([bool]$Snapshot.HasExited) {
        Throw-AotLogWatchFailure -Code 'PROCESS_EXITED' `
            -Message "$side retained process has exited." -Side $side
    }
    if ([int64]$Snapshot.ProcessId -ne [int64]$Binding.ProcessId) {
        Throw-AotLogWatchFailure -Code 'PROCESS_START_MISMATCH' `
            -Message "$side process ID changed." -Side $side
    }
    $start = ConvertTo-AotUtcDateTime $Snapshot.StartTimeUtc `
        "$side process StartTimeUtc"
    if ($start.Ticks -ne $Binding.StartTimeUtc.Ticks) {
        Throw-AotLogWatchFailure -Code 'PROCESS_START_MISMATCH' `
            -Message "$side process start time changed (possible PID reuse)." `
            -Side $side
    }
    $imagePath = ConvertTo-AotFullPath ([string]$Snapshot.ExecutablePath) `
        "$side process ExecutablePath"
    if (-not (Test-AotSamePath $imagePath $Binding.ExecutablePath)) {
        Throw-AotLogWatchFailure -Code 'PROCESS_IMAGE_PATH_MISMATCH' `
            -Message "$side process image path changed." -Side $side
    }
}

function Open-AotPathProbe {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][IO.FileShare]$Share,
        [Parameter(Mandatory = $true)][string]$FailureCode,
        [Parameter(Mandatory = $true)][string]$Label,
        [Parameter(Mandatory = $true)][string]$Side
    )

    return Open-AotReadStream -Path $Path -Share $Share `
        -FailureCode $FailureCode -Label $Label -Side $Side
}

function Assert-AotBoundFile {
    param(
        [Parameter(Mandatory = $true)][object]$Binding,
        [Parameter(Mandatory = $true)][ValidateSet('Executable', 'Log')]
        [string]$Kind
    )

    $side = $Binding.Side
    if ($Kind -ceq 'Executable') {
        $stream = $Binding.ExecutableStream
        $expectedPath = $Binding.ExecutablePath
        $expectedId = $Binding.ExecutableFileId
        $share = [IO.FileShare]::Read
        $pathCode = 'EXECUTABLE_PATH_MISMATCH'
        $idCode = 'EXECUTABLE_FILE_ID_CHANGED'
        $probeCode = 'EXECUTABLE_OPEN_FAILED'
        $label = "$side executable"
    } else {
        $stream = $Binding.LogStream
        $expectedPath = $Binding.LogPath
        $expectedId = $Binding.LogFileId
        $share = [IO.FileShare]([IO.FileShare]::Read -bor
            [IO.FileShare]::Write -bor [IO.FileShare]::Delete)
        $pathCode = 'LOG_FINAL_PATH_CHANGED'
        $idCode = 'LOG_FILE_ID_CHANGED'
        $probeCode = 'LOG_PATH_REOPEN_FAILED'
        $label = "$side log"
    }

    $retainedId = Get-AotFileIdentity -Stream $stream -FailureCode $idCode `
        -Label "$label retained handle" -Side $side
    if ($retainedId -cne $expectedId) {
        Throw-AotLogWatchFailure -Code $idCode `
            -Message "$label retained file identity changed." -Side $side
    }
    $retainedPath = Get-AotFinalFilePath -Stream $stream `
        -FailureCode $pathCode -Label "$label retained handle" -Side $side
    if (-not (Test-AotSamePath $retainedPath $expectedPath)) {
        Throw-AotLogWatchFailure -Code $pathCode `
            -Message "$label retained final path changed." -Side $side
    }

    $probe = Open-AotPathProbe -Path $expectedPath -Share $share `
        -FailureCode $probeCode -Label "$label path probe" -Side $side
    try {
        $probeId = Get-AotFileIdentity -Stream $probe -FailureCode $idCode `
            -Label "$label path probe" -Side $side
        $probePath = Get-AotFinalFilePath -Stream $probe `
            -FailureCode $pathCode -Label "$label path probe" -Side $side
        if ($probeId -cne $expectedId) {
            Throw-AotLogWatchFailure -Code $idCode `
                -Message "$label path now names a different file." -Side $side
        }
        if (-not (Test-AotSamePath $probePath $expectedPath)) {
            Throw-AotLogWatchFailure -Code $pathCode `
                -Message "$label path probe resolved elsewhere." -Side $side
        }
    } finally {
        $probe.Dispose()
    }
}

function Assert-AotBindingIdentity {
    param(
        [Parameter(Mandatory = $true)][object]$Binding,
        [Parameter(Mandatory = $true)][bool]$SyntheticFixture,
        [AllowNull()][Collections.IDictionary]$TestHooks = $null,
        [int]$PollIndex = -1
    )

    $snapshot = Get-AotProcessSnapshot -Binding $Binding `
        -SyntheticFixture $SyntheticFixture -TestHooks $TestHooks `
        -PollIndex $PollIndex
    Assert-AotProcessSnapshot -Binding $Binding -Snapshot $snapshot
    Assert-AotBoundFile -Binding $Binding -Kind Executable
    Assert-AotBoundFile -Binding $Binding -Kind Log
    if ($Binding.LogStream.Length -lt $Binding.HighWaterLength -or
        $Binding.LogStream.Length -lt $Binding.ReadOffset -or
        $Binding.LogStream.Length -lt $Binding.BaselineOffset) {
        Throw-AotLogWatchFailure -Code 'LOG_SHRANK' `
            -Message "$($Binding.Side) log shrank below its retained high-water mark." `
            -Side $Binding.Side
    }
}

function New-AotLogBinding {
    param(
        [Parameter(Mandatory = $true)][object]$Receipt,
        [Parameter(Mandatory = $true)][bool]$SyntheticFixture,
        [AllowNull()][Collections.IDictionary]$TestHooks = $null
    )

    $side = $Receipt.Side
    $processObject = $null
    $executableStream = $null
    $logStream = $null
    try {
        if (-not $SyntheticFixture) {
            try {
                $processObject = Get-Process -Id $Receipt.ProcessId `
                    -ErrorAction Stop
                $null = $processObject.Handle
            } catch {
                Throw-AotLogWatchFailure -Code 'PROCESS_NOT_FOUND' `
                    -Message "$side process $($Receipt.ProcessId) was not found." `
                    -Side $side
            }
        }

        $bootstrap = [pscustomobject]@{
            Side = $side
            ProcessId = $Receipt.ProcessId
            StartTimeUtc = $Receipt.StartTimeUtc
            ExecutablePath = $Receipt.FilePath
            ProcessObject = $processObject
        }
        $snapshot = Get-AotProcessSnapshot -Binding $bootstrap `
            -SyntheticFixture $SyntheticFixture -TestHooks $TestHooks
        Assert-AotProcessSnapshot -Binding $bootstrap -Snapshot $snapshot

        $exeShare = [IO.FileShare]::Read
        $executableStream = Open-AotReadStream -Path $Receipt.FilePath `
            -Share $exeShare -FailureCode 'EXECUTABLE_OPEN_FAILED' `
            -Label "$side executable" -Side $side
        $executablePath = Get-AotFinalFilePath -Stream $executableStream `
            -FailureCode 'EXECUTABLE_PATH_MISMATCH' `
            -Label "$side executable" -Side $side
        if (-not (Test-AotSamePath $executablePath $Receipt.FilePath)) {
            Throw-AotLogWatchFailure -Code 'EXECUTABLE_PATH_MISMATCH' `
                -Message "$side executable resolved outside its receipt path." `
                -Side $side
        }
        if ($executableStream.Length -ne $Receipt.XeniaBytes) {
            Throw-AotLogWatchFailure -Code 'EXECUTABLE_SIZE_MISMATCH' `
                -Message "$side executable size does not match its launch receipt." `
                -Side $side
        }
        $actualHash = Get-AotStreamSha256 -Stream $executableStream
        if ($actualHash -cne $Receipt.XeniaSha256) {
            Throw-AotLogWatchFailure -Code 'EXECUTABLE_HASH_MISMATCH' `
                -Message "$side executable hash does not match its launch receipt." `
                -Side $side
        }
        $executableId = Get-AotFileIdentity -Stream $executableStream `
            -FailureCode 'EXECUTABLE_FILE_ID_CHANGED' `
            -Label "$side executable" -Side $side

        $logShare = [IO.FileShare]([IO.FileShare]::Read -bor
            [IO.FileShare]::Write -bor [IO.FileShare]::Delete)
        $logStream = Open-AotReadStream -Path $Receipt.LogPath `
            -Share $logShare -FailureCode 'LOG_OPEN_FAILED' `
            -Label "$side log" -Side $side -NotFoundCode 'LOG_NOT_FOUND'
        $logPath = Get-AotFinalFilePath -Stream $logStream `
            -FailureCode 'LOG_FINAL_PATH_CHANGED' -Label "$side log" `
            -Side $side
        if (-not (Test-AotSamePath $logPath $Receipt.LogPath)) {
            Throw-AotLogWatchFailure -Code 'LOG_PATH_INVALID' `
                -Message "$side log resolved outside its required xenia.log path." `
                -Side $side
        }
        $logId = Get-AotFileIdentity -Stream $logStream `
            -FailureCode 'LOG_FILE_ID_CHANGED' -Label "$side log" -Side $side

        $binding = [pscustomobject][ordered]@{
            Side = $side
            ProcessId = $Receipt.ProcessId
            StartTimeUtc = $Receipt.StartTimeUtc
            ExecutablePath = $executablePath
            ExecutableSha256 = $actualHash
            ExecutableFileId = $executableId
            ExecutableStream = $executableStream
            ProcessObject = $processObject
            LogPath = $logPath
            LogFileId = $logId
            LogStream = $logStream
            BaselineOffset = [int64]0
            ReadOffset = [int64]0
            HighWaterLength = [int64]0
            CarryStartOffset = [int64]0
            Carry = [byte[]]::new(0)
            BytesRead = [int64]0
            CompleteLineCount = [int64]0
            IgnoredLineCount = [int64]0
            Candidates = [Collections.Generic.List[object]]::new()
            ArgumentListSha256 = $Receipt.ArgumentListSha256
            RunId = $Receipt.RunId
        }

        $baselineStopwatch = [Diagnostics.Stopwatch]::StartNew()
        $baselineStartedMs = Get-AotWatchElapsedMilliseconds `
            -SyntheticFixture $SyntheticFixture -TestHooks $TestHooks `
            -Stopwatch $baselineStopwatch
        $baselineProbe = 0
        while ($true) {
            Assert-AotBindingIdentity -Binding $binding `
                -SyntheticFixture $SyntheticFixture -TestHooks $TestHooks `
                -PollIndex (-1 - $baselineProbe)
            [int64]$candidateBaseline = $logStream.Length
            $binding.HighWaterLength = $candidateBaseline
            $lineBoundary = $candidateBaseline -eq 0
            if ($candidateBaseline -gt 0) {
                try {
                    $logStream.Position = $candidateBaseline - 1
                    $lineBoundary = $logStream.ReadByte() -eq 10
                } catch {
                    Throw-AotLogWatchFailure -Code 'LOG_READ_FAILED' `
                        -Message "$side baseline boundary read failed: $($_.Exception.Message)" `
                        -Side $side
                }
            }
            if ($lineBoundary) {
                $binding.BaselineOffset = $candidateBaseline
                $binding.ReadOffset = $candidateBaseline
                $binding.CarryStartOffset = $candidateBaseline
                $logStream.Position = $candidateBaseline
                break
            }

            $baselineNowMs = Get-AotWatchElapsedMilliseconds `
                -SyntheticFixture $SyntheticFixture -TestHooks $TestHooks `
                -Stopwatch $baselineStopwatch
            if ($baselineNowMs - $baselineStartedMs -ge
                $script:BaselineTimeoutMilliseconds) {
                Throw-AotLogWatchFailure -Code 'BASELINE_PARTIAL_LINE' `
                    -Message "$side log did not reach a complete-line EOF boundary within the bounded baseline window." `
                    -Side $side
            }
            if ($SyntheticFixture -and
                $TestHooks.Contains('BeforeBaselineProbe')) {
                $null = & $TestHooks['BeforeBaselineProbe'] $side $baselineProbe
            }
            Invoke-AotWatchSleep `
                -Milliseconds $script:BaselinePollMilliseconds `
                -SyntheticFixture $SyntheticFixture -TestHooks $TestHooks
            $baselineProbe++
        }
        $baselineStopwatch.Stop()

        Assert-AotBindingIdentity -Binding $binding `
            -SyntheticFixture $SyntheticFixture -TestHooks $TestHooks
        return $binding
    } catch {
        if ($null -ne $logStream) { $logStream.Dispose() }
        if ($null -ne $executableStream) { $executableStream.Dispose() }
        if ($null -ne $processObject) { $processObject.Dispose() }
        throw
    }
}

function Assert-AotBindingPair {
    param(
        [Parameter(Mandatory = $true)][object]$Daddy,
        [Parameter(Mandatory = $true)][object]$CJ
    )

    if (Test-AotSamePath $Daddy.ExecutablePath $CJ.ExecutablePath) {
        Throw-AotLogWatchFailure -Code 'WATCH_INPUT_INVALID' `
            -Message 'Daddy and CJ retained handles resolved to one executable path.'
    }
    if ($Daddy.ExecutableFileId -ceq $CJ.ExecutableFileId) {
        Throw-AotLogWatchFailure -Code 'WATCH_INPUT_INVALID' `
            -Message 'Daddy and CJ retained handles identify one executable file.'
    }
    if (Test-AotSamePath $Daddy.LogPath $CJ.LogPath) {
        Throw-AotLogWatchFailure -Code 'WATCH_INPUT_INVALID' `
            -Message 'Daddy and CJ retained handles resolved to one log path.'
    }
    if ($Daddy.LogFileId -ceq $CJ.LogFileId) {
        Throw-AotLogWatchFailure -Code 'WATCH_INPUT_INVALID' `
            -Message 'Daddy and CJ retained handles identify one log file.'
    }
}

function Add-AotLogBytes {
    param(
        [Parameter(Mandatory = $true)][object]$Binding,
        [Parameter(Mandatory = $true)][byte[]]$Bytes,
        [Parameter(Mandatory = $true)][int]$Count,
        [Parameter(Mandatory = $true)][int64]$ChunkStartOffset
    )

    if ($Count -le 0) { return }
    $carryLength = $Binding.Carry.Length
    $combined = [byte[]]::new($carryLength + $Count)
    if ($carryLength -gt 0) {
        [Array]::Copy($Binding.Carry, 0, $combined, 0, $carryLength)
    }
    [Array]::Copy($Bytes, 0, $combined, $carryLength, $Count)
    [int64]$combinedStart = if ($carryLength -gt 0) {
        $Binding.CarryStartOffset
    } else { $ChunkStartOffset }

    $lineStart = 0
    for ($index = 0; $index -lt $combined.Length; $index++) {
        if ($combined[$index] -ne 10) { continue }
        $rawLength = $index - $lineStart
        if ($rawLength -gt $script:MaximumLineBytes) {
            Throw-AotLogWatchFailure -Code 'LOG_LINE_TOO_LONG' `
                -Message "$($Binding.Side) log contained an overlong complete line." `
                -Side $Binding.Side
        }
        $textLength = $rawLength
        if ($textLength -gt 0 -and
            $combined[$lineStart + $textLength - 1] -eq 13) {
            $textLength--
        }
        try {
            $text = $script:StrictUtf8.GetString(
                $combined, $lineStart, $textLength)
        } catch [Text.DecoderFallbackException] {
            Throw-AotLogWatchFailure -Code 'LOG_INVALID_UTF8' `
                -Message "$($Binding.Side) log contained invalid UTF-8 in a complete line." `
                -Side $Binding.Side
        }
        $Binding.CompleteLineCount++
        if ($text.IndexOf($script:MarkerPrefix,
                [StringComparison]::OrdinalIgnoreCase) -ge 0) {
            if ($Binding.Candidates.Count -ge $script:MaximumCandidateLines) {
                Throw-AotLogWatchFailure `
                    -Code 'SA2_EVIDENCE_INVALID' `
                    -Message "$($Binding.Side) exceeded the bounded SA2 marker candidate count." `
                    -Side $Binding.Side
            }
            $Binding.Candidates.Add([pscustomobject][ordered]@{
                Side = $Binding.Side
                ByteOffset = [uint64]($combinedStart + $lineStart)
                Text = $text
            })
        } else {
            $Binding.IgnoredLineCount++
        }
        $lineStart = $index + 1
    }

    $remaining = $combined.Length - $lineStart
    if ($remaining -gt $script:MaximumLineBytes) {
        Throw-AotLogWatchFailure -Code 'LOG_LINE_TOO_LONG' `
            -Message "$($Binding.Side) log retained an overlong partial line." `
            -Side $Binding.Side
    }
    $newCarry = [byte[]]::new($remaining)
    if ($remaining -gt 0) {
        [Array]::Copy($combined, $lineStart, $newCarry, 0, $remaining)
    }
    $Binding.Carry = $newCarry
    $Binding.CarryStartOffset = $combinedStart + $lineStart
}

function Read-AotLogAppend {
    param([Parameter(Mandatory = $true)][object]$Binding)

    $stream = $Binding.LogStream
    [int64]$length = $stream.Length
    if ($length -lt $Binding.HighWaterLength -or
        $length -lt $Binding.ReadOffset -or
        $length -lt $Binding.BaselineOffset) {
        Throw-AotLogWatchFailure -Code 'LOG_SHRANK' `
            -Message "$($Binding.Side) log shrank during the acceptance watch." `
            -Side $Binding.Side
    }
    $Binding.HighWaterLength = $length
    if ($length -eq $Binding.ReadOffset) { return }

    try { $stream.Position = $Binding.ReadOffset } catch {
        Throw-AotLogWatchFailure -Code 'LOG_READ_FAILED' `
            -Message "$($Binding.Side) log seek failed: $($_.Exception.Message)" `
            -Side $Binding.Side
    }
    $buffer = [byte[]]::new($script:ReadBufferBytes)
    while ($Binding.ReadOffset -lt $length) {
        [int64]$remaining = $length - $Binding.ReadOffset
        $request = [int][Math]::Min([int64]$buffer.Length, $remaining)
        try { $read = $stream.Read($buffer, 0, $request) } catch {
            Throw-AotLogWatchFailure -Code 'LOG_READ_FAILED' `
                -Message "$($Binding.Side) log read failed: $($_.Exception.Message)" `
                -Side $Binding.Side
        }
        if ($read -le 0) {
            Throw-AotLogWatchFailure -Code 'LOG_SHORT_READ' `
                -Message "$($Binding.Side) log returned EOF before its captured length." `
                -Side $Binding.Side
        }
        [int64]$chunkStart = $Binding.ReadOffset
        Add-AotLogBytes -Binding $Binding -Bytes $buffer -Count $read `
            -ChunkStartOffset $chunkStart
        $Binding.ReadOffset += $read
        $Binding.BytesRead += $read
    }
}

function Test-AotBindingsAtStableEof {
    param([Parameter(Mandatory = $true)][object[]]$Bindings)

    foreach ($binding in $Bindings) {
        try { [int64]$length = $binding.LogStream.Length } catch {
            Throw-AotLogWatchFailure -Code 'LOG_READ_FAILED' `
                -Message "$($binding.Side) log EOF query failed: $($_.Exception.Message)" `
                -Side $binding.Side
        }
        if ($length -ne $binding.ReadOffset) { return $false }
    }
    return $true
}

function Sync-AotFinalLogSnapshot {
    param(
        [Parameter(Mandatory = $true)][object[]]$Bindings,
        [Parameter(Mandatory = $true)][bool]$SyntheticFixture,
        [AllowNull()][Collections.IDictionary]$TestHooks = $null,
        [int]$PollIndex = -1
    )

    for ($attempt = 0; $attempt -lt $script:FinalSnapshotAttempts; $attempt++) {
        foreach ($binding in $Bindings) {
            Assert-AotBindingIdentity -Binding $binding `
                -SyntheticFixture $SyntheticFixture -TestHooks $TestHooks `
                -PollIndex $PollIndex
            Read-AotLogAppend -Binding $binding
        }
        foreach ($binding in $Bindings) {
            Assert-AotBindingIdentity -Binding $binding `
                -SyntheticFixture $SyntheticFixture -TestHooks $TestHooks `
                -PollIndex $PollIndex
        }
        if (Test-AotBindingsAtStableEof -Bindings $Bindings) { return }
    }
    Throw-AotLogWatchFailure -Code 'LOG_READ_FAILED' `
        -Message 'Logs did not reach a stable readable EOF snapshot at timeout.'
}

function Get-AotCombinedCandidates {
    param(
        [Parameter(Mandatory = $true)][object]$DaddyBinding,
        [Parameter(Mandatory = $true)][object]$CjBinding
    )
    return @($DaddyBinding.Candidates.ToArray() +
        $CjBinding.Candidates.ToArray())
}

function Get-AotSanitizedBinding {
    param([AllowNull()][object]$Binding)

    if ($null -eq $Binding) { return $null }
    return [pscustomobject][ordered]@{
        Side = $Binding.Side
        ProcessId = $Binding.ProcessId
        StartTimeUtc = $Binding.StartTimeUtc.ToString('o')
        ExecutablePath = $Binding.ExecutablePath
        ExecutableSha256 = $Binding.ExecutableSha256
        ExecutableFileId = $Binding.ExecutableFileId
        LogPath = $Binding.LogPath
        LogFileId = $Binding.LogFileId
        BaselineOffset = $Binding.BaselineOffset
        FinalReadOffset = $Binding.ReadOffset
        BytesRead = $Binding.BytesRead
        CompleteLineCount = $Binding.CompleteLineCount
        IgnoredLineCount = $Binding.IgnoredLineCount
        CandidateLineCount = $Binding.Candidates.Count
        PartialByteCount = $Binding.Carry.Length
        ArgumentListSha256 = $Binding.ArgumentListSha256
        RunId = $Binding.RunId
    }
}

function Close-AotLogBinding {
    param([AllowNull()][object]$Binding)

    if ($null -eq $Binding) { return }
    if ($null -ne $Binding.LogStream) { $Binding.LogStream.Dispose() }
    if ($null -ne $Binding.ExecutableStream) {
        $Binding.ExecutableStream.Dispose()
    }
    if ($null -ne $Binding.ProcessObject) { $Binding.ProcessObject.Dispose() }
}

function Assert-AotSyntheticHooks {
    param([Parameter(Mandatory = $true)][Collections.IDictionary]$TestHooks)

    $required = @(
        'TempRoot', 'GetProcessSnapshot', 'GetElapsedMilliseconds', 'Sleep')
    $allowed = $required + @(
        'BeforeBaselineProbe', 'BeforePoll', 'AfterRead',
        'CancellationRequested')
    $keys = @($TestHooks.Keys | ForEach-Object { [string]$_ })
    $missing = @($required | Where-Object { $_ -notin $keys })
    $extra = @($keys | Where-Object { $_ -notin $allowed })
    if ($missing.Count -ne 0 -or $extra.Count -ne 0) {
        Throw-AotLogWatchFailure -Code 'WATCH_INPUT_INVALID' `
            -Message ("Synthetic TestHooks schema mismatch: missing=[{0}] extra=[{1}]" -f
                ($missing -join ','), ($extra -join ','))
    }
    foreach ($name in 'GetProcessSnapshot', 'GetElapsedMilliseconds', 'Sleep') {
        if ($TestHooks[$name] -isnot [scriptblock]) {
            Throw-AotLogWatchFailure -Code 'WATCH_INPUT_INVALID' `
                -Message "TestHooks.$name must be a scriptblock."
        }
    }
    foreach ($name in 'BeforeBaselineProbe', 'BeforePoll', 'AfterRead',
            'CancellationRequested') {
        if ($TestHooks.Contains($name) -and
            $TestHooks[$name] -isnot [scriptblock]) {
            Throw-AotLogWatchFailure -Code 'WATCH_INPUT_INVALID' `
                -Message "TestHooks.$name must be a scriptblock."
        }
    }

    $tempRoot = ConvertTo-AotFullPath ([string]$TestHooks['TempRoot']) `
        'TestHooks.TempRoot'
    $trustedAnchor = Get-AotTrustedSyntheticAnchor
    if (-not (Test-AotPathUnderRoot $tempRoot $trustedAnchor)) {
        Throw-AotLogWatchFailure -Code 'WATCH_INPUT_INVALID' `
            -Message 'Synthetic TempRoot must be a strict descendant of the trusted LocalApplicationData Temp anchor.'
    }
    if (-not [IO.Directory]::Exists($tempRoot)) {
        Throw-AotLogWatchFailure -Code 'WATCH_INPUT_INVALID' `
            -Message 'Synthetic TempRoot must already exist as a directory.'
    }
    Assert-AotPathHasNoReparsePoints -Path $tempRoot -Root $trustedAnchor `
        -Label 'Synthetic TempRoot'
    return $tempRoot
}

function Invoke-AotRuntimeCoreAcceptanceWatch {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$DaddyLaunchReceipt,
        [Parameter(Mandatory = $true)][object]$CjLaunchReceipt,
        [ValidateRange(1, 900)][int]$TimeoutSeconds = 120,
        [ValidateRange(10, 5000)][int]$PollMilliseconds = 100,
        [switch]$SyntheticFixture,
        [AllowNull()][Collections.IDictionary]$TestHooks = $null
    )

    $startedUtc = [DateTime]::UtcNow
    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    $daddyBinding = $null
    $cjBinding = $null
    $evidence = $null
    $status = 'FAILED'
    $failureCode = $null
    $failureSide = $null
    $failureMessage = $null
    $passed = $false
    $syntheticRoot = $null
    $pollIndex = 0

    try {
        if ($SyntheticFixture) {
            if ($null -eq $TestHooks) {
                Throw-AotLogWatchFailure -Code 'WATCH_INPUT_INVALID' `
                    -Message 'SyntheticFixture requires explicit TestHooks.'
            }
            $syntheticRoot = Assert-AotSyntheticHooks -TestHooks $TestHooks
        } elseif ($null -ne $TestHooks) {
            Throw-AotLogWatchFailure -Code 'WATCH_INPUT_INVALID' `
                -Message 'TestHooks are forbidden outside SyntheticFixture mode.'
        }

        $daddyReceipt = Assert-AotReceiptShape -Receipt $DaddyLaunchReceipt `
            -ExpectedSide Daddy -SyntheticFixture:$SyntheticFixture `
            -SyntheticRoot $syntheticRoot
        $cjReceipt = Assert-AotReceiptShape -Receipt $CjLaunchReceipt `
            -ExpectedSide CJ -SyntheticFixture:$SyntheticFixture `
            -SyntheticRoot $syntheticRoot
        Assert-AotReceiptPair -Daddy $daddyReceipt -CJ $cjReceipt

        $daddyBinding = New-AotLogBinding -Receipt $daddyReceipt `
            -SyntheticFixture ([bool]$SyntheticFixture) -TestHooks $TestHooks
        $cjBinding = New-AotLogBinding -Receipt $cjReceipt `
            -SyntheticFixture ([bool]$SyntheticFixture) -TestHooks $TestHooks
        Assert-AotBindingPair -Daddy $daddyBinding -CJ $cjBinding

        while ($true) {
            [int64]$elapsedMs = Get-AotWatchElapsedMilliseconds `
                -SyntheticFixture ([bool]$SyntheticFixture) `
                -TestHooks $TestHooks -Stopwatch $stopwatch
            if ($elapsedMs -ge ([int64]$TimeoutSeconds * 1000)) { break }

            if ($SyntheticFixture -and
                $TestHooks.Contains('CancellationRequested') -and
                [bool](& $TestHooks['CancellationRequested'] $pollIndex)) {
                Throw-AotLogWatchFailure -Code 'WATCH_CANCELLED' `
                    -Message 'Acceptance log watch was cancelled.'
            }
            if ($SyntheticFixture -and $TestHooks.Contains('BeforePoll')) {
                $null = & $TestHooks['BeforePoll'] $pollIndex
            }

            foreach ($binding in $daddyBinding, $cjBinding) {
                Assert-AotBindingIdentity -Binding $binding `
                    -SyntheticFixture ([bool]$SyntheticFixture) `
                    -TestHooks $TestHooks -PollIndex $pollIndex
                Read-AotLogAppend -Binding $binding
            }

            if ($SyntheticFixture -and $TestHooks.Contains('AfterRead')) {
                $null = & $TestHooks['AfterRead'] $pollIndex
            }
            foreach ($binding in $daddyBinding, $cjBinding) {
                Assert-AotBindingIdentity -Binding $binding `
                    -SyntheticFixture ([bool]$SyntheticFixture) `
                    -TestHooks $TestHooks -PollIndex $pollIndex
            }

            $records = @(Get-AotCombinedCandidates $daddyBinding $cjBinding)
            $evidence = Test-AotRuntimeCoreSa2Evidence -InputObject $records
            $terminalCodes = @($evidence.ErrorCodes | Where-Object {
                $_ -notin $script:PendingEvidenceCodes
            })
            if ($terminalCodes.Count -ne 0) {
                Throw-AotLogWatchFailure -Code 'SA2_EVIDENCE_INVALID' `
                    -Message ("SA2 evidence failed terminal validation: {0}" -f
                        ($terminalCodes -join ','))
            }
            if ($evidence.Passed -and $daddyBinding.Carry.Length -eq 0 -and
                $cjBinding.Carry.Length -eq 0) {
                foreach ($binding in $daddyBinding, $cjBinding) {
                    Assert-AotBindingIdentity -Binding $binding `
                        -SyntheticFixture ([bool]$SyntheticFixture) `
                        -TestHooks $TestHooks -PollIndex $pollIndex
                }
                if (Test-AotBindingsAtStableEof -Bindings @(
                        $daddyBinding, $cjBinding)) {
                    $passed = $true
                    $status = 'PASSED'
                    break
                }
            }

            Invoke-AotWatchSleep -Milliseconds $PollMilliseconds `
                -SyntheticFixture ([bool]$SyntheticFixture) `
                -TestHooks $TestHooks
            $pollIndex++
        }

        if (-not $passed) {
            Sync-AotFinalLogSnapshot -Bindings @($daddyBinding, $cjBinding) `
                -SyntheticFixture ([bool]$SyntheticFixture) `
                -TestHooks $TestHooks -PollIndex $pollIndex
            $records = @(Get-AotCombinedCandidates $daddyBinding $cjBinding)
            $evidence = Test-AotRuntimeCoreSa2Evidence -InputObject $records
            $terminalCodes = @($evidence.ErrorCodes | Where-Object {
                $_ -notin $script:PendingEvidenceCodes
            })
            if ($terminalCodes.Count -ne 0) {
                Throw-AotLogWatchFailure -Code 'SA2_EVIDENCE_INVALID' `
                    -Message ("SA2 evidence failed terminal validation: {0}" -f
                        ($terminalCodes -join ','))
            }
            if ($evidence.Passed -and $daddyBinding.Carry.Length -eq 0 -and
                $cjBinding.Carry.Length -eq 0) {
                $passed = $true
                $status = 'PASSED'
            } elseif ($daddyBinding.Carry.Length -ne 0 -or
                $cjBinding.Carry.Length -ne 0) {
                Throw-AotLogWatchFailure -Code 'LOG_PARTIAL_FINAL_LINE' `
                    -Message 'Acceptance watch timed out with an incomplete final log line.'
            } else {
                Throw-AotLogWatchFailure -Code 'SA2_EVIDENCE_TIMEOUT' `
                    -Message 'Timed out before the exact SA2 acceptance evidence completed.'
            }
        }
    } catch {
        $failure = Get-AotWatchFailure -Exception $_.Exception
        $failureCode = $failure.Code
        $failureSide = $failure.Side
        $failureMessage = $failure.Message
        if ($failureCode -ceq 'SA2_EVIDENCE_TIMEOUT') {
            $status = 'TIMED_OUT'
        } elseif ($failureCode -ceq 'WATCH_CANCELLED') {
            $status = 'CANCELLED'
        } else {
            $status = 'FAILED'
        }
    } finally {
        $stopwatch.Stop()
        $sanitizedDaddy = Get-AotSanitizedBinding $daddyBinding
        $sanitizedCj = Get-AotSanitizedBinding $cjBinding
        Close-AotLogBinding $cjBinding
        Close-AotLogBinding $daddyBinding
    }

    [int64]$durationMs = $stopwatch.ElapsedMilliseconds
    if ($SyntheticFixture -and $null -ne $TestHooks -and
        $TestHooks.Contains('GetElapsedMilliseconds') -and
        $TestHooks['GetElapsedMilliseconds'] -is [scriptblock]) {
        try {
            $durationMs = [int64](& $TestHooks['GetElapsedMilliseconds'])
        } catch {
            $durationMs = $stopwatch.ElapsedMilliseconds
        }
    }
    return [pscustomobject][ordered]@{
        SchemaVersion = 1
        EvidenceTrust = if ($SyntheticFixture) {
            'SYNTHETIC_TEST_ONLY'
        } else {
            'PRODUCTION_RETAINED_HANDLE'
        }
        Status = $status
        Passed = $passed
        FailureCode = $failureCode
        FailureSide = $failureSide
        FailureMessage = $failureMessage
        StartedUtc = $startedUtc.ToString('o')
        CompletedUtc = [DateTime]::UtcNow.ToString('o')
        DurationMs = $durationMs
        RequiresOwnedRunCleanup = (-not $passed)
        Daddy = $sanitizedDaddy
        CJ = $sanitizedCj
        Evidence = $evidence
    }
}

Export-ModuleMember -Function Invoke-AotRuntimeCoreAcceptanceWatch
