param([int[]]$TargetPid = @())

$ErrorActionPreference = 'Stop'
$PROCESS_VM_READ = 0x10

if (-not ('AotUiRead' -as [type])) {
    Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class AotUiRead {
  [DllImport("kernel32.dll", SetLastError=true)]
  public static extern IntPtr OpenProcess(int access, bool inherit, int pid);
  [DllImport("kernel32.dll", SetLastError=true)]
  public static extern bool ReadProcessMemory(IntPtr process, IntPtr address,
                                               byte[] buffer, int size,
                                               out int read);
  [DllImport("kernel32.dll")]
  public static extern bool CloseHandle(IntPtr process);
}
'@
}

function Read-HostBytes([IntPtr]$Process, [int64]$Address, [int]$Count) {
    $bytes = New-Object byte[] $Count
    $read = 0
    $ok = [AotUiRead]::ReadProcessMemory(
        $Process, [IntPtr]::new($Address), $bytes, $Count, [ref]$read)
    if (-not $ok -or $read -ne $Count) {
        throw ('ReadProcessMemory failed at host 0x{0:X} ({1}/{2} bytes)' -f
            $Address, $read, $Count)
    }
    return ,$bytes
}

function Read-GuestWord([IntPtr]$Process, [int64]$Base, [int64]$Address) {
    $bytes = Read-HostBytes $Process ($Base + $Address) 4
    return ([uint32]$bytes[0] -shl 24) -bor
           ([uint32]$bytes[1] -shl 16) -bor
           ([uint32]$bytes[2] -shl 8) -bor
           [uint32]$bytes[3]
}

function Read-GuestBytes([IntPtr]$Process, [int64]$Base,
                         [uint32]$Address, [int]$Count) {
    return Read-HostBytes $Process ($Base + [int64]$Address) $Count
}

function Test-GuestPointer([uint32]$Value) {
    return ([int64]$Value -ge 0x10000L -and [int64]$Value -lt 0xE0000000L)
}

function Get-ArrayHeader([IntPtr]$Process, [int64]$Base, [uint32]$Address) {
    return [pscustomobject]@{
        Data = Read-GuestWord $Process $Base $Address
        Num = Read-GuestWord $Process $Base ([int64]$Address + 4)
        Max = Read-GuestWord $Process $Base ([int64]$Address + 8)
    }
}

function Assert-BoundedHeader($Header, [string]$Label) {
    if ($Header.Num -gt $Header.Max) {
        throw "$Label Num exceeds Max"
    }
    if ($Header.Num -gt 31) {
        throw "$Label Num exceeds the diagnostic cap of 31"
    }
    if ($Header.Num -gt 0 -and -not (Test-GuestPointer $Header.Data)) {
        throw "$Label has an invalid Data pointer"
    }
}

function Read-WrapperName([IntPtr]$Process, [int64]$Base, [uint32]$Wrapper) {
    $Name = Get-ArrayHeader $Process $Base $Wrapper
    if ($Name.Num -gt $Name.Max) { throw 'Wrapper name Num exceeds Max' }
    if ($Name.Num -gt 256) { throw 'Wrapper name exceeds 256-byte cap' }
    if ($Name.Num -eq 0) { return '' }
    if (-not (Test-GuestPointer $Name.Data)) { throw 'Invalid wrapper name pointer' }
    $bytes = Read-GuestBytes $Process $Base $Name.Data ([int]$Name.Num)
    $nul = [Array]::IndexOf($bytes, [byte]0)
    if ($nul -lt 0) { throw 'Wrapper name lacks a NUL terminator' }
    return [Text.Encoding]::ASCII.GetString($bytes, 0, $nul)
}

function Get-ManagerCore([IntPtr]$Process, [int64]$Base, [uint32]$Holder) {
    $active = Get-ArrayHeader $Process $Base ($Holder + 0x1C)
    Assert-BoundedHeader $active 'Active scene stack'
    return [pscustomobject]@{
        Active = $active
        OverallInputGate = Read-GuestWord $Process $Base ($Holder + 0x40)
        CaptureWrapper = Read-GuestWord $Process $Base ($Holder + 0xB4)
        CaptureConsume = Read-GuestWord $Process $Base ($Holder + 0xB8)
    }
}

function Get-CoreSignature($Core) {
    return ('{0:X8}:{1}:{2}:{3:X8}:{4:X8}:{5:X8}' -f
        $Core.Active.Data, $Core.Active.Num, $Core.Active.Max,
        $Core.OverallInputGate, $Core.CaptureWrapper, $Core.CaptureConsume)
}

