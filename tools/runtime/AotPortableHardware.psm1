Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:CpuSetNativeType = $null

function Get-AotCpuSetNativeType {
    if ($null -ne $script:CpuSetNativeType) {
        return $script:CpuSetNativeType
    }

    $assemblyName = [Reflection.AssemblyName]::new(
        'AotPortableCpuSets_' + [Guid]::NewGuid().ToString('N'))
    $domainFactory = [AppDomain]::CurrentDomain.GetType().GetMethod(
        'DefineDynamicAssembly', [Type[]]@(
            [Reflection.AssemblyName],
            [Reflection.Emit.AssemblyBuilderAccess]))
    if ($null -ne $domainFactory) {
        $assembly = $domainFactory.Invoke([AppDomain]::CurrentDomain, @(
            $assemblyName, [Reflection.Emit.AssemblyBuilderAccess]::Run))
    } else {
        $assembly = [Reflection.Emit.AssemblyBuilder]::DefineDynamicAssembly(
            $assemblyName, [Reflection.Emit.AssemblyBuilderAccess]::Run)
    }
    $module = $assembly.DefineDynamicModule($assemblyName.Name)
    $type = $module.DefineType('AotPortableCpuSetNative',
        [Reflection.TypeAttributes]'Public, Abstract, Sealed')
    $methodAttributes = [Reflection.MethodAttributes]::Public -bor
        [Reflection.MethodAttributes]::Static -bor
        [Reflection.MethodAttributes]::PinvokeImpl

    $cpuSetMethod = $type.DefinePInvokeMethod(
        'GetSystemCpuSetInformation', 'kernel32.dll', $methodAttributes,
        [Reflection.CallingConventions]::Standard, [bool],
        [Type[]]@([IntPtr], [uint32], [uint32].MakeByRefType(),
                  [IntPtr], [uint32]),
        [Runtime.InteropServices.CallingConvention]::Winapi,
        [Runtime.InteropServices.CharSet]::Unicode)
    $cpuSetMethod.SetImplementationFlags(
        $cpuSetMethod.GetMethodImplementationFlags() -bor
        [Reflection.MethodImplAttributes]::PreserveSig)

    $groupMethod = $type.DefinePInvokeMethod(
        'GetActiveProcessorGroupCount', 'kernel32.dll', $methodAttributes,
        [Reflection.CallingConventions]::Standard, [uint16], [Type[]]@(),
        [Runtime.InteropServices.CallingConvention]::Winapi,
        [Runtime.InteropServices.CharSet]::Unicode)
    $groupMethod.SetImplementationFlags(
        $groupMethod.GetMethodImplementationFlags() -bor
        [Reflection.MethodImplAttributes]::PreserveSig)

    $script:CpuSetNativeType = $type.CreateType()
    return $script:CpuSetNativeType
}

function Format-AotCpuMask {
    param([Parameter(Mandatory = $true)][uint64]$Value)
    $width = if ($Value -le [uint32]::MaxValue) { 8 } else { 16 }
    return $Value.ToString("X$width")
}

function ConvertTo-AotCpuMaskValue {
    param(
        [Parameter(Mandatory = $true)][object]$Value,
        [string]$Label = 'CPU mask',
        [switch]$AllowZero)
    $text = ([string]$Value).Trim() -replace '^(?i:0x)', ''
    if ($text -notmatch '^[0-9A-Fa-f]{1,16}$') {
        throw "$Label must be a hexadecimal processor mask up to 64 bits."
    }
    $number = [Convert]::ToUInt64($text, 16)
    if (-not $AllowZero -and $number -eq 0) {
        throw "$Label must be nonzero."
    }
    return $number
}

