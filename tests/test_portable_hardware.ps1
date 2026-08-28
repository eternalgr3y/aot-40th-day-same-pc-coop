[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$modulePath = Join-Path $root 'tools\runtime\AotPortableHardware.psm1'
Import-Module $modulePath -Force

function Assert-Equal {
    param([object]$Actual, [object]$Expected, [string]$Label)
    if ([string]$Actual -cne [string]$Expected) {
        throw "$Label mismatch: actual=[$Actual] expected=[$Expected]"
    }
}

function Assert-Rejected {
    param([scriptblock]$Action, [string]$Pattern, [string]$Label)
    $message = ''
    try { & $Action | Out-Null } catch { $message = $_.Exception.Message }
    if ($message -notmatch $Pattern) {
        throw "$Label was not rejected as expected: $message"
    }
}

$rows = [Collections.Generic.List[object]]::new()
for ($logical = 0; $logical -lt 16; $logical++) {
    $rows.Add([pscustomobject]@{
        Group = 0
        LogicalProcessorIndex = $logical
        CoreIndex = [int]([Math]::Floor($logical / 2) * 2)
        LastLevelCacheIndex = 0
        NumaNodeIndex = 0
        EfficiencyClass = 1
        Flags = 0
    })
}
for ($logical = 16; $logical -lt 28; $logical++) {
    $rows.Add([pscustomobject]@{
        Group = 0
        LogicalProcessorIndex = $logical
        CoreIndex = $logical
        LastLevelCacheIndex = 0
        NumaNodeIndex = 0
        EfficiencyClass = 0
        Flags = 0
    })
}
$topology = [pscustomobject]@{
    GroupCount = 1
    LogicalProcessorCount = 28
    ActiveMask = '0FFFFFFF'
    ActiveMaskValue = [uint64]0x0FFFFFFF
    Signature = ('A' * 64)
    CpuSets = @($rows)
}

$full = Get-AotCpuAllocationPlan -Topology $topology
Assert-Equal $full.Policy 'WholeCoreTierSplitV1' 'allocation policy'
Assert-Equal $full.DaddyCpuMask '001F00FF' '14700K Daddy mask'
Assert-Equal $full.CjCpuMask '07C0FF00' '14700K CJ mask'
Assert-Equal $full.XwsCpuMask '08200000' '14700K XWS mask'
Assert-Equal $full.FeslCpuMask '00200000' '14700K FESL mask'
Assert-Equal $full.ReservedCpuMask '00000000' '14700K reserved mask'

$coexistence = Get-AotCpuAllocationPlan -Topology $topology `
    -ReservedCpuMask '0000FFFF'
Assert-Equal $coexistence.DaddyCpuMask '001F0000' 'E-only Daddy mask'
Assert-Equal $coexistence.CjCpuMask '07C00000' 'E-only CJ mask'
if ([string]::IsNullOrWhiteSpace($coexistence.Warning)) {
    throw 'coexistence allocation lacks its unvalidated warning'
}

Assert-Rejected -Action {
    Get-AotCpuAllocationPlan -Topology $topology -ReservedCpuMask '00000001'
} -Pattern 'splits SMT siblings' -Label 'partial SMT reservation'
Assert-Rejected -Action {
    Get-AotCpuAllocationPlan -Topology $topology -ReservedCpuMask '10000000'
} -Pattern 'outside the active' -Label 'out-of-range reservation'

function New-HomogeneousTopology {
    param([int]$CoreCount)
    $fixtureRows = @(
        for ($logical = 0; $logical -lt $CoreCount; $logical++) {
            [pscustomobject]@{
                Group = 0
                LogicalProcessorIndex = $logical
                CoreIndex = $logical
                LastLevelCacheIndex = 0
                NumaNodeIndex = 0
                EfficiencyClass = 0
                Flags = 0
            }
        })
    [uint64]$mask = 0
    foreach ($logical in 0..($CoreCount - 1)) {
        $mask = $mask -bor ([uint64]1 -shl $logical)
    }
    return [pscustomobject]@{
        GroupCount = 1
        LogicalProcessorCount = $CoreCount
        ActiveMask = (Format-AotCpuMask $mask)
        ActiveMaskValue = $mask
        Signature = ('B' * 64)
        CpuSets = $fixtureRows
    }
}

Assert-Rejected -Action {
    Get-AotCpuAllocationPlan -Topology (New-HomogeneousTopology 4)
} -Pattern 'two game cores per side plus one service core' `
    -Label 'four-core minimum'
$sixCore = Get-AotCpuAllocationPlan -Topology (New-HomogeneousTopology 6)
Assert-Equal $sixCore.DaddyCpuMask '00000003' 'six-core Daddy minimum'
Assert-Equal $sixCore.CjCpuMask '00000018' 'six-core CJ minimum'
Assert-Equal $sixCore.XwsCpuMask '00000024' 'six-core service mask'
Assert-Equal $sixCore.FeslCpuMask '00000004' 'six-core FESL mask'

$singletonTopology = New-HomogeneousTopology 6
for ($index = 0; $index -lt $singletonTopology.CpuSets.Count; $index++) {
    $singletonTopology.CpuSets[$index].EfficiencyClass = $index
}
$singleton = Get-AotCpuAllocationPlan -Topology $singletonTopology
if ($singleton.DaddyCpuMask -eq '00000000' -or
    $singleton.CjCpuMask -eq '00000000') {
    throw 'singleton efficiency tiers did not balance across both rigs'
}

$sixtyFour = New-HomogeneousTopology 64
$sixtyFourPlan = Get-AotCpuAllocationPlan -Topology $sixtyFour
Assert-Equal $sixtyFour.ActiveMask 'FFFFFFFFFFFFFFFF' `
    '64-logical active mask'
if ($sixtyFourPlan.XwsCpuMask.Length -ne 16) {
    throw '64-logical service allocation lost its high-bit mask width'
}

$wired = ConvertFrom-AotControllerDevice `
    -InstanceId 'HID\VID_045E&PID_028E&IG_00\fixture' `
    -FriendlyName 'HID-compliant game controller' -Class HIDClass
$bluetooth = ConvertFrom-AotControllerDevice `
    -InstanceId 'BTHLEDEVICE\fixture_DEV_VID&02045E_PID&0B13_REV&0523\fixture' `
    -FriendlyName 'Bluetooth LE XINPUT compatible input device' -Class HIDClass
$falsePositive = ConvertFrom-AotControllerDevice `
    -InstanceId 'HID\VID_046D&PID_C54D&MI_01&COL03\fixture' `
    -FriendlyName 'HID-compliant system controller' -Class HIDClass
$genericBluetooth = ConvertFrom-AotControllerDevice `
    -InstanceId 'BTHLEDEVICE\fixture_DEV_VID&02045E_PID&0B13_REV&0523\fixture' `
    -FriendlyName 'Generic Access Profile' -Class Bluetooth
Assert-Equal $wired '0x045E/0x028E' 'wired controller route'
Assert-Equal $bluetooth '0x045E/0x0B13' 'Bluetooth controller route'
if ($null -ne $falsePositive -or $null -ne $genericBluetooth) {
    throw 'controller parser accepted a non-input PnP device'
}

Write-Host 'PASS: portable hardware allocator preserves whole cores, reproduces B19 masks, labels coexistence, bounds reservations, and parses USB/BTHLE pads strictly'