function Read-Wrapper([IntPtr]$Process, [int64]$Base, [uint32]$Wrapper,
                      [string]$Index, [bool]$Captured) {
    if (-not (Test-GuestPointer $Wrapper)) { throw 'Invalid scene wrapper pointer' }
    return [pscustomobject]@{
        Kind = 'Scene'
        Index = $Index
        Wrapper = ('{0:X8}' -f $Wrapper)
        Name = Read-WrapperName $Process $Base $Wrapper
        BackingAsset = ('{0:X8}' -f (Read-GuestWord $Process $Base ($Wrapper + 0x30)))
        MovieInstance = ('{0:X8}' -f (Read-GuestWord $Process $Base ($Wrapper + 0x34)))
        Open = Read-GuestWord $Process $Base ($Wrapper + 0x3C)
        InputEligible = Read-GuestWord $Process $Base ($Wrapper + 0x40)
        State44 = ('{0:X8}' -f (Read-GuestWord $Process $Base ($Wrapper + 0x44)))
        OpenArg4C = ('{0:X8}' -f (Read-GuestWord $Process $Base ($Wrapper + 0x4C)))
        Mode50 = ('{0:X8}' -f (Read-GuestWord $Process $Base ($Wrapper + 0x50)))
        Mode54 = ('{0:X8}' -f (Read-GuestWord $Process $Base ($Wrapper + 0x54)))
        Config58 = ('{0:X8}' -f (Read-GuestWord $Process $Base ($Wrapper + 0x58)))
        Owner5C = ('{0:X8}' -f (Read-GuestWord $Process $Base ($Wrapper + 0x5C)))
        Captured = $Captured
    }
}

function Get-StableSnapshot([IntPtr]$Process, [int64]$Base, [uint32]$Holder) {
    foreach ($attempt in 1..3) {
        $before = Get-ManagerCore $Process $Base $Holder
        $wrappers = @()
        $seen = @{}
        for ($index = 0; $index -lt $before.Active.Num; $index++) {
            $wrapper = Read-GuestWord $Process $Base ($before.Active.Data + 4 * $index)
            $seen[[uint32]$wrapper] = $true
            $captured = ($wrapper -eq $before.CaptureWrapper)
            $wrappers += Read-Wrapper $Process $Base $wrapper "$index" $captured
        }
        if ((Test-GuestPointer $before.CaptureWrapper) -and
            -not $seen.ContainsKey([uint32]$before.CaptureWrapper)) {
            $wrappers += Read-Wrapper $Process $Base $before.CaptureWrapper 'capture-only' $true
        }
        $after = Get-ManagerCore $Process $Base $Holder
        if ((Get-CoreSignature $before) -eq (Get-CoreSignature $after)) {
            return [pscustomobject]@{
                StableSnapshot = $true
                Attempt = $attempt
                Core = $after
                Wrappers = $wrappers
            }
        }
        Start-Sleep -Milliseconds 20
    }
    throw 'UI scene manager changed during all three snapshot attempts'
}

$ids = if ($TargetPid.Count -gt 0) {
    $TargetPid
} else {
    @(Get-Process -Name 'xenia_canary_netplay' -ErrorAction Stop | ForEach-Object Id)
}

foreach ($procId in $ids) {
    $target = Get-Process -Id $procId -ErrorAction Stop
    if ($target.ProcessName -notlike 'xenia_canary_netplay*') {
        throw "PID $procId is not a Xenia Canary netplay process"
    }
    $process = [AotUiRead]::OpenProcess($PROCESS_VM_READ, $false, $procId)
    if ($process -eq [IntPtr]::Zero) { throw "OpenProcess failed for PID $procId" }
    try {
        $bases = @()
        foreach ($power in 32..40) {
            $candidate = [int64][math]::Pow(2, $power)
            try {
                $mz = Read-GuestWord $process $candidate 0x82000000L
                if (($mz -band 0xFFFF0000) -eq 0x4D5A0000) {
                    $bases += $candidate
                }
            } catch { }
        }
        if ($bases.Count -ne 1) {
            throw "Expected exactly one guest memory base; found $($bases.Count)"
        }
        $base = $bases[0]
        $holder = Read-GuestWord $process $base 0x837DF4C0L
        if (-not (Test-GuestPointer $holder)) { throw 'Invalid UI manager pointer' }
        $snapshot = Get-StableSnapshot $process $base $holder
        [pscustomobject]@{
            Kind = 'Manager'
            PID = $procId
            GuestBase = ('0x{0:X}' -f $base)
            Holder = ('{0:X8}' -f $holder)
            ActiveData = ('{0:X8}' -f $snapshot.Core.Active.Data)
            ActiveNum = $snapshot.Core.Active.Num
            ActiveMax = $snapshot.Core.Active.Max
            OverallInputGate = ('{0:X8}' -f $snapshot.Core.OverallInputGate)
            CaptureWrapper = ('{0:X8}' -f $snapshot.Core.CaptureWrapper)
            CaptureConsume = $snapshot.Core.CaptureConsume
            StableSnapshot = $snapshot.StableSnapshot
            Attempt = $snapshot.Attempt
        }
        $snapshot.Wrappers
    } finally {
        [void][AotUiRead]::CloseHandle($process)
    }
}