function Get-AotCpuTopology {
    [CmdletBinding()]
    param()

    if (-not [Environment]::Is64BitOperatingSystem -or
        -not [Environment]::Is64BitProcess) {
        throw 'CPU topology requires a 64-bit Windows process.'
    }
    $native = Get-AotCpuSetNativeType
    $groupCountMethod = $native.GetMethod('GetActiveProcessorGroupCount')
    $groupCount = [uint16]$groupCountMethod.Invoke($null, @())
    if ($groupCount -ne 1) {
        throw "The first portable alpha supports exactly one active processor group; found $groupCount."
    }

    $method = $native.GetMethod('GetSystemCpuSetInformation')
    [object[]]$probeArguments = @(
        [IntPtr]::Zero, [uint32]0, [uint32]0, [IntPtr]::Zero, [uint32]0)
    [void]$method.Invoke($null, $probeArguments)
    $needed = [uint32]$probeArguments[2]
    if ($needed -lt 32) {
        throw "Windows returned an invalid CPU-set buffer length: $needed"
    }

    $buffer = [Runtime.InteropServices.Marshal]::AllocHGlobal([int]$needed)
    try {
        [object[]]$arguments = @(
            $buffer, $needed, [uint32]0, [IntPtr]::Zero, [uint32]0)
        if (-not [bool]$method.Invoke($null, $arguments)) {
            throw 'GetSystemCpuSetInformation failed with a correctly sized buffer.'
        }
        $returned = [uint32]$arguments[2]
        if ($returned -gt $needed) {
            throw 'Windows returned more CPU-set data than the allocated buffer.'
        }
        $rows = [Collections.Generic.List[object]]::new()
        $offset = 0
        while ($offset -lt $returned) {
            $entry = [IntPtr]::Add($buffer, $offset)
            $size = [uint32][Runtime.InteropServices.Marshal]::ReadInt32($entry, 0)
            $type = [uint32][Runtime.InteropServices.Marshal]::ReadInt32($entry, 4)
            if ($size -lt 8 -or $offset + $size -gt $returned) {
                throw "Windows returned a malformed CPU-set entry at offset $offset."
            }
            if ($type -eq 0) {
                if ($size -lt 32) {
                    throw "Windows returned a short CPU-set record: $size bytes."
                }
                $rows.Add([pscustomobject][ordered]@{
                    Id = [uint32][Runtime.InteropServices.Marshal]::ReadInt32($entry, 8)
                    Group = [uint16][Runtime.InteropServices.Marshal]::ReadInt16($entry, 12)
                    LogicalProcessorIndex = [byte][Runtime.InteropServices.Marshal]::ReadByte($entry, 14)
                    CoreIndex = [byte][Runtime.InteropServices.Marshal]::ReadByte($entry, 15)
                    LastLevelCacheIndex = [byte][Runtime.InteropServices.Marshal]::ReadByte($entry, 16)
                    NumaNodeIndex = [byte][Runtime.InteropServices.Marshal]::ReadByte($entry, 17)
                    EfficiencyClass = [byte][Runtime.InteropServices.Marshal]::ReadByte($entry, 18)
                    Flags = [byte][Runtime.InteropServices.Marshal]::ReadByte($entry, 19)
                })
            }
            $offset += $size
        }
    } finally {
        [Runtime.InteropServices.Marshal]::FreeHGlobal($buffer)
    }

    $cpuSets = @($rows | Where-Object Group -eq 0 |
        Sort-Object LogicalProcessorIndex)
    if ($cpuSets.Count -eq 0 -or $cpuSets.Count -gt 64) {
        throw "The first portable alpha requires 1 through 64 Group-0 CPU sets; found $($cpuSets.Count)."
    }
    $logicalIndices = @($cpuSets | ForEach-Object LogicalProcessorIndex)
    if (@($logicalIndices | Sort-Object -Unique).Count -ne $cpuSets.Count -or
        ($logicalIndices | Measure-Object -Maximum).Maximum -ge 64) {
        throw 'Windows returned duplicate or out-of-range Group-0 logical indices.'
    }

    [uint64]$activeMask = 0
    foreach ($row in $cpuSets) {
        $activeMask = $activeMask -bor
            ([uint64]1 -shl [int]$row.LogicalProcessorIndex)
    }
    $canonical = @($cpuSets | ForEach-Object {
        '{0}:{1}:{2}:{3}:{4}' -f $_.Group, $_.LogicalProcessorIndex,
            $_.CoreIndex, $_.EfficiencyClass, $_.NumaNodeIndex
    }) -join ';'
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $signature = ([BitConverter]::ToString($sha.ComputeHash(
            [Text.Encoding]::UTF8.GetBytes($canonical)))) -replace '-', ''
    } finally {
        $sha.Dispose()
    }

    return [pscustomobject][ordered]@{
        SchemaVersion = 1
        GroupCount = $groupCount
        LogicalProcessorCount = $cpuSets.Count
        ActiveMask = Format-AotCpuMask $activeMask
        ActiveMaskValue = $activeMask
        Signature = $signature
        CpuSets = $cpuSets
    }
}

function Get-AotCpuAllocationPlan {
    [CmdletBinding()]
    param(
        [object]$Topology = $null,
        [object]$ReservedCpuMask = '0')

    if ($null -eq $Topology) { $Topology = Get-AotCpuTopology }
    [uint64]$reserved = ConvertTo-AotCpuMaskValue -Value $ReservedCpuMask `
        -Label 'ReservedCpuMask' -AllowZero
    [uint64]$active = [uint64]$Topology.ActiveMaskValue
    if (($reserved -band $active) -ne $reserved) {
        throw 'ReservedCpuMask contains a logical processor outside the active Group-0 mask.'
    }

    $cpuSets = @($Topology.CpuSets)
    if ($cpuSets.Count -eq 0) { throw 'CPU topology contains no CPU sets.' }
    $logicalIndices = @($cpuSets | ForEach-Object {
        [int]$_.LogicalProcessorIndex
    })
    if (@($logicalIndices | Sort-Object -Unique).Count -ne $cpuSets.Count -or
        @($logicalIndices | Where-Object { $_ -lt 0 -or $_ -ge 64 }).Count -ne 0 -or
        @($cpuSets | Where-Object { [int]$_.Group -ne 0 }).Count -ne 0) {
        throw 'CPU topology has duplicate, out-of-range, or non-Group-0 CPU sets.'
    }
    [uint64]$topologyMask = 0
    foreach ($logical in $logicalIndices) {
        $topologyMask = $topologyMask -bor ([uint64]1 -shl $logical)
    }
    if ($topologyMask -ne $active) {
        throw 'CPU topology rows do not match ActiveMaskValue.'
    }

    $allCores = @($cpuSets | Group-Object CoreIndex | ForEach-Object {
        $members = @($_.Group | Sort-Object LogicalProcessorIndex)
        if (@($members | ForEach-Object { [int]$_.EfficiencyClass } |
                Sort-Object -Unique).Count -ne 1) {
            throw "Core $($members[0].CoreIndex) has inconsistent efficiency classes."
        }
        [uint64]$mask = 0
        foreach ($member in $members) {
            $mask = $mask -bor
                ([uint64]1 -shl [int]$member.LogicalProcessorIndex)
        }
        [pscustomobject]@{
            CoreIndex = [int]$members[0].CoreIndex
            EfficiencyClass = [int]$members[0].EfficiencyClass
            Mask = $mask
            LogicalCount = $members.Count
        }
    } | Sort-Object EfficiencyClass, CoreIndex)
    foreach ($core in $allCores) {
        [uint64]$intersection = $core.Mask -band $reserved
        if ($intersection -ne 0 -and $intersection -ne $core.Mask) {
            throw "ReservedCpuMask splits SMT siblings on core $($core.CoreIndex)."
        }
    }
    $availableCores = @($allCores | Where-Object {
        ($_.Mask -band $reserved) -eq 0
    })
    $tiers = @($availableCores | Group-Object EfficiencyClass |
        Sort-Object { [int]$_.Name } -Descending)
    if ($tiers.Count -eq 0) {
        throw 'ReservedCpuMask leaves no cores for AoT.'
    }
    $daddyAssigned = [Collections.Generic.List[object]]::new()
    $cjAssigned = [Collections.Generic.List[object]]::new()
    foreach ($tier in $tiers) {
        $cores = @($tier.Group | Sort-Object CoreIndex)
        $baseCount = [int][Math]::Floor($cores.Count / 2)
        $daddyCount = $baseCount
        $cjCount = $baseCount
        if (($cores.Count % 2) -ne 0) {
            # Keep each tier contiguous, but alternate unavoidable singleton
            # cores toward the side with fewer cores assigned so far.
            if ($daddyAssigned.Count -le $cjAssigned.Count) {
                $daddyCount++
            } else {
                $cjCount++
            }
        }
        foreach ($core in @($cores | Select-Object -First $daddyCount)) {
            $daddyAssigned.Add($core)
        }
        foreach ($core in @($cores | Select-Object -Skip $daddyCount `
                -First $cjCount)) {
            $cjAssigned.Add($core)
        }
    }
    if ($daddyAssigned.Count -lt 3 -or $cjAssigned.Count -lt 3) {
        throw 'WholeCoreTierSplitV1 requires at least two game cores per side plus one service core per side.'
    }

    $serviceSort = @(
        @{ Expression = { [int]$_.EfficiencyClass }; Ascending = $true },
        @{ Expression = { [int]$_.CoreIndex }; Descending = $true })
    $serviceDaddyCore = @($daddyAssigned | Sort-Object -Property $serviceSort)[0]
    $serviceCjCore = @($cjAssigned | Sort-Object -Property $serviceSort)[0]
    [uint64]$serviceDaddy = [uint64]$serviceDaddyCore.Mask
    [uint64]$serviceCj = [uint64]$serviceCjCore.Mask
    [uint64]$daddy = 0
    [uint64]$cj = 0
    foreach ($core in @($daddyAssigned | Where-Object {
                $_.CoreIndex -ne $serviceDaddyCore.CoreIndex })) {
        $daddy = $daddy -bor [uint64]$core.Mask
    }
    foreach ($core in @($cjAssigned | Where-Object {
                $_.CoreIndex -ne $serviceCjCore.CoreIndex })) {
        $cj = $cj -bor [uint64]$core.Mask
    }
    [uint64]$xws = $serviceDaddy -bor $serviceCj
    [uint64]$fesl = $serviceDaddy
    if ($daddy -eq 0 -or $cj -eq 0 -or $xws -eq 0 -or $fesl -eq 0) {
        throw 'Whole-core allocation did not produce all four required masks.'
    }
    if (($daddy -band $cj) -ne 0 -or
        (($daddy -bor $cj) -band $xws) -ne 0 -or
        ($fesl -band $xws) -ne $fesl) {
        throw 'Whole-core allocation produced an invalid overlap contract.'
    }
    if (($daddy -bor $cj -bor $xws -bor $reserved) -ne $active) {
        throw 'Whole-core allocation does not account for every active logical processor.'
    }

    return [pscustomobject][ordered]@{
        SchemaVersion = 1
        Policy = 'WholeCoreTierSplitV1'
        TopologySignature = [string]$Topology.Signature
        ActiveCpuMask = Format-AotCpuMask $active
        ReservedCpuMask = Format-AotCpuMask $reserved
        DaddyCpuMask = Format-AotCpuMask $daddy
        CjCpuMask = Format-AotCpuMask $cj
        XwsCpuMask = Format-AotCpuMask $xws
        FeslCpuMask = Format-AotCpuMask $fesl
        Warning = if ($reserved -ne 0) {
            'Coexistence allocation is unvalidated; never reserve cores implicitly.'
        } else { '' }
    }
}

function ConvertFrom-AotControllerDevice {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$InstanceId,
        [string]$FriendlyName = '',
        [string]$Class = '')

    $eligibleName = $FriendlyName -match
        '(?i)(xinput compatible input device|hid-compliant game controller|xbox(?: 360| wireless)? controller)'
    $eligibleClass = $Class -in @('HIDClass', 'XnaComposite')
    if (-not $eligibleName -or -not $eligibleClass) { return $null }

    $match = [regex]::Match($InstanceId,
        '(?i)(?:^|[\\_])VID_(?<vid>[0-9A-F]{4}).*?PID_(?<pid>[0-9A-F]{4})')
    if (-not $match.Success) {
        $match = [regex]::Match($InstanceId,
            '(?i)DEV_VID&02(?<vid>[0-9A-F]{4})_PID&(?<pid>[0-9A-F]{4})')
    }
    if (-not $match.Success) { return $null }
    return ('0x{0}/0x{1}' -f
        $match.Groups['vid'].Value.ToUpperInvariant(),
        $match.Groups['pid'].Value.ToUpperInvariant())
}

function Get-AotControllerRoutes {
    [CmdletBinding()]
    param()

    $routes = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::OrdinalIgnoreCase)
    $getPnpDevice = Get-Command Get-PnpDevice -ErrorAction SilentlyContinue
    if ($null -eq $getPnpDevice) { return @() }
    foreach ($device in @(Get-PnpDevice -PresentOnly -ErrorAction Stop)) {
        $route = ConvertFrom-AotControllerDevice `
            -InstanceId ([string]$device.InstanceId) `
            -FriendlyName ([string]$device.FriendlyName) `
            -Class ([string]$device.Class)
        if (-not [string]::IsNullOrWhiteSpace($route)) {
            [void]$routes.Add($route)
        }
    }
    return @($routes | Sort-Object)
}

function Test-AotControllerRoutePresent {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Route)
    return $Route -in @(Get-AotControllerRoutes)
}

Export-ModuleMember -Function Get-AotCpuTopology, Get-AotCpuAllocationPlan,
    ConvertFrom-AotControllerDevice, Get-AotControllerRoutes,
    Test-AotControllerRoutePresent, ConvertTo-AotCpuMaskValue,
    Format-AotCpuMask
