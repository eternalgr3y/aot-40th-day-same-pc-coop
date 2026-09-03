Set-StrictMode -Version Latest

$script:AotPlanProperties = @(
    'SchemaVersion', 'Profile', 'Side', 'LaunchCapable',
    'LaunchCapability', 'RuntimeProof', 'ProfileTrust',
    'ProductionPinVerified', 'ProfileSha256', 'SourceCommit', 'SourceTree',
    'XeniaBytes', 'XeniaSha256', 'WorkingDirectory', 'FilePath', 'Affinity',
    'Priority', 'ArgumentList', 'ArgumentTokens', 'ArgumentListSha256',
    'TemplateSha256', 'ArgumentCount', 'OptionCount', 'PatchCount',
    'RuntimeGateStatus', 'PendingRuntimeGates', 'RuntimeGateCount',
    'Sa2AcceptanceMarkerStatus', 'RequiredSa2AcceptanceMarkers',
    'Sa2AcceptanceMarkerCount', 'GamePath', 'GameSha256',
    'GameHashVerified', 'SaveSlot', 'InstallRoot', 'CpuAllocationPolicy',
    'CpuTopologySignature', 'ReservedCpuMask', 'ProfileXuid', 'OnlineXuid',
    'MacAddress', 'OwnHostAddress', 'PeerHostAddress', 'PlayerPort',
    'Controller', 'InvertRightX')

$script:AotServiceProperties = @(
    'SchemaVersion', 'Role', 'SpecTrust', 'ProductionPinVerified',
    'FilePath', 'ExecutableBytes', 'ExecutableSha256', 'WorkingDirectory',
    'ArgumentList', 'ArgumentTokens', 'ArgumentListSha256', 'ArgumentCount',
    'PayloadPath', 'PayloadBytes', 'PayloadSha256', 'Affinity', 'Priority',
    'NoWindow')

$script:AotSpecFingerprintFields = @(
    'Contract', 'TrustMode', 'Role', 'ProcessClass', 'FilePath',
    'ImageBytes', 'ImageSha256', 'WorkingDirectory', 'ArgumentList',
    'ArgumentListSha256', 'Affinity', 'Priority', 'NoWindow', 'PayloadPath',
    'PayloadBytes', 'PayloadSha256', 'ReceiptSide', 'InstallRoot', 'GamePath',
    'GameSha256', 'ReservedCpuMask')

$script:AotAdapterMethodNames = @(
    'UtcNow', 'HashFile', 'FileLength', 'CreateSuspended', 'GetIdentity',
    'SetContract', 'Resume', 'CloseThreadHandle', 'CloseProcessHandle',
    'IsAlive', 'FindWindows', 'GetWindowProcessId', 'GetForegroundWindow',
    'PlaceHidden', 'RevealNoActivate', 'PlaceVisibleNoActivate',
    'RequestClose', 'WaitExit', 'Terminate', 'CommitLedger')

$script:AotContextAdapterAnchors =
    New-Object 'Collections.Generic.Dictionary[string,object]' `
        ([StringComparer]::Ordinal)

$script:AotProductionPins = [pscustomobject][ordered]@{
    ProfileSha256 = '87987BECC70800C3D7CA3434E7BE15365A8E3053185E04121AE38525BFA5E891'
    SourceCommit = 'b8c0c49520e841a97309e7c742570c0a8769c4f6'
    SourceTree = '1194169c7723b1bbf314105c5255a7ea2e2e7c97'
    XeniaBytes = [int64]17942016
    XeniaSha256 = 'E0AE2C785BC19637E83019FE921E0D3CEE83B229D1CDF9B82F6508A50336C629'
    GameSha256 = '7C2008F53D4569D4079311B36CF2555E5FDC26B48A2C2E3578580B9F07EC16EF'
    DaddyTemplateSha256 = 'FCDFFB2CB25300BF32D19AE64DB62A7343FF330EA4FFF9A22390AA8B7738FB2E'
    CjTemplateSha256 = 'FCDFFB2CB25300BF32D19AE64DB62A7343FF330EA4FFF9A22390AA8B7738FB2E'
}

$script:AotRuntimeGates = @(
    'ZERO_LIVE_XENIA_PROCESSES_BEFORE_STAGING',
    'VERIFIED_SAVE_BACKUP_COMPLETED_BEFORE_ACCEPTANCE_RUN_PREP',
    'ISOLATED_RIG_ROOTS_CREATED_WITHOUT_OVERWRITE',
    'DADDY_SLOT_1_OCCUPIED_AND_CJ_SLOT_2_VERIFIED_EMPTY',
    'LIVE_CPU_TOPOLOGY_MATCHES_DECLARED_SIGNATURE',
    'RIG_XCONFIG_IDENTITIES_MATCH_DECLARED_VALUES',
    'TWO_PHYSICAL_PADS_PRESENT_AND_ISOLATED',
    'XWS_WHOAMI_IS_NONZERO_AND_BACKEND_IS_HEALTHY_BEFORE_JOIN',
    'SA2_BOTH_SIDES_EMIT_EXACTLY_ONE_MANAGER_ARM_MARKER',
    'SA2_ONE_SIDE_PROVES_GENERATION_BOUND_PREPARE_ARM_CONSUME_ACK_CHAIN',
    'EXTERNAL_TIMEOUT_AND_CLEANUP_ARE_ENFORCED',
    'NATIVE_JOIN_REACHES_ONE_SHARED_SESSION',
    'PHYSICAL_PAD_GAMEPLAY_IS_STABLE_FOR_THREE_MINUTES',
    'DEATH_CHECKPOINT_RELOAD_COMPLETES_WITHOUT_BACKEND_DISCONNECT')

$script:AotSa2Markers = @(
    [pscustomobject][ordered]@{
        Stage = 1
        Event = 'PRECONNECT_XSA1_PREPARED_FOR_GUEST'
        Format = '[AOT-RUNTIME-SA2][ACCEPT] seq=<seq> generation=<generation> stage=1 event=PRECONNECT_XSA1_PREPARED_FOR_GUEST'
    },
    [pscustomobject][ordered]@{
        Stage = 2
        Event = 'XNETCONNECT_MANAGER_ARMED'
        Format = '[AOT-RUNTIME-SA2][ACCEPT] seq=<seq> generation=<generation> stage=2 event=XNETCONNECT_MANAGER_ARMED'
    },
    [pscustomobject][ordered]@{
        Stage = 3
        Event = 'POSTCONNECT_XSA1_RETRANSMIT_CONSUMED_ACK_SENT'
        Format = '[AOT-RUNTIME-SA2][ACCEPT] seq=<seq> generation=<generation> stage=3 event=POSTCONNECT_XSA1_RETRANSMIT_CONSUMED_ACK_SENT'
    })

function Get-AotSha256Text {
    param([Parameter(Mandatory = $true)][string]$Text)

    $algorithm = [Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes($Text)
        return ([BitConverter]::ToString(
                $algorithm.ComputeHash($bytes))).Replace('-', '')
    } finally {
        $algorithm.Dispose()
    }
}

function Get-AotSpecFingerprint {
    param([Parameter(Mandatory = $true)][object]$Spec)

    $builder = New-Object Text.StringBuilder
    foreach ($field in $script:AotSpecFingerprintFields) {
        $property = $Spec.PSObject.Properties[$field]
        if ($null -eq $property) {
            throw "Normalized process spec is missing fingerprint field $field."
        }
        $value = $property.Value
        $typeTag = if ($null -eq $value) {
            'N'
        } elseif ($value -is [bool]) {
            'B'
        } elseif ($value -is [byte] -or $value -is [uint16] -or
            $value -is [uint32] -or $value -is [uint64] -or
            $value -is [sbyte] -or $value -is [int16] -or
            $value -is [int32] -or $value -is [int64]) {
            'I'
        } elseif ($value -is [string]) {
            'S'
        } else {
            throw "Normalized process spec field $field has an unsupported type."
        }
        $text = if ($null -eq $value) {
            ''
        } elseif ($value -is [bool]) {
            if ([bool]$value) { 'true' } else { 'false' }
        } elseif ($typeTag -ceq 'I') {
            ([decimal]$value).ToString(
                [Globalization.CultureInfo]::InvariantCulture)
        } else {
            [string]$value
        }
        $line = '{0}:{1}={2}:{3}:{4}' -f $field.Length, $field,
            $typeTag, $text.Length, $text
        [void]$builder.Append($line).Append("`n")
    }
    return Get-AotSha256Text -Text $builder.ToString()
}

function Add-AotSpecFingerprint {
    param([Parameter(Mandatory = $true)][object]$Spec)

    $fingerprint = Get-AotSpecFingerprint -Spec $Spec
    $Spec | Add-Member -NotePropertyName SpecFingerprintSha256 `
        -NotePropertyValue $fingerprint
    return $Spec
}

function Assert-AotExactProperties {
    param(
        [Parameter(Mandatory = $true)][object]$InputObject,
        [Parameter(Mandatory = $true)][string[]]$Expected,
        [Parameter(Mandatory = $true)][string]$Label
    )

    if ($null -eq $InputObject) {
        throw "$Label is null."
    }
    $actual = @($InputObject.PSObject.Properties | ForEach-Object {
            [string]$_.Name
        })
    if ($actual.Count -ne $Expected.Count) {
        throw "$Label must contain exactly $($Expected.Count) properties."
    }
    $expectedSet = New-Object 'Collections.Generic.HashSet[string]' `
        ([StringComparer]::Ordinal)
    foreach ($name in $Expected) {
        [void]$expectedSet.Add($name)
    }
    foreach ($name in $actual) {
        if (-not $expectedSet.Remove($name)) {
            throw "$Label contains an unknown or incorrectly-cased property: $name"
        }
    }
    if ($expectedSet.Count -ne 0) {
        throw "$Label is missing required properties."
    }
}

function Assert-AotExactSequence {
    param(
        [AllowNull()][object]$Actual,
        [Parameter(Mandatory = $true)][object[]]$Expected,
        [Parameter(Mandatory = $true)][string]$Label
    )

    $items = @($Actual)
    if ($items.Count -ne $Expected.Count) {
        throw "$Label must contain exactly $($Expected.Count) ordered values."
    }
    for ($index = 0; $index -lt $Expected.Count; $index++) {
        if ([string]$items[$index] -cne [string]$Expected[$index]) {
            throw "$Label differs at index $index."
        }
    }
}

function Assert-AotCanonicalHash {
    param(
        [AllowNull()][object]$Value,
        [Parameter(Mandatory = $true)][string]$Label
    )

    if (-not ($Value -is [string]) -or
        [string]$Value -cnotmatch '^[0-9A-F]{64}$') {
        throw "$Label must be an uppercase SHA-256 value."
    }
    return [string]$Value
}

function Assert-AotPositiveInteger {
    param(
        [AllowNull()][object]$Value,
        [Parameter(Mandatory = $true)][string]$Label,
        [switch]$AllowZero
    )

    if ($Value -isnot [byte] -and $Value -isnot [uint16] -and
        $Value -isnot [uint32] -and $Value -isnot [uint64] -and
        $Value -isnot [sbyte] -and $Value -isnot [int16] -and
        $Value -isnot [int32] -and $Value -isnot [int64]) {
        throw "$Label must be an integer."
    }
    $number = [decimal]$Value
    if (($AllowZero -and $number -lt 0) -or
        (-not $AllowZero -and $number -le 0)) {
        throw "$Label is outside its allowed range."
    }
    return $number
}

function Get-AotCanonicalPath {
    param(
        [AllowNull()][object]$Value,
        [Parameter(Mandatory = $true)][string]$Label,
        [switch]$Directory
    )

    if (-not ($Value -is [string]) -or [string]::IsNullOrWhiteSpace($Value) -or
        [string]$Value -match '[\x00"]') {
        throw "$Label must be a nonempty shell-free path."
    }
    $originalPath = [string]$Value
    $isFullyQualified = if ([Environment]::OSVersion.Platform -eq
        [PlatformID]::Win32NT) {
        $originalPath -match '^(?i:[A-Z]):[\\/]' -or
            $originalPath -match '^[\\/]{2}[^\\/]+[\\/][^\\/]+'
    } else {
        $originalPath.StartsWith('/')
    }
    if (-not $isFullyQualified -or
        -not [IO.Path]::IsPathRooted($originalPath)) {
        throw "$Label must be absolute before normalization."
    }
    try {
        $path = [IO.Path]::GetFullPath($originalPath)
    } catch {
        throw "$Label is not a canonicalizable path."
    }
    if (-not [IO.Path]::IsPathRooted($path)) {
        throw "$Label must be absolute."
    }
    if ($Directory) {
        $root = [IO.Path]::GetPathRoot($path)
        if (-not [string]::Equals($path, $root,
                [StringComparison]::OrdinalIgnoreCase)) {
            $path = $path.TrimEnd('\', '/')
        }
    }
    return $path
}

function Assert-AotPathHasNoReparsePoint {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Label
    )

    $fullPath = [IO.Path]::GetFullPath($Path)
    $volumeRoot = [IO.Path]::GetPathRoot($fullPath)
    if ([string]::IsNullOrWhiteSpace($volumeRoot)) {
        throw "$Label has no volume root."
    }
    $relative = $fullPath.Substring($volumeRoot.Length)
    $parts = @($relative.Split(@('\', '/'),
            [StringSplitOptions]::RemoveEmptyEntries))
    $current = $volumeRoot
    foreach ($part in $parts) {
        $current = Join-Path $current $part
        if (-not [IO.File]::Exists($current) -and
            -not [IO.Directory]::Exists($current)) {
            throw "$Label contains a missing path component: $current"
        }
        $attributes = [IO.File]::GetAttributes($current)
        if (($attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "$Label contains a reparse point: $current"
        }
    }
}

function Get-AotTrustedSyntheticRoot {
    $localApplicationData = [Environment]::GetFolderPath(
        [Environment+SpecialFolder]::LocalApplicationData)
    if ([string]::IsNullOrWhiteSpace($localApplicationData)) {
        throw 'The LocalApplicationData known folder is unavailable.'
    }
    $localRoot = Get-AotCanonicalPath -Value $localApplicationData `
        -Label 'LocalApplicationData known folder' -Directory
    $volumeRoot = [IO.Path]::GetPathRoot($localRoot)
    if ([string]::Equals($localRoot, $volumeRoot,
            [StringComparison]::OrdinalIgnoreCase)) {
        throw 'LocalApplicationData may not resolve to a volume root.'
    }
    $trustedRoot = Get-AotCanonicalPath `
        -Value (Join-Path $localRoot 'Temp') `
        -Label 'trusted synthetic root' -Directory
    if ([string]::Equals($trustedRoot, $volumeRoot,
            [StringComparison]::OrdinalIgnoreCase) -or
        -not [IO.Directory]::Exists($trustedRoot)) {
        throw 'The trusted LocalApplicationData Temp directory is unavailable.'
    }
    Assert-AotPathHasNoReparsePoint -Path $trustedRoot `
        -Label 'trusted synthetic root'
    return $trustedRoot
}

function Assert-AotTrustedSyntheticPath {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Label
    )

    $trustedRoot = Get-AotTrustedSyntheticRoot
    $fullPath = [IO.Path]::GetFullPath($Path)
    $prefix = $trustedRoot + [IO.Path]::DirectorySeparatorChar
    if (-not $fullPath.StartsWith($prefix,
            [StringComparison]::OrdinalIgnoreCase)) {
        throw "$Label must remain beneath the trusted synthetic root."
    }
    Assert-AotPathHasNoReparsePoint -Path $fullPath -Label $Label
}

function ConvertTo-AotAffinity {
    param(
        [AllowNull()][object]$Value,
        [Parameter(Mandatory = $true)][string]$Label,
        [switch]$AllowZero
    )

    if (-not ($Value -is [string]) -or
        [string]$Value -cnotmatch '^[0-9A-F]{8,16}$') {
        throw "$Label must be 8 to 16 uppercase hexadecimal digits."
    }
    try {
        $number = [Convert]::ToUInt64([string]$Value, 16)
    } catch {
        throw "$Label is outside the UInt64 affinity range."
    }
    if (-not $AllowZero -and $number -eq 0) {
        throw "$Label may not be zero."
    }
    return [pscustomobject]@{
        Text = [string]$Value
        Value = $number
    }
}

function Assert-AotArgumentContract {
    param(
        [Parameter(Mandatory = $true)][object]$Object,
        [Parameter(Mandatory = $true)][string]$Label
    )

    if (-not ($Object.ArgumentList -is [string]) -or
        [string]$Object.ArgumentList -match '\x00|[\r\n]') {
        throw "$Label.ArgumentList must be a single direct argument tail."
    }
    $tokens = @($Object.ArgumentTokens)
    if ($tokens.Count -eq 0) {
        throw "$Label.ArgumentTokens may not be empty."
    }
    foreach ($token in $tokens) {
        if (-not ($token -is [string]) -or [string]$token -match '\x00|[\r\n]') {
            throw "$Label.ArgumentTokens contains an invalid token."
        }
    }
    $argumentCount = Assert-AotPositiveInteger -Value $Object.ArgumentCount `
        -Label "$Label.ArgumentCount"
    if ($argumentCount -ne $tokens.Count) {
        throw "$Label.ArgumentCount does not match ArgumentTokens."
    }
    if (($tokens -join ' ') -cne [string]$Object.ArgumentList) {
        throw "$Label.ArgumentList is not the exact ordered token join."
    }
    $expectedHash = Assert-AotCanonicalHash -Value $Object.ArgumentListSha256 `
        -Label "$Label.ArgumentListSha256"
    if ((Get-AotSha256Text -Text ([string]$Object.ArgumentList)) -cne
        $expectedHash) {
        throw "$Label.ArgumentListSha256 does not match ArgumentList."
    }
}

function Assert-AotPlanReceipt {
    param(
        [Parameter(Mandatory = $true)][object]$Receipt,
        [Parameter(Mandatory = $true)][ValidateSet('Daddy', 'Cj')]
        [string]$ExpectedSide,
        [switch]$SyntheticFixture
    )

    $label = "$ExpectedSide planner receipt"
    Assert-AotExactProperties -InputObject $Receipt `
        -Expected $script:AotPlanProperties -Label $label
    if ($Receipt.SchemaVersion -isnot [int32] -or
        [int]$Receipt.SchemaVersion -ne 1) {
        throw "$label.SchemaVersion must be integer 1."
    }
    if (-not ($Receipt.Side -is [string]) -or
        [string]$Receipt.Side -cne $ExpectedSide) {
        throw "$label.Side is not exact."
    }
    if (-not ($Receipt.Profile -is [string]) -or
        [string]$Receipt.Profile -cne 'B19-Runtime-Core-Acceptance') {
        throw "$label.Profile is not the reviewed runtime-core profile."
    }
    if ($Receipt.LaunchCapable -isnot [bool] -or
        [bool]$Receipt.LaunchCapable -or
        $Receipt.LaunchCapability -isnot [string] -or
        [string]$Receipt.LaunchCapability -cne 'NONE_OFFLINE_PLAN_ONLY') {
        throw "$label lost the offline-planner capability boundary."
    }
    if ($SyntheticFixture) {
        if ($Receipt.RuntimeProof -isnot [string] -or
            [string]$Receipt.RuntimeProof -cne
                'SYNTHETIC FIXTURE - NO CANDIDATE RUNTIME PROOF' -or
            $Receipt.ProfileTrust -isnot [string] -or
            [string]$Receipt.ProfileTrust -cne
                'UNTRUSTED_SYNTHETIC_TEST_ONLY' -or
            $Receipt.ProductionPinVerified -isnot [bool] -or
            [bool]$Receipt.ProductionPinVerified) {
            throw "$label is not an explicit synthetic fixture receipt."
        }
    } else {
        if ($Receipt.RuntimeProof -isnot [string] -or
            [string]$Receipt.RuntimeProof -cne
                'SOURCE-BUILT CANDIDATE - RUNTIME ACCEPTANCE PENDING' -or
            $Receipt.ProfileTrust -isnot [string] -or
            [string]$Receipt.ProfileTrust -cne 'PRODUCTION_REVIEWED_PROFILE' -or
            $Receipt.ProductionPinVerified -isnot [bool] -or
            -not [bool]$Receipt.ProductionPinVerified) {
            throw "$label is not a production-pinned planner receipt."
        }
    }

    foreach ($field in 'ProfileSha256', 'XeniaSha256', 'TemplateSha256',
            'GameSha256', 'CpuTopologySignature') {
        [void](Assert-AotCanonicalHash -Value $Receipt.$field `
            -Label "$label.$field")
    }
    foreach ($field in 'SourceCommit', 'SourceTree') {
        if ($Receipt.$field -isnot [string] -or
            [string]$Receipt.$field -cnotmatch '^[0-9a-f]{40}$') {
            throw "$label.$field must be canonical lowercase Git object id."
        }
    }
    if (-not $SyntheticFixture) {
        $expectedTemplateHash = if ($ExpectedSide -ceq 'Daddy') {
            [string]$script:AotProductionPins.DaddyTemplateSha256
        } else {
            [string]$script:AotProductionPins.CjTemplateSha256
        }
        if ([string]$Receipt.ProfileSha256 -cne
                [string]$script:AotProductionPins.ProfileSha256 -or
            [string]$Receipt.SourceCommit -cne
                [string]$script:AotProductionPins.SourceCommit -or
            [string]$Receipt.SourceTree -cne
                [string]$script:AotProductionPins.SourceTree -or
            [int64]$Receipt.XeniaBytes -ne
                [int64]$script:AotProductionPins.XeniaBytes -or
            [string]$Receipt.XeniaSha256 -cne
                [string]$script:AotProductionPins.XeniaSha256 -or
            [string]$Receipt.GameSha256 -cne
                [string]$script:AotProductionPins.GameSha256 -or
            [string]$Receipt.TemplateSha256 -cne $expectedTemplateHash) {
            throw "$label differs from the exact reviewed production pins."
        }
    }
    [void](Assert-AotPositiveInteger -Value $Receipt.XeniaBytes `
        -Label "$label.XeniaBytes")
    foreach ($field in 'OptionCount', 'PatchCount') {
        [void](Assert-AotPositiveInteger -Value $Receipt.$field `
            -Label "$label.$field" -AllowZero)
    }
    if ([int]$Receipt.PatchCount -ne 3) {
        throw "$label.PatchCount must remain exactly three."
    }
    Assert-AotArgumentContract -Object $Receipt -Label $label

    $workingDirectory = Get-AotCanonicalPath -Value $Receipt.WorkingDirectory `
        -Label "$label.WorkingDirectory" -Directory
    $filePath = Get-AotCanonicalPath -Value $Receipt.FilePath `
        -Label "$label.FilePath"
    $fileParent = Get-AotCanonicalPath -Value `
        ([IO.Path]::GetDirectoryName($filePath)) -Label "$label.FilePath parent" `
        -Directory
    if (-not [string]::Equals($fileParent, $workingDirectory,
            [StringComparison]::OrdinalIgnoreCase)) {
        throw "$label.FilePath must be directly inside WorkingDirectory."
    }
    if ([IO.Path]::GetFileName($filePath) -cnotmatch
        '^xenia[A-Za-z0-9._-]{0,95}\.exe$') {
        throw "$label.FilePath must name the planner-reviewed xenia*.exe form."
    }
    $gamePath = Get-AotCanonicalPath -Value $Receipt.GamePath `
        -Label "$label.GamePath"
    $gameTokenMatches = 0
    foreach ($argumentToken in @($Receipt.ArgumentTokens)) {
        $candidate = [string]$argumentToken
        if ($candidate.Length -ge 2 -and
            $candidate[0] -eq '"' -and
            $candidate[$candidate.Length - 1] -eq '"') {
            $candidate = $candidate.Substring(1, $candidate.Length - 2)
        }
        try {
            $candidatePath = [IO.Path]::GetFullPath($candidate)
            if ([string]::Equals($candidatePath, $gamePath,
                    [StringComparison]::OrdinalIgnoreCase)) {
                $gameTokenMatches++
            }
        } catch {}
    }
    if ($gameTokenMatches -ne 1) {
        throw "$label must bind GamePath in exactly one direct argument token."
    }
    $installRoot = Get-AotCanonicalPath -Value $Receipt.InstallRoot `
        -Label "$label.InstallRoot" -Directory
    $rigRoot = Get-AotCanonicalPath -Value (Join-Path $installRoot 'rigs') `
        -Label "$label rig root" -Directory
    $workingParent = Get-AotCanonicalPath -Value `
        ([IO.Path]::GetDirectoryName($workingDirectory)) `
        -Label "$label.WorkingDirectory parent" -Directory
    if (-not [string]::Equals($workingParent, $rigRoot,
            [StringComparison]::OrdinalIgnoreCase)) {
        throw "$label.WorkingDirectory must be a direct InstallRoot\rigs child."
    }
    $affinity = ConvertTo-AotAffinity -Value $Receipt.Affinity `
        -Label "$label.Affinity"
    $reservedAffinity = ConvertTo-AotAffinity -Value $Receipt.ReservedCpuMask `
        -Label "$label.ReservedCpuMask" -AllowZero
    if ($SyntheticFixture) {
        Assert-AotTrustedSyntheticPath -Path $workingDirectory `
            -Label "$label.WorkingDirectory"
        Assert-AotTrustedSyntheticPath -Path $filePath `
            -Label "$label.FilePath"
        Assert-AotTrustedSyntheticPath -Path $gamePath `
            -Label "$label.GamePath"
        Assert-AotTrustedSyntheticPath -Path $installRoot `
            -Label "$label.InstallRoot"
    }
    if ($Receipt.Priority -isnot [string] -or
        [string]$Receipt.Priority -cne 'High') {
        throw "$label.Priority must be exact High."
    }
    if ($Receipt.RuntimeGateStatus -isnot [string] -or
        [string]$Receipt.RuntimeGateStatus -cne 'PENDING_NOT_EXECUTED' -or
        $Receipt.Sa2AcceptanceMarkerStatus -isnot [string] -or
        [string]$Receipt.Sa2AcceptanceMarkerStatus -cne
            'PENDING_NOT_EXECUTED') {
        throw "$label may only carry unexecuted runtime gates."
    }
    Assert-AotExactSequence -Actual $Receipt.PendingRuntimeGates `
        -Expected $script:AotRuntimeGates -Label "$label.PendingRuntimeGates"
    if ($Receipt.RuntimeGateCount -isnot [int32] -or
        [int]$Receipt.RuntimeGateCount -ne $script:AotRuntimeGates.Count) {
        throw "$label.RuntimeGateCount is not exact."
    }
    $markers = @($Receipt.RequiredSa2AcceptanceMarkers)
    if ($markers.Count -ne $script:AotSa2Markers.Count -or
        $Receipt.Sa2AcceptanceMarkerCount -isnot [int32] -or
        [int]$Receipt.Sa2AcceptanceMarkerCount -ne $script:AotSa2Markers.Count) {
        throw "$label must carry exactly three SA2 acceptance markers."
    }
    for ($index = 0; $index -lt $script:AotSa2Markers.Count; $index++) {
        $marker = $markers[$index]
        $expectedMarker = $script:AotSa2Markers[$index]
        Assert-AotExactProperties -InputObject $marker `
            -Expected @('Stage', 'Event', 'Format') `
            -Label "$label marker $index"
        if ($marker.Stage -isnot [int32] -or
            [int]$marker.Stage -ne [int]$expectedMarker.Stage -or
            $marker.Event -isnot [string] -or
            [string]$marker.Event -cne [string]$expectedMarker.Event -or
            $marker.Format -isnot [string] -or
            [string]$marker.Format -cne [string]$expectedMarker.Format) {
            throw "$label marker $index differs from the reviewed contract."
        }
    }
    if ($Receipt.GameHashVerified -isnot [bool] -or
        -not [bool]$Receipt.GameHashVerified) {
        throw "$label.GameHashVerified must be true."
    }
    if ($Receipt.SaveSlot -isnot [int32] -or [int]$Receipt.SaveSlot -ne 1) {
        throw "$label.SaveSlot must remain exactly 1."
    }
    if ($Receipt.CpuAllocationPolicy -isnot [string] -or
        [string]$Receipt.CpuAllocationPolicy -cne 'WholeCoreTierSplitV1') {
        throw "$label.CpuAllocationPolicy is not reviewed."
    }
    foreach ($field in 'ProfileXuid', 'OnlineXuid', 'MacAddress',
            'OwnHostAddress', 'PeerHostAddress', 'Controller') {
        if ($Receipt.$field -isnot [string]) {
            throw "$label.$field must be a string."
        }
    }
    if ([string]$Receipt.ProfileXuid -cnotmatch '^E000[0-9A-F]{12}$' -or
        [string]$Receipt.OnlineXuid -cnotmatch '^0009[0-9A-F]{12}$' -or
        [string]$Receipt.MacAddress -cnotmatch '^7C1E52[0-9A-F]{6}$' -or
        [string]$Receipt.Controller -cnotmatch '^0x[0-9A-F]{4}/0x[0-9A-F]{4}$') {
        throw "$label carries a noncanonical persisted identity."
    }
    if (([string]$Receipt.ProfileXuid).Substring(8, 8) -cne
        ([string]$Receipt.MacAddress).Substring(4, 8)) {
        throw "$label offline XUID and MAC suffixes differ."
    }
    $macTail = ([string]$Receipt.MacAddress).Substring(6, 6)
    $expectedHostAddress = '127.{0}.{1}.{2}' -f
        [Convert]::ToByte($macTail.Substring(0, 2), 16),
        [Convert]::ToByte($macTail.Substring(2, 2), 16),
        [Convert]::ToByte($macTail.Substring(4, 2), 16)
    $ipAddress = $null
    if (-not [Net.IPAddress]::TryParse([string]$Receipt.OwnHostAddress,
            [ref]$ipAddress) -or
        [string]$Receipt.OwnHostAddress -cne $expectedHostAddress -or
        [string]$Receipt.OwnHostAddress -in '127.0.0.0', '127.0.0.1') {
        throw "$label.OwnHostAddress must equal its MAC-derived loopback."
    }
    $ipAddress = $null
    if (-not [Net.IPAddress]::TryParse([string]$Receipt.PeerHostAddress,
            [ref]$ipAddress) -or
        -not [string]$Receipt.PeerHostAddress.StartsWith('127.')) {
        throw "$label.PeerHostAddress must be loopback."
    }
    [void](Assert-AotPositiveInteger -Value $Receipt.PlayerPort `
        -Label "$label.PlayerPort")
    if ([decimal]$Receipt.PlayerPort -gt 65535) {
        throw "$label.PlayerPort is outside the TCP/UDP port range."
    }
    $expectedPlayerPort = 36001 +
        ([Convert]::ToUInt64([string]$Receipt.MacAddress, 16) -band 0x3FF)
    if ([uint64]$Receipt.PlayerPort -ne [uint64]$expectedPlayerPort) {
        throw "$label.PlayerPort is not its MAC-derived port."
    }
    if ($Receipt.InvertRightX -isnot [bool]) {
        throw "$label.InvertRightX must be Boolean."
    }
    $expectedArguments = New-Object 'Collections.Generic.List[string]'
    foreach ($token in '--portable=true', '--hid=sdl',
            ("--hid_sdl_allowed_devices={0}" -f
                [string]$Receipt.Controller)) {
        $expectedArguments.Add($token)
    }
    if ([bool]$Receipt.InvertRightX) {
        $expectedArguments.Add('--hid_sdl_invert_right_x=true')
    }
    foreach ($token in
            ("--logged_profile_slot_0_xuid={0}" -f
                [string]$Receipt.ProfileXuid),
            '--network_mode=2', '--upnp=false',
            '--network_synthetic_loopback=true',
            '--api_address=http://127.0.0.1:36000/',
            ("--aot_runtime_peer_ipv4={0}" -f
                [string]$Receipt.PeerHostAddress),
            '--aot_runtime_sa2=true',
            '--aot_runtime_leg_destination_repair=true',
            '--aot_runtime_xport_control_load_repair=true',
            '--apply_patches=true', '--auto_check_updates=false',
            '--log_level=2') {
        $expectedArguments.Add($token)
    }
    $gameArgument = if ($gamePath -match '\s') {
        '"' + $gamePath + '"'
    } else {
        $gamePath
    }
    $expectedArguments.Add($gameArgument)
    Assert-AotExactSequence -Actual $Receipt.ArgumentTokens `
        -Expected $expectedArguments.ToArray() `
        -Label "$label.ArgumentTokens"
    if ([int]$Receipt.ArgumentCount -ne $expectedArguments.Count -or
        [int]$Receipt.OptionCount -ne ($expectedArguments.Count - 1)) {
        throw "$label argument/option counts differ from the reviewed template."
    }

    $spec = [pscustomobject][ordered]@{
        Contract = 'AOT_OWNED_PROCESS_SPEC_V1'
        TrustMode = if ($SyntheticFixture) {
            'SYNTHETIC_TEST_ONLY'
        } else {
            'PRODUCTION_PINNED'
        }
        Role = $ExpectedSide
        ProcessClass = 'Xenia'
        FilePath = $filePath
        ImageBytes = [int64]$Receipt.XeniaBytes
        ImageSha256 = [string]$Receipt.XeniaSha256
        WorkingDirectory = $workingDirectory
        ArgumentList = [string]$Receipt.ArgumentList
        ArgumentListSha256 = [string]$Receipt.ArgumentListSha256
        Affinity = [string]$affinity.Text
        Priority = 'High'
        NoWindow = $false
        PayloadPath = $null
        PayloadBytes = [int64]0
        PayloadSha256 = $null
        ReceiptSide = $ExpectedSide
        InstallRoot = $installRoot
        GamePath = $gamePath
        GameSha256 = [string]$Receipt.GameSha256
        ReservedCpuMask = [string]$reservedAffinity.Text
    }
    return Add-AotSpecFingerprint -Spec $spec
}

function Assert-AotOwnedPlanPair {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$Daddy,
        [Parameter(Mandatory = $true)][object]$Cj,
        [switch]$SyntheticFixture
    )

    $daddySpec = Assert-AotPlanReceipt -Receipt $Daddy -ExpectedSide Daddy `
        -SyntheticFixture:$SyntheticFixture
    $cjSpec = Assert-AotPlanReceipt -Receipt $Cj -ExpectedSide Cj `
        -SyntheticFixture:$SyntheticFixture

    foreach ($field in 'Profile', 'ProfileSha256', 'SourceCommit', 'SourceTree',
            'XeniaBytes', 'XeniaSha256', 'GamePath', 'GameSha256',
            'InstallRoot', 'CpuAllocationPolicy', 'CpuTopologySignature',
            'ReservedCpuMask', 'SaveSlot', 'RuntimeGateCount',
            'Sa2AcceptanceMarkerCount') {
        if ([string]$Daddy.$field -cne [string]$Cj.$field) {
            throw "Planner pair differs at shared field $field."
        }
    }
    if ([string]$Daddy.OwnHostAddress -cne [string]$Cj.PeerHostAddress -or
        [string]$Cj.OwnHostAddress -cne [string]$Daddy.PeerHostAddress) {
        throw 'Planner pair host addresses are not reciprocal.'
    }
    foreach ($field in 'ProfileXuid', 'OnlineXuid', 'MacAddress',
            'OwnHostAddress', 'PlayerPort', 'Controller', 'WorkingDirectory',
            'FilePath') {
        if ([string]$Daddy.$field -ceq [string]$Cj.$field) {
            throw "Planner pair must differ at side field $field."
        }
    }
    $daddyMask = ConvertTo-AotAffinity -Value $Daddy.Affinity `
        -Label 'Daddy planner receipt.Affinity'
    $cjMask = ConvertTo-AotAffinity -Value $Cj.Affinity `
        -Label 'Cj planner receipt.Affinity'
    if (($daddyMask.Value -band $cjMask.Value) -ne 0) {
        throw 'Planner pair Xenia affinity masks overlap.'
    }
    $reservedMask = ConvertTo-AotAffinity -Value $Daddy.ReservedCpuMask `
        -Label 'planner pair.ReservedCpuMask' -AllowZero
    if (($reservedMask.Value -band $daddyMask.Value) -ne 0 -or
        ($reservedMask.Value -band $cjMask.Value) -ne 0) {
        throw 'Planner pair reserved CPU mask overlaps a Xenia mask.'
    }

    $specs = New-Object 'Collections.Generic.Dictionary[string,object]' `
        ([StringComparer]::Ordinal)
    $specs.Add('Daddy', $daddySpec)
    $specs.Add('Cj', $cjSpec)
    $pairFingerprint = Get-AotSha256Text -Text (
        'Daddy=' + [string]$daddySpec.SpecFingerprintSha256 + "`n" +
        'Cj=' + [string]$cjSpec.SpecFingerprintSha256 + "`n")
    return [pscustomobject][ordered]@{
        Contract = 'AOT_OWNED_PLAN_PAIR_V1'
        TrustMode = if ($SyntheticFixture) {
            'SYNTHETIC_TEST_ONLY'
        } else {
            'PRODUCTION_PINNED'
        }
        SyntheticFixture = [bool]$SyntheticFixture
        PlanFingerprintSha256 = $pairFingerprint
        Specs = $specs
    }
}

function Assert-AotOwnedServiceSpecs {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object[]]$ServiceSpec,
        [switch]$SyntheticFixture
    )

    $items = @($ServiceSpec)
    if ($items.Count -ne 2) {
        throw 'ServiceSpec must contain exactly XWS and FESL.'
    }
    $specs = New-Object 'Collections.Generic.Dictionary[string,object]' `
        ([StringComparer]::Ordinal)
    foreach ($item in $items) {
        Assert-AotExactProperties -InputObject $item `
            -Expected $script:AotServiceProperties -Label 'service spec'
        if ($item.SchemaVersion -isnot [int32] -or
            [int]$item.SchemaVersion -ne 1 -or
            $item.Role -isnot [string] -or
            ([string]$item.Role -cne 'XWS' -and
                [string]$item.Role -cne 'FESL')) {
            throw 'Service spec role/schema is not exact XWS/FESL v1.'
        }
        $role = [string]$item.Role
        if ($specs.ContainsKey($role)) {
            throw "Service spec contains duplicate role $role."
        }
        if ($SyntheticFixture) {
            if ($item.SpecTrust -isnot [string] -or
                [string]$item.SpecTrust -cne 'UNTRUSTED_SYNTHETIC_TEST_ONLY' -or
                $item.ProductionPinVerified -isnot [bool] -or
                [bool]$item.ProductionPinVerified) {
                throw "$role service spec is not explicitly synthetic."
            }
        } else {
            throw ('PRODUCTION_SERVICE_AUTHORITY_DEFERRED: a self-asserted ' +
                'ProductionPinVerified service spec is not launch authority; ' +
                'the future wrapper must bind a reviewed pinned service manifest.')
        }
        $filePath = Get-AotCanonicalPath -Value $item.FilePath `
            -Label "$role service spec.FilePath"
        $workingDirectory = Get-AotCanonicalPath -Value $item.WorkingDirectory `
            -Label "$role service spec.WorkingDirectory" -Directory
        $payloadPath = Get-AotCanonicalPath -Value $item.PayloadPath `
            -Label "$role service spec.PayloadPath"
        Assert-AotArgumentContract -Object $item -Label "$role service spec"
        $payloadParent = Get-AotCanonicalPath -Value `
            ([IO.Path]::GetDirectoryName($payloadPath)) `
            -Label "$role service spec.PayloadPath parent" -Directory
        if (-not [string]::Equals($payloadParent, $workingDirectory,
                [StringComparison]::OrdinalIgnoreCase)) {
            throw "$role payload must be directly inside WorkingDirectory."
        }
        $payloadToken = [string](@($item.ArgumentTokens)[0])
        if ($payloadToken.Length -ge 2 -and $payloadToken[0] -eq '"' -and
            $payloadToken[$payloadToken.Length - 1] -eq '"') {
            $payloadToken = $payloadToken.Substring(1,
                $payloadToken.Length - 2)
        }
        $payloadTokenPath = $null
        try {
            $payloadTokenPath = [IO.Path]::GetFullPath($payloadToken)
        } catch {
            throw "$role first direct argument is not its payload path."
        }
        if (-not [string]::Equals($payloadTokenPath, $payloadPath,
                [StringComparison]::OrdinalIgnoreCase)) {
            throw "$role first direct argument is not its payload path."
        }
        if ($SyntheticFixture) {
            Assert-AotTrustedSyntheticPath -Path $filePath `
                -Label "$role service spec.FilePath"
            Assert-AotTrustedSyntheticPath -Path $workingDirectory `
                -Label "$role service spec.WorkingDirectory"
            Assert-AotTrustedSyntheticPath -Path $payloadPath `
                -Label "$role service spec.PayloadPath"
        }
        [void](Assert-AotPositiveInteger -Value $item.ExecutableBytes `
            -Label "$role service spec.ExecutableBytes")
        [void](Assert-AotPositiveInteger -Value $item.PayloadBytes `
            -Label "$role service spec.PayloadBytes")
        $imageHash = Assert-AotCanonicalHash -Value $item.ExecutableSha256 `
            -Label "$role service spec.ExecutableSha256"
        $payloadHash = Assert-AotCanonicalHash -Value $item.PayloadSha256 `
            -Label "$role service spec.PayloadSha256"
        $affinity = ConvertTo-AotAffinity -Value $item.Affinity `
            -Label "$role service spec.Affinity"
        if ($item.Priority -isnot [string] -or
            [string]$item.Priority -cne 'High' -or
            $item.NoWindow -isnot [bool] -or
            -not [bool]$item.NoWindow) {
            throw "$role service spec must be hidden and High priority."
        }
        $normalizedSpec = [pscustomobject][ordered]@{
                Contract = 'AOT_OWNED_PROCESS_SPEC_V1'
                TrustMode = if ($SyntheticFixture) {
                    'SYNTHETIC_TEST_ONLY'
                } else {
                    'PRODUCTION_PINNED'
                }
                Role = $role
                ProcessClass = 'Service'
                FilePath = $filePath
                ImageBytes = [int64]$item.ExecutableBytes
                ImageSha256 = $imageHash
                WorkingDirectory = $workingDirectory
                ArgumentList = [string]$item.ArgumentList
                ArgumentListSha256 = [string]$item.ArgumentListSha256
                Affinity = [string]$affinity.Text
                Priority = 'High'
                NoWindow = $true
                PayloadPath = $payloadPath
                PayloadBytes = [int64]$item.PayloadBytes
                PayloadSha256 = $payloadHash
                ReceiptSide = $null
                InstallRoot = $null
                GamePath = $null
                GameSha256 = $null
                ReservedCpuMask = $null
            }
        $specs.Add($role, (Add-AotSpecFingerprint -Spec $normalizedSpec))
    }
    foreach ($requiredRole in 'XWS', 'FESL') {
        if (-not $specs.ContainsKey($requiredRole)) {
            throw "ServiceSpec is missing exact role $requiredRole."
        }
    }
    $setFingerprint = Get-AotSha256Text -Text (
        'XWS=' + [string]$specs['XWS'].SpecFingerprintSha256 + "`n" +
        'FESL=' + [string]$specs['FESL'].SpecFingerprintSha256 + "`n")
    return [pscustomobject][ordered]@{
        Contract = 'AOT_OWNED_SERVICE_SET_V1'
        TrustMode = if ($SyntheticFixture) {
            'SYNTHETIC_TEST_ONLY'
        } else {
            'PRODUCTION_PINNED'
        }
        SyntheticFixture = [bool]$SyntheticFixture
        ServiceSetFingerprintSha256 = $setFingerprint
        Specs = $specs
    }
}

function Initialize-AotOwnedNativeType {
    if ($null -ne ('AotOwnedProcessNativeV1' -as [type])) {
        return
    }

    $source = @'
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;

public sealed class AotOwnedCreatedProcessV1 {
    public IntPtr ProcessHandle;
    public IntPtr ThreadHandle;
    public uint ProcessId;
}

public sealed class AotOwnedIdentityV1 {
    public uint ProcessId;
    public ulong CreationFileTime;
    public string StartTimeUtc;
    public string ImagePath;
}

public sealed class AotOwnedContractV1 {
    public ulong Affinity;
    public uint PriorityClass;
}

public static class AotOwnedProcessNativeV1 {
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct STARTUPINFO {
        public uint cb;
        public string lpReserved;
        public string lpDesktop;
        public string lpTitle;
        public uint dwX;
        public uint dwY;
        public uint dwXSize;
        public uint dwYSize;
        public uint dwXCountChars;
        public uint dwYCountChars;
        public uint dwFillAttribute;
        public uint dwFlags;
        public short wShowWindow;
        public short cbReserved2;
        public IntPtr lpReserved2;
        public IntPtr hStdInput;
        public IntPtr hStdOutput;
        public IntPtr hStdError;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct PROCESS_INFORMATION {
        public IntPtr hProcess;
        public IntPtr hThread;
        public uint dwProcessId;
        public uint dwThreadId;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct FILETIME {
        public uint dwLowDateTime;
        public uint dwHighDateTime;
    }

    public struct AotRectV1 {
        public int X;
        public int Y;
        public int Width;
        public int Height;
    }

    private const uint CREATE_SUSPENDED = 0x00000004;
    private const uint CREATE_NEW_PROCESS_GROUP = 0x00000200;
    private const uint CREATE_UNICODE_ENVIRONMENT = 0x00000400;
    private const uint CREATE_NO_WINDOW = 0x08000000;
    private const uint STARTF_USESHOWWINDOW = 0x00000001;
    private const short SW_HIDE = 0;
    private const int SW_SHOWNOACTIVATE = 4;
    private const uint HIGH_PRIORITY_CLASS = 0x00000080;
    private const uint WAIT_OBJECT_0 = 0x00000000;
    private const uint WAIT_TIMEOUT = 0x00000102;
    private const uint WAIT_FAILED = 0xFFFFFFFF;
    private const uint GW_OWNER = 4;
    private const uint WM_CLOSE = 0x0010;
    private const uint SWP_NOZORDER = 0x0004;
    private const uint SWP_NOACTIVATE = 0x0010;
    private const uint SWP_SHOWWINDOW = 0x0040;
    private const uint MOVEFILE_REPLACE_EXISTING = 0x00000001;
    private const uint MOVEFILE_WRITE_THROUGH = 0x00000008;

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool CreateProcessW(
        string applicationName, StringBuilder commandLine,
        IntPtr processAttributes, IntPtr threadAttributes,
        bool inheritHandles, uint creationFlags, IntPtr environment,
        string currentDirectory, ref STARTUPINFO startupInfo,
        out PROCESS_INFORMATION processInformation);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern uint GetProcessId(IntPtr process);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool GetProcessTimes(IntPtr process,
        out FILETIME creation, out FILETIME exit, out FILETIME kernel,
        out FILETIME user);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool QueryFullProcessImageNameW(IntPtr process,
        uint flags, StringBuilder executableName, ref uint size);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool SetProcessAffinityMask(IntPtr process,
        UIntPtr mask);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool GetProcessAffinityMask(IntPtr process,
        out UIntPtr processMask, out UIntPtr systemMask);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool SetPriorityClass(IntPtr process,
        uint priorityClass);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern uint GetPriorityClass(IntPtr process);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern uint ResumeThread(IntPtr thread);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern uint WaitForSingleObject(IntPtr handle,
        uint milliseconds);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool TerminateProcess(IntPtr process,
        uint exitCode);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool CloseHandle(IntPtr handle);

    private delegate bool EnumWindowsProc(IntPtr window, IntPtr parameter);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool EnumWindows(EnumWindowsProc callback,
        IntPtr parameter);

    [DllImport("user32.dll")]
    private static extern IntPtr GetWindow(IntPtr window, uint command);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern uint GetWindowThreadProcessId(IntPtr window,
        out uint processId);

    [DllImport("user32.dll")]
    private static extern IntPtr GetForegroundWindow();

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool SetWindowPos(IntPtr window,
        IntPtr insertAfter, int x, int y, int width, int height, uint flags);

    [DllImport("user32.dll")]
    private static extern bool ShowWindow(IntPtr window, int command);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool PostMessageW(IntPtr window, uint message,
        IntPtr wParam, IntPtr lParam);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool MoveFileExW(string existingFileName,
        string newFileName, uint flags);

    private static Win32Exception Error(string operation) {
        return new Win32Exception(Marshal.GetLastWin32Error(), operation);
    }

    public static AotOwnedCreatedProcessV1 CreateSuspended(
        string filePath, string argumentList, string workingDirectory,
        bool noWindow) {
        if (filePath.IndexOf('\0') >= 0 || filePath.IndexOf('"') >= 0 ||
            argumentList.IndexOf('\0') >= 0 || argumentList.IndexOf('\r') >= 0 ||
            argumentList.IndexOf('\n') >= 0) {
            throw new ArgumentException("Invalid direct process arguments.");
        }
        string text = "\"" + filePath + "\"";
        if (argumentList.Length != 0) text += " " + argumentList;
        if (text.Length > 32766) {
            throw new ArgumentException("Windows command line exceeds 32767 characters.");
        }
        STARTUPINFO startup = new STARTUPINFO();
        startup.cb = (uint)Marshal.SizeOf(typeof(STARTUPINFO));
        startup.dwFlags = STARTF_USESHOWWINDOW;
        startup.wShowWindow = SW_HIDE;
        PROCESS_INFORMATION created;
        uint flags = CREATE_SUSPENDED | CREATE_NEW_PROCESS_GROUP |
            CREATE_UNICODE_ENVIRONMENT;
        if (noWindow) flags |= CREATE_NO_WINDOW;
        if (!CreateProcessW(filePath, new StringBuilder(text), IntPtr.Zero,
                IntPtr.Zero, false, flags, IntPtr.Zero, workingDirectory,
                ref startup, out created)) {
            throw Error("CreateProcessW failed");
        }
        AotOwnedCreatedProcessV1 result = new AotOwnedCreatedProcessV1();
        result.ProcessHandle = created.hProcess;
        result.ThreadHandle = created.hThread;
        result.ProcessId = created.dwProcessId;
        return result;
    }

    public static AotOwnedIdentityV1 GetIdentity(IntPtr process,
        uint expectedProcessId) {
        uint actualProcessId = GetProcessId(process);
        if (actualProcessId == 0) throw Error("GetProcessId failed");
        FILETIME creation, exit, kernel, user;
        if (!GetProcessTimes(process, out creation, out exit,
                out kernel, out user)) {
            throw Error("GetProcessTimes failed");
        }
        StringBuilder image = new StringBuilder(32768);
        uint length = (uint)image.Capacity;
        if (!QueryFullProcessImageNameW(process, 0, image, ref length)) {
            throw Error("QueryFullProcessImageNameW failed");
        }
        ulong fileTime = ((ulong)creation.dwHighDateTime << 32) |
            creation.dwLowDateTime;
        AotOwnedIdentityV1 result = new AotOwnedIdentityV1();
        result.ProcessId = actualProcessId;
        result.CreationFileTime = fileTime;
        result.StartTimeUtc = DateTime.FromFileTimeUtc((long)fileTime)
            .ToString("o");
        result.ImagePath = image.ToString();
        if (actualProcessId != expectedProcessId) {
            throw new InvalidOperationException("Retained handle PID mismatch.");
        }
        return result;
    }

    public static AotOwnedContractV1 SetContract(IntPtr process,
        ulong affinity, string priority) {
        if (priority != "High") {
            throw new ArgumentException("Only exact High priority is supported.");
        }
        UIntPtr mask = new UIntPtr(affinity);
        if (!SetProcessAffinityMask(process, mask)) {
            throw Error("SetProcessAffinityMask failed");
        }
        if (!SetPriorityClass(process, HIGH_PRIORITY_CLASS)) {
            throw Error("SetPriorityClass failed");
        }
        UIntPtr actualMask, systemMask;
        if (!GetProcessAffinityMask(process, out actualMask, out systemMask)) {
            throw Error("GetProcessAffinityMask failed");
        }
        uint priorityClass = GetPriorityClass(process);
        if (priorityClass == 0) throw Error("GetPriorityClass failed");
        AotOwnedContractV1 result = new AotOwnedContractV1();
        result.Affinity = actualMask.ToUInt64();
        result.PriorityClass = priorityClass;
        return result;
    }

    public static uint Resume(IntPtr thread) {
        uint result = ResumeThread(thread);
        if (result == 0xFFFFFFFF) throw Error("ResumeThread failed");
        return result;
    }

    public static bool IsAlive(IntPtr process) {
        uint result = WaitForSingleObject(process, 0);
        if (result == WAIT_TIMEOUT) return true;
        if (result == WAIT_OBJECT_0) return false;
        if (result == WAIT_FAILED) throw Error("WaitForSingleObject failed");
        throw new InvalidOperationException("Unexpected process wait result.");
    }

    public static bool WaitExit(IntPtr process, uint milliseconds) {
        uint result = WaitForSingleObject(process, milliseconds);
        if (result == WAIT_OBJECT_0) return true;
        if (result == WAIT_TIMEOUT) return false;
        if (result == WAIT_FAILED) throw Error("WaitForSingleObject failed");
        throw new InvalidOperationException("Unexpected process wait result.");
    }

    public static void Terminate(IntPtr process, uint exitCode) {
        if (!TerminateProcess(process, exitCode)) {
            throw Error("TerminateProcess failed");
        }
    }

    public static void CloseHandleChecked(IntPtr handle) {
        if (handle != IntPtr.Zero && !CloseHandle(handle)) {
            throw Error("CloseHandle failed");
        }
    }

    public static IntPtr[] FindTopLevelWindows(uint processId) {
        List<IntPtr> result = new List<IntPtr>();
        EnumWindowsProc callback = delegate(IntPtr window, IntPtr parameter) {
            uint ownerProcessId;
            GetWindowThreadProcessId(window, out ownerProcessId);
            if (ownerProcessId == processId &&
                GetWindow(window, GW_OWNER) == IntPtr.Zero) {
                result.Add(window);
            }
            return true;
        };
        if (!EnumWindows(callback, IntPtr.Zero)) {
            throw Error("EnumWindows failed");
        }
        return result.ToArray();
    }

    public static uint GetWindowProcessId(IntPtr window) {
        uint processId;
        if (GetWindowThreadProcessId(window, out processId) == 0) {
            throw Error("GetWindowThreadProcessId failed");
        }
        return processId;
    }

    public static IntPtr ForegroundWindow() {
        return GetForegroundWindow();
    }

    public static void PlaceHidden(IntPtr window, int x, int y,
        int width, int height) {
        if (!SetWindowPos(window, IntPtr.Zero, x, y, width, height,
                SWP_NOZORDER | SWP_NOACTIVATE)) {
            throw Error("SetWindowPos hidden placement failed");
        }
    }

    public static void RevealNoActivate(IntPtr window) {
        ShowWindow(window, SW_SHOWNOACTIVATE);
    }

    public static void PlaceVisibleNoActivate(IntPtr window, int x, int y,
        int width, int height) {
        if (!SetWindowPos(window, IntPtr.Zero, x, y, width, height,
                SWP_NOZORDER | SWP_NOACTIVATE | SWP_SHOWWINDOW)) {
            throw Error("SetWindowPos visible placement failed");
        }
    }

    public static void RequestClose(IntPtr window) {
        if (!PostMessageW(window, WM_CLOSE, IntPtr.Zero, IntPtr.Zero)) {
            throw Error("PostMessageW WM_CLOSE failed");
        }
    }

    public static void CommitUtf8(string destination, string text,
        string token) {
        string temporary = destination + "." + token + ".tmp";
        byte[] bytes = new UTF8Encoding(false).GetBytes(text);
        try {
            using (FileStream stream = new FileStream(temporary,
                    FileMode.CreateNew, FileAccess.Write, FileShare.None,
                    4096, FileOptions.WriteThrough)) {
                stream.Write(bytes, 0, bytes.Length);
                stream.Flush(true);
            }
            if (!MoveFileExW(temporary, destination,
                    MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH)) {
                throw Error("Atomic ledger replacement failed");
            }
        } finally {
            if (File.Exists(temporary)) File.Delete(temporary);
        }
    }
}
'@
    Add-Type -TypeDefinition $source -Language CSharp
}

function New-AotOwnedProductionAdapter {
    [CmdletBinding()]
    param()

    $blocked = {
        throw 'PRODUCTION_LAUNCH_CLOSURE_DEFERRED'
    }
    $properties = [ordered]@{
        Kind = 'WindowsNativeV1'
        IsSynthetic = $false
        State = $null
    }
    foreach ($methodName in $script:AotAdapterMethodNames) {
        $properties[$methodName] = $blocked
    }
    return [pscustomobject]$properties
}

function Assert-AotAdapter {
    param(
        [Parameter(Mandatory = $true)][object]$Adapter,
        [switch]$SyntheticFixture
    )

    if ($Adapter.IsSynthetic -isnot [bool]) {
        throw 'Owned-process adapter must declare Boolean IsSynthetic.'
    }
    if ($SyntheticFixture) {
        if (-not [bool]$Adapter.IsSynthetic -or
            $Adapter.Kind -isnot [string] -or
            [string]$Adapter.Kind -cne 'SyntheticV1') {
            throw 'SyntheticFixture requires the exact SyntheticV1 adapter.'
        }
    } else {
        if ([bool]$Adapter.IsSynthetic -or
            $Adapter.Kind -isnot [string] -or
            [string]$Adapter.Kind -cne 'WindowsNativeV1') {
            throw 'Production execution requires the exact WindowsNativeV1 adapter.'
        }
        if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT -or
            [IntPtr]::Size -ne 8) {
            throw 'Production owned-process execution requires 64-bit Windows.'
        }
    }
    foreach ($methodName in $script:AotAdapterMethodNames) {
        $property = $Adapter.PSObject.Properties[$methodName]
        if ($null -eq $property -or $property.Value -isnot [scriptblock]) {
            throw "Owned-process adapter lacks scriptblock method $methodName."
        }
    }
}

function Invoke-AotAdapter {
    param(
        [Parameter(Mandatory = $true)][object]$Adapter,
        [Parameter(Mandatory = $true)][string]$Method,
        [object[]]$ArgumentList = @()
    )

    $block = $Adapter.PSObject.Properties[$Method].Value
    return & $block $Adapter @ArgumentList
}

function Add-AotContextAdapterAnchor {
    param(
        [Parameter(Mandatory = $true)][object]$Context,
        [Parameter(Mandatory = $true)][object]$Adapter,
        [Parameter(Mandatory = $true)][string]$AnchorId
    )

    Assert-AotAdapter -Adapter $Adapter -SyntheticFixture
    if ($script:AotContextAdapterAnchors.ContainsKey($AnchorId)) {
        throw 'ADAPTER_ANCHOR_COLLISION'
    }
    $methods = New-Object 'Collections.Generic.Dictionary[string,object]' `
        ([StringComparer]::Ordinal)
    foreach ($methodName in $script:AotAdapterMethodNames) {
        $methods.Add($methodName,
            $Adapter.PSObject.Properties[$methodName].Value)
    }
    $stateProperty = $Adapter.PSObject.Properties['State']
    $anchor = [pscustomobject][ordered]@{
        Context = $Context
        Adapter = $Adapter
        MethodAnchors = $methods
        HasState = $null -ne $stateProperty
        State = if ($null -eq $stateProperty) {
            $null
        } else {
            $stateProperty.Value
        }
    }
    $script:AotContextAdapterAnchors.Add($AnchorId, $anchor)
}

function Get-AotBoundContextAdapter {
    param([Parameter(Mandatory = $true)][object]$Context)

    $anchorProperty = $Context.PSObject.Properties['AdapterAnchorId']
    $adapterProperty = $Context.PSObject.Properties['Adapter']
    if ($null -eq $anchorProperty -or $anchorProperty.Value -isnot [string] -or
        [string]::IsNullOrWhiteSpace([string]$anchorProperty.Value) -or
        $null -eq $adapterProperty) {
        throw 'ADAPTER_BINDING_MISMATCH: context adapter anchor is absent.'
    }
    $anchorId = [string]$anchorProperty.Value
    if (-not $script:AotContextAdapterAnchors.ContainsKey($anchorId)) {
        throw 'ADAPTER_BINDING_MISMATCH: context adapter anchor is unknown.'
    }
    $anchor = $script:AotContextAdapterAnchors[$anchorId]
    if (-not [object]::ReferenceEquals($Context, $anchor.Context) -or
        -not [object]::ReferenceEquals($adapterProperty.Value,
            $anchor.Adapter)) {
        throw 'ADAPTER_BINDING_MISMATCH: context adapter was replaced.'
    }
    try {
        Assert-AotAdapter -Adapter $adapterProperty.Value -SyntheticFixture
    } catch {
        throw ('ADAPTER_BINDING_MISMATCH: ' + $_.Exception.Message)
    }
    $stateProperty = $adapterProperty.Value.PSObject.Properties['State']
    if ([bool]$anchor.HasState -ne ($null -ne $stateProperty) -or
        ([bool]$anchor.HasState -and
            -not [object]::ReferenceEquals($stateProperty.Value,
                $anchor.State))) {
        throw 'ADAPTER_BINDING_MISMATCH: synthetic adapter state was replaced.'
    }
    foreach ($methodName in $script:AotAdapterMethodNames) {
        $current = $adapterProperty.Value.PSObject.Properties[$methodName].Value
        if (-not [object]::ReferenceEquals($current,
                $anchor.MethodAnchors[$methodName])) {
            throw "ADAPTER_BINDING_MISMATCH: adapter method $methodName was replaced."
        }
    }
    return $anchor.Adapter
}

function Invoke-AotContextAdapter {
    param(
        [Parameter(Mandatory = $true)][object]$Context,
        [Parameter(Mandatory = $true)][string]$Method,
        [object[]]$ArgumentList = @()
    )

    $adapter = Get-AotBoundContextAdapter -Context $Context
    return Invoke-AotAdapter -Adapter $adapter -Method $Method `
        -ArgumentList $ArgumentList
}

function New-AotOwnedRunToken {
    [CmdletBinding()]
    param()

    $bytes = New-Object byte[] 16
    $generator = [Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        $generator.GetBytes($bytes)
    } finally {
        $generator.Dispose()
    }
    $bytes[6] = ($bytes[6] -band 0x0F) -bor 0x40
    $bytes[8] = ($bytes[8] -band 0x3F) -bor 0x80
    return ([BitConverter]::ToString($bytes)).Replace('-', '')
}

function Get-AotLedgerProjection {
    param([Parameter(Mandatory = $true)][object]$Context)

    $entries = @($Context.Entries.Values | Sort-Object LaunchOrdinal |
        ForEach-Object {
            [pscustomobject][ordered]@{
                RunToken = [string]$_.RunToken
                TrustMode = [string]$_.TrustMode
                LaunchOrdinal = [int]$_.LaunchOrdinal
                Role = [string]$_.Role
                ProcessClass = [string]$_.ProcessClass
                Pid = [uint32]$_.Pid
                CreationFileTime = [string]$_.CreationFileTime
                StartTimeUtc = [string]$_.StartTimeUtc
                FilePath = [string]$_.FilePath
                ImageBytes = [int64]$_.ImageBytes
                ImageSha256 = [string]$_.ImageSha256
                ArgumentListSha256 = [string]$_.ArgumentListSha256
                SpecFingerprintSha256 = [string]$_.SpecFingerprintSha256
                Affinity = [string]$_.Affinity
                Priority = [string]$_.Priority
                State = [string]$_.State
                ContractAssertions = [int]$_.ContractAssertions
                LastObservedUtc = [string]$_.LastObservedUtc
                StopResult = [string]$_.StopResult
                ErrorCode = [string]$_.ErrorCode
                HandleClosed = [bool]$_.HandleClosed
            }
        })
    return [pscustomobject][ordered]@{
        SchemaVersion = 1
        RunToken = [string]$Context.RunToken
        TrustMode = [string]$Context.TrustMode
        PlanFingerprintSha256 = [string]$Context.PlanFingerprintSha256
        ServiceSetFingerprintSha256 = `
            [string]$Context.ServiceSetFingerprintSha256
        CreatedUtc = [string]$Context.CreatedUtc
        Status = [string]$Context.Status
        Entries = $entries
    }
}

function Save-AotOwnedLedger {
    param([Parameter(Mandatory = $true)][object]$Context)

    if ([bool]$Context.SyntheticFixture) {
        Assert-AotTrustedSyntheticPath -Path ([string]$Context.RunDirectory) `
            -Label 'SyntheticFixture run directory'
        $ledgerParent = Get-AotCanonicalPath -Value `
            ([IO.Path]::GetDirectoryName([string]$Context.LedgerPath)) `
            -Label 'SyntheticFixture ledger parent' -Directory
        if (-not [string]::Equals($ledgerParent,
                [string]$Context.RunDirectory,
                [StringComparison]::OrdinalIgnoreCase)) {
            throw 'SyntheticFixture ledger escaped its run directory.'
        }
    }
    $projection = Get-AotLedgerProjection -Context $Context
    $json = $projection | ConvertTo-Json -Depth 6 -Compress
    [void](Invoke-AotContextAdapter -Context $Context `
        -Method CommitLedger -ArgumentList @(
            [string]$Context.LedgerPath, [string]$json,
            [string]$Context.RunToken))
}

function New-AotOwnedRunContext {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$RunRoot,
        [Parameter(Mandatory = $true)][object]$PlanPair,
        [Parameter(Mandatory = $true)][object]$ServiceSpecs,
        [Parameter(Mandatory = $true)][object]$Adapter,
        [switch]$SyntheticFixture
    )

    if ($PlanPair.Contract -cne 'AOT_OWNED_PLAN_PAIR_V1' -or
        $ServiceSpecs.Contract -cne 'AOT_OWNED_SERVICE_SET_V1') {
        throw 'Run context requires validated v1 plan and service contracts.'
    }
    if ([bool]$PlanPair.SyntheticFixture -ne [bool]$SyntheticFixture -or
        [bool]$ServiceSpecs.SyntheticFixture -ne [bool]$SyntheticFixture) {
        throw 'Run context fixture mode differs from its validated inputs.'
    }
    $expectedTrust = if ($SyntheticFixture) {
        'SYNTHETIC_TEST_ONLY'
    } else {
        'PRODUCTION_PINNED'
    }
    if ([string]$PlanPair.TrustMode -cne $expectedTrust -or
        [string]$ServiceSpecs.TrustMode -cne $expectedTrust) {
        throw 'Run context trust mode differs from its validated inputs.'
    }
    if (-not $SyntheticFixture) {
        throw ('PRODUCTION_LAUNCH_CLOSURE_DEFERRED: production ownership ' +
            'requires retained deny-write executable, game, and exact ' +
            'three-patch handles through initialization, plus the pinned ' +
            'service manifest and cold-acceptance wrapper.')
    }
    foreach ($role in 'Daddy', 'Cj') {
        $spec = $PlanPair.Specs[$role]
        if ($null -eq $spec -or [string]$spec.Role -cne $role -or
            [string]$spec.TrustMode -cne $expectedTrust -or
            (Get-AotSpecFingerprint -Spec $spec) -cne
                [string]$spec.SpecFingerprintSha256) {
            throw "Run context rejects mutated plan spec $role."
        }
    }
    $expectedPlanFingerprint = Get-AotSha256Text -Text (
        'Daddy=' + [string]$PlanPair.Specs['Daddy'].SpecFingerprintSha256 +
        "`n" + 'Cj=' +
        [string]$PlanPair.Specs['Cj'].SpecFingerprintSha256 + "`n")
    if ([string]$PlanPair.PlanFingerprintSha256 -cne
        $expectedPlanFingerprint) {
        throw 'Run context rejects a mutated plan fingerprint.'
    }
    foreach ($role in 'XWS', 'FESL') {
        $spec = $ServiceSpecs.Specs[$role]
        if ($null -eq $spec -or [string]$spec.Role -cne $role -or
            [string]$spec.TrustMode -cne $expectedTrust -or
            (Get-AotSpecFingerprint -Spec $spec) -cne
                [string]$spec.SpecFingerprintSha256) {
            throw "Run context rejects mutated service spec $role."
        }
    }
    $expectedServiceFingerprint = Get-AotSha256Text -Text (
        'XWS=' + [string]$ServiceSpecs.Specs['XWS'].SpecFingerprintSha256 +
        "`n" + 'FESL=' +
        [string]$ServiceSpecs.Specs['FESL'].SpecFingerprintSha256 + "`n")
    if ([string]$ServiceSpecs.ServiceSetFingerprintSha256 -cne
        $expectedServiceFingerprint) {
        throw 'Run context rejects a mutated service-set fingerprint.'
    }
    Assert-AotAdapter -Adapter $Adapter -SyntheticFixture:$SyntheticFixture
    $root = Get-AotCanonicalPath -Value $RunRoot -Label 'RunRoot' -Directory
    if ($SyntheticFixture) {
        Assert-AotTrustedSyntheticPath -Path $root -Label 'SyntheticFixture RunRoot'
    }
    $allowed = New-Object 'Collections.Generic.Dictionary[string,object]' `
        ([StringComparer]::Ordinal)
    $expectedSpecFingerprints = `
        New-Object 'Collections.Generic.Dictionary[string,string]' `
            ([StringComparer]::Ordinal)
    foreach ($role in 'XWS', 'FESL') {
        $allowed.Add($role, $ServiceSpecs.Specs[$role])
        $expectedSpecFingerprints.Add($role,
            [string]$ServiceSpecs.Specs[$role].SpecFingerprintSha256)
    }
    foreach ($role in 'Daddy', 'Cj') {
        $allowed.Add($role, $PlanPair.Specs[$role])
        $expectedSpecFingerprints.Add($role,
            [string]$PlanPair.Specs[$role].SpecFingerprintSha256)
    }
    $runToken = New-AotOwnedRunToken
    $runDirectory = Join-Path $root $runToken
    [void][IO.Directory]::CreateDirectory($runDirectory)
    if ($SyntheticFixture) {
        Assert-AotTrustedSyntheticPath -Path $runDirectory `
            -Label 'SyntheticFixture run directory'
    }
    $entries = New-Object 'Collections.Generic.Dictionary[string,object]' `
        ([StringComparer]::Ordinal)
    $expectedRuntimeIdentities = `
        New-Object 'Collections.Generic.Dictionary[string,object]' `
            ([StringComparer]::Ordinal)
    $context = [pscustomobject][ordered]@{
        Contract = 'AOT_OWNED_RUN_CONTEXT_V1'
        TrustMode = $expectedTrust
        SyntheticFixture = [bool]$SyntheticFixture
        PlanFingerprintSha256 = $expectedPlanFingerprint
        ServiceSetFingerprintSha256 = $expectedServiceFingerprint
        RunToken = $runToken
        RunDirectory = $runDirectory
        LedgerPath = Join-Path $runDirectory 'ownership.json'
        CreatedUtc = $null
        Status = 'Intent'
        AllowedSpecs = $allowed
        ExpectedSpecFingerprints = $expectedSpecFingerprints
        ExpectedRuntimeIdentities = $expectedRuntimeIdentities
        Entries = $entries
        NextOrdinal = 1
        Adapter = $Adapter
        AdapterAnchorId = $runToken
    }
    Add-AotContextAdapterAnchor -Context $context -Adapter $Adapter `
        -AnchorId $runToken
    $createdUtc = Invoke-AotContextAdapter -Context $context -Method UtcNow
    $context.CreatedUtc =
        ([DateTime]$createdUtc).ToUniversalTime().ToString('o')
    Save-AotOwnedLedger -Context $context
    return $context
}

function Assert-AotFilePin {
    param(
        [Parameter(Mandatory = $true)][object]$Context,
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][int64]$Bytes,
        [Parameter(Mandatory = $true)][string]$Sha256,
        [Parameter(Mandatory = $true)][string]$Label
    )

    $actualBytes = Invoke-AotContextAdapter -Context $Context `
        -Method FileLength -ArgumentList @($Path)
    if ([int64]$actualBytes -ne $Bytes) {
        throw "$Label length does not match its reviewed pin."
    }
    $actualHash = Invoke-AotContextAdapter -Context $Context `
        -Method HashFile -ArgumentList @($Path)
    if ([string]$actualHash -cne $Sha256) {
        throw "$Label SHA-256 does not match its reviewed pin."
    }
}

function New-AotIdentityCheckResult {
    param(
        [Parameter(Mandatory = $true)][bool]$IsMatch,
        [Parameter(Mandatory = $true)][string]$Code,
        [AllowNull()][object]$Identity,
        [AllowNull()][object]$Spec,
        [AllowNull()][object]$RuntimeIdentity,
        [AllowNull()][string]$Detail
    )

    return [pscustomobject][ordered]@{
        IsMatch = $IsMatch
        Code = $Code
        Identity = $Identity
        Spec = $Spec
        RuntimeIdentity = $RuntimeIdentity
        Detail = $Detail
    }
}

function Get-AotValidatedEntryBinding {
    param(
        [Parameter(Mandatory = $true)][object]$Context,
        [Parameter(Mandatory = $true)][string]$Role,
        [Parameter(Mandatory = $true)][object]$Entry
    )

    if ($null -eq $Entry.PSObject.Properties['RunToken']) {
        return New-AotIdentityCheckResult -IsMatch $false `
            -Code 'IDENTITY_ENTRY_CONTRACT_MISMATCH' -Identity $null `
            -Spec $null -RuntimeIdentity $null `
            -Detail 'Entry is missing operational field RunToken.'
    }
    if ([string]$Entry.RunToken -cne [string]$Context.RunToken) {
        return New-AotIdentityCheckResult -IsMatch $false `
            -Code 'IDENTITY_RUN_TOKEN_MISMATCH' -Identity $null `
            -Spec $null -RuntimeIdentity $null `
            -Detail 'Entry run token differs from its owning context.'
    }
    $spec = $Context.AllowedSpecs[$Role]
    $expectedFingerprint = $Context.ExpectedSpecFingerprints[$Role]
    if ($null -eq $spec -or
        [string]$spec.Contract -cne 'AOT_OWNED_PROCESS_SPEC_V1' -or
        [string]$spec.Role -cne $Role -or
        [string]$spec.TrustMode -cne [string]$Context.TrustMode) {
        return New-AotIdentityCheckResult -IsMatch $false `
            -Code 'IDENTITY_CONTEXT_SPEC_INVALID' -Identity $null `
            -Spec $spec -RuntimeIdentity $null `
            -Detail 'Context has no exact validated spec for the requested role.'
    }
    try {
        $actualFingerprint = Get-AotSpecFingerprint -Spec $spec
    } catch {
        return New-AotIdentityCheckResult -IsMatch $false `
            -Code 'IDENTITY_CONTEXT_SPEC_INVALID' -Identity $null `
            -Spec $spec -RuntimeIdentity $null `
            -Detail ([string]$_.Exception.Message)
    }
    $expectedClass = if ($Role -cin 'Daddy', 'Cj') { 'Xenia' } else { 'Service' }
    if ([string]$actualFingerprint -cne [string]$expectedFingerprint -or
        [string]$spec.SpecFingerprintSha256 -cne
            [string]$expectedFingerprint -or
        [string]$spec.ProcessClass -cne $expectedClass) {
        return New-AotIdentityCheckResult -IsMatch $false `
            -Code 'IDENTITY_CONTEXT_SPEC_FINGERPRINT_MISMATCH' `
            -Identity $null -Spec $spec -RuntimeIdentity $null `
            -Detail 'Context spec differs from its expected fingerprint.'
    }
    $setFingerprint = if ($expectedClass -ceq 'Xenia') {
        Get-AotSha256Text -Text (
            'Daddy=' +
            [string]$Context.ExpectedSpecFingerprints['Daddy'] + "`n" +
            'Cj=' + [string]$Context.ExpectedSpecFingerprints['Cj'] + "`n")
    } else {
        Get-AotSha256Text -Text (
            'XWS=' + [string]$Context.ExpectedSpecFingerprints['XWS'] +
            "`n" + 'FESL=' +
            [string]$Context.ExpectedSpecFingerprints['FESL'] + "`n")
    }
    $expectedSetFingerprint = if ($expectedClass -ceq 'Xenia') {
        [string]$Context.PlanFingerprintSha256
    } else {
        [string]$Context.ServiceSetFingerprintSha256
    }
    if ([string]$setFingerprint -cne $expectedSetFingerprint) {
        return New-AotIdentityCheckResult -IsMatch $false `
            -Code 'IDENTITY_CONTEXT_SET_FINGERPRINT_MISMATCH' `
            -Identity $null -Spec $spec -RuntimeIdentity $null `
            -Detail 'Context role-set fingerprint differs.'
    }
    $requiredEntryProperties = @(
        'RunToken', 'TrustMode', 'Role', 'ProcessClass', 'FilePath',
        'ImageBytes', 'ImageSha256', 'ArgumentListSha256', 'Affinity',
        'Priority', 'SpecFingerprintSha256', 'Pid', 'CreationFileTime',
        'StartTimeUtc', 'HandleClosed', 'Native')
    foreach ($propertyName in $requiredEntryProperties) {
        if ($null -eq $Entry.PSObject.Properties[$propertyName]) {
            return New-AotIdentityCheckResult -IsMatch $false `
                -Code 'IDENTITY_ENTRY_CONTRACT_MISMATCH' -Identity $null `
                -Spec $spec -RuntimeIdentity $null `
                -Detail "Entry is missing operational field $propertyName."
        }
    }
    try {
        $entryContractMatches =
            [string]$Entry.TrustMode -ceq [string]$spec.TrustMode -and
            [string]$Entry.Role -ceq $Role -and
            [string]$Entry.ProcessClass -ceq [string]$spec.ProcessClass -and
            [string]::Equals([string]$Entry.FilePath, [string]$spec.FilePath,
                [StringComparison]::OrdinalIgnoreCase) -and
            [int64]$Entry.ImageBytes -eq [int64]$spec.ImageBytes -and
            [string]$Entry.ImageSha256 -ceq [string]$spec.ImageSha256 -and
            [string]$Entry.ArgumentListSha256 -ceq
                [string]$spec.ArgumentListSha256 -and
            [string]$Entry.Affinity -ceq [string]$spec.Affinity -and
            [string]$Entry.Priority -ceq [string]$spec.Priority -and
            [string]$Entry.SpecFingerprintSha256 -ceq
                [string]$expectedFingerprint
    } catch {
        $entryContractMatches = $false
    }
    if (-not $entryContractMatches) {
        return New-AotIdentityCheckResult -IsMatch $false `
            -Code 'IDENTITY_ENTRY_CONTRACT_MISMATCH' -Identity $null `
            -Spec $spec -RuntimeIdentity $null `
            -Detail 'Mutable entry operational fields differ from the context spec.'
    }
    if (-not $Context.ExpectedRuntimeIdentities.ContainsKey($Role)) {
        return New-AotIdentityCheckResult -IsMatch $false `
            -Code 'IDENTITY_RUNTIME_ANCHOR_MISSING' -Identity $null `
            -Spec $spec -RuntimeIdentity $null `
            -Detail 'Context lacks the retained runtime identity anchor.'
    }
    $runtimeIdentity = $Context.ExpectedRuntimeIdentities[$Role]
    try {
        $entryRuntimeMatches =
            [uint32]$Entry.Pid -eq [uint32]$runtimeIdentity.ProcessId -and
            [string]$Entry.CreationFileTime -ceq
                [string]$runtimeIdentity.CreationFileTime -and
            [string]$Entry.StartTimeUtc -ceq
                [string]$runtimeIdentity.StartTimeUtc -and
            [bool]$Entry.HandleClosed -eq
                [bool]$runtimeIdentity.HandleClosed -and
            [object]::ReferenceEquals($Entry.Native,
                $runtimeIdentity.Native)
    } catch {
        $entryRuntimeMatches = $false
    }
    if (-not $entryRuntimeMatches) {
        return New-AotIdentityCheckResult -IsMatch $false `
            -Code 'IDENTITY_ENTRY_RUNTIME_MISMATCH' -Identity $null `
            -Spec $spec -RuntimeIdentity $runtimeIdentity `
            -Detail 'Mutable entry runtime identity differs from its context anchor.'
    }
    return New-AotIdentityCheckResult -IsMatch $true `
        -Code 'ENTRY_BINDING_MATCH' -Identity $null -Spec $spec `
        -RuntimeIdentity $runtimeIdentity -Detail $null
}

function Get-AotIdentityCheck {
    param(
        [Parameter(Mandatory = $true)][object]$Context,
        [Parameter(Mandatory = $true)][string]$Role,
        [Parameter(Mandatory = $true)][object]$Entry
    )

    [void](Get-AotBoundContextAdapter -Context $Context)
    $binding = Get-AotValidatedEntryBinding -Context $Context -Role $Role `
        -Entry $Entry
    if (-not $binding.IsMatch) {
        return $binding
    }
    if ([bool]$binding.RuntimeIdentity.HandleClosed -or
        $null -eq $binding.RuntimeIdentity.Native) {
        return New-AotIdentityCheckResult -IsMatch $false `
            -Code 'IDENTITY_HANDLE_CLOSED' -Identity $null `
            -Spec $binding.Spec -RuntimeIdentity $binding.RuntimeIdentity `
            -Detail 'The retained process handle is already closed.'
    }
    try {
        $identity = Invoke-AotContextAdapter -Context $Context `
            -Method GetIdentity `
            -ArgumentList @($binding.RuntimeIdentity.Native)
    } catch {
        return New-AotIdentityCheckResult -IsMatch $false `
            -Code 'IDENTITY_QUERY_FAILED' -Identity $null `
            -Spec $binding.Spec -RuntimeIdentity $binding.RuntimeIdentity `
            -Detail ([string]$_.Exception.Message)
    }
    $actualPath = $null
    try {
        $actualPath = Get-AotCanonicalPath -Value $identity.ImagePath `
            -Label 'retained-handle image path'
    } catch {
        return New-AotIdentityCheckResult -IsMatch $false `
            -Code 'IDENTITY_IMAGE_PATH_INVALID' -Identity $identity `
            -Spec $binding.Spec -RuntimeIdentity $binding.RuntimeIdentity `
            -Detail ([string]$_.Exception.Message)
    }
    if ([uint32]$identity.ProcessId -ne
        [uint32]$binding.RuntimeIdentity.ProcessId) {
        return New-AotIdentityCheckResult -IsMatch $false `
            -Code 'IDENTITY_PID_MISMATCH' -Identity $identity `
            -Spec $binding.Spec -RuntimeIdentity $binding.RuntimeIdentity `
            -Detail 'PID differs from the context runtime anchor.'
    }
    if ([string]$identity.CreationFileTime -cne
        [string]$binding.RuntimeIdentity.CreationFileTime) {
        return New-AotIdentityCheckResult -IsMatch $false `
            -Code 'IDENTITY_CREATION_TIME_MISMATCH' -Identity $identity `
            -Spec $binding.Spec -RuntimeIdentity $binding.RuntimeIdentity `
            -Detail 'Creation FILETIME differs from the context runtime anchor.'
    }
    if (-not [string]::Equals($actualPath,
            [string]$binding.Spec.FilePath,
            [StringComparison]::OrdinalIgnoreCase)) {
        return New-AotIdentityCheckResult -IsMatch $false `
            -Code 'IDENTITY_IMAGE_PATH_MISMATCH' -Identity $identity `
            -Spec $binding.Spec -RuntimeIdentity $binding.RuntimeIdentity `
            -Detail 'Image path differs from the context spec.'
    }
    try {
        Assert-AotFilePin -Context $Context -Path $actualPath `
            -Bytes ([int64]$binding.Spec.ImageBytes) `
            -Sha256 ([string]$binding.Spec.ImageSha256) `
            -Label 'retained-handle image'
    } catch {
        return New-AotIdentityCheckResult -IsMatch $false `
            -Code 'IDENTITY_IMAGE_PIN_MISMATCH' -Identity $identity `
            -Spec $binding.Spec -RuntimeIdentity $binding.RuntimeIdentity `
            -Detail ([string]$_.Exception.Message)
    }
    return New-AotIdentityCheckResult -IsMatch $true `
        -Code 'IDENTITY_MATCH' -Identity $identity -Spec $binding.Spec `
        -RuntimeIdentity $binding.RuntimeIdentity -Detail $null
}

function Invoke-AotAbortCreated {
    param(
        [Parameter(Mandatory = $true)][object]$Context,
        [Parameter(Mandatory = $true)][object]$Created
    )

    $exitConfirmed = $false
    $threadHandleClosed = $false
    $processHandleClosed = $false
    $failureMessage = $null
    try {
        $alive = [bool](Invoke-AotContextAdapter -Context $Context `
            -Method IsAlive -ArgumentList @($Created))
        if ($alive) {
            [void](Invoke-AotContextAdapter -Context $Context `
                -Method Terminate `
                -ArgumentList @($Created, [uint32]2691760129))
            $exitConfirmed = [bool](Invoke-AotContextAdapter `
                -Context $Context -Method WaitExit `
                -ArgumentList @($Created, 5000))
            if (-not $exitConfirmed) {
                $failureMessage =
                    'Created process did not signal during launch rollback.'
            }
        } else {
            $exitConfirmed = $true
        }
    } catch {
        $failureMessage = [string]$_.Exception.Message
        $exitConfirmed = $false
    }
    try {
        [void](Invoke-AotContextAdapter -Context $Context `
            -Method CloseThreadHandle -ArgumentList @($Created))
        $threadHandleClosed = $true
    } catch {
        if ([string]::IsNullOrEmpty($failureMessage)) {
            $failureMessage = [string]$_.Exception.Message
        }
    }
    if ($exitConfirmed) {
        try {
            [void](Invoke-AotContextAdapter -Context $Context `
                -Method CloseProcessHandle -ArgumentList @($Created))
            $processHandleClosed = $true
        } catch {
            $failureMessage = [string]$_.Exception.Message
        }
    }
    return [pscustomobject][ordered]@{
        ExitConfirmed = $exitConfirmed
        ThreadHandleClosed = $threadHandleClosed
        ProcessHandleClosed = $processHandleClosed
        Failure = $failureMessage
    }
}

function Start-AotOwnedProcess {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$Context,
        [Parameter(Mandatory = $true)]
        [ValidateSet('XWS', 'FESL', 'Daddy', 'Cj')][string]$Role
    )

    if ($Context.Contract -cne 'AOT_OWNED_RUN_CONTEXT_V1' -or
        [string]$Context.Status -notin 'Intent', 'Active') {
        throw 'Owned run context is not launchable.'
    }
    [void](Get-AotBoundContextAdapter -Context $Context)
    if ([string]$Context.TrustMode -cne 'SYNTHETIC_TEST_ONLY' -or
        -not [bool]$Context.SyntheticFixture) {
        throw 'PRODUCTION_LAUNCH_CLOSURE_DEFERRED'
    }
    if ($Context.Entries.ContainsKey($Role)) {
        throw "Owned run already contains role $Role."
    }
    $spec = $Context.AllowedSpecs[$Role]
    if ($null -eq $spec -or
        [string]$spec.Contract -cne 'AOT_OWNED_PROCESS_SPEC_V1' -or
        [string]$spec.Role -cne $Role -or
        [string]$spec.TrustMode -cne [string]$Context.TrustMode) {
        throw "Owned run has no validated spec for role $Role."
    }
    $currentFingerprint = Get-AotSpecFingerprint -Spec $spec
    $expectedFingerprint = $Context.ExpectedSpecFingerprints[$Role]
    $setFingerprint = if ([string]$spec.ProcessClass -ceq 'Xenia') {
        Get-AotSha256Text -Text (
            'Daddy=' +
            [string]$Context.ExpectedSpecFingerprints['Daddy'] + "`n" +
            'Cj=' + [string]$Context.ExpectedSpecFingerprints['Cj'] + "`n")
    } else {
        Get-AotSha256Text -Text (
            'XWS=' + [string]$Context.ExpectedSpecFingerprints['XWS'] +
            "`n" + 'FESL=' +
            [string]$Context.ExpectedSpecFingerprints['FESL'] + "`n")
    }
    $contextSetFingerprint = if ([string]$spec.ProcessClass -ceq 'Xenia') {
        [string]$Context.PlanFingerprintSha256
    } else {
        [string]$Context.ServiceSetFingerprintSha256
    }
    if ([string]$currentFingerprint -cne [string]$expectedFingerprint -or
        [string]$spec.SpecFingerprintSha256 -cne
            [string]$expectedFingerprint -or
        [string]$setFingerprint -cne $contextSetFingerprint) {
        throw "$Role normalized process spec was mutated after validation."
    }
    Assert-AotFilePin -Context $Context -Path ([string]$spec.FilePath) `
        -Bytes ([int64]$spec.ImageBytes) `
        -Sha256 ([string]$spec.ImageSha256) -Label "$Role image"
    if ([string]$spec.ProcessClass -ceq 'Service') {
        Assert-AotFilePin -Context $Context -Path ([string]$spec.PayloadPath) `
            -Bytes ([int64]$spec.PayloadBytes) `
            -Sha256 ([string]$spec.PayloadSha256) -Label "$Role payload"
    } else {
        $actualGameHash = Invoke-AotContextAdapter -Context $Context `
            -Method HashFile -ArgumentList @([string]$spec.GamePath)
        if ([string]$actualGameHash -cne [string]$spec.GameSha256) {
            throw "$Role game image SHA-256 does not match its planner pin."
        }
    }

    $now = Invoke-AotContextAdapter -Context $Context -Method UtcNow
    $entry = [pscustomobject][ordered]@{
        RunToken = [string]$Context.RunToken
        TrustMode = [string]$Context.TrustMode
        LaunchOrdinal = [int]$Context.NextOrdinal
        Role = $Role
        ProcessClass = [string]$spec.ProcessClass
        Pid = [uint32]0
        CreationFileTime = $null
        StartTimeUtc = $null
        FilePath = [string]$spec.FilePath
        ImageBytes = [int64]$spec.ImageBytes
        ImageSha256 = [string]$spec.ImageSha256
        ArgumentListSha256 = [string]$spec.ArgumentListSha256
        SpecFingerprintSha256 = [string]$spec.SpecFingerprintSha256
        Affinity = [string]$spec.Affinity
        Priority = [string]$spec.Priority
        State = 'LaunchIntent'
        ContractAssertions = 0
        LastObservedUtc = ([DateTime]$now).ToUniversalTime().ToString('o')
        StopResult = $null
        ErrorCode = $null
        HandleClosed = $false
        Native = $null
    }
    $Context.Entries.Add($Role, $entry)
    $Context.NextOrdinal = [int]$Context.NextOrdinal + 1
    $Context.Status = 'Active'
    try {
        Save-AotOwnedLedger -Context $Context
    } catch {
        $entry.State = 'LaunchRolledBack'
        $entry.ErrorCode = 'LAUNCH_INTENT_LEDGER_COMMIT_FAILED'
        $entry.HandleClosed = $true
        try { Save-AotOwnedLedger -Context $Context } catch {}
        throw
    }

    $created = $null
    try {
        if ((Get-AotSpecFingerprint -Spec $spec) -cne
                [string]$expectedFingerprint -or
            [string]$entry.SpecFingerprintSha256 -cne
                [string]$expectedFingerprint) {
            throw "$Role normalized process spec changed after LaunchIntent."
        }
        $spawnForeground = [IntPtr]::Zero
        if ([string]$spec.ProcessClass -ceq 'Xenia') {
            $spawnForeground = [IntPtr](Invoke-AotContextAdapter `
                -Context $Context -Method GetForegroundWindow)
        }
        $created = Invoke-AotContextAdapter -Context $Context `
            -Method CreateSuspended -ArgumentList @($spec)
        $entry.Native = $created
        if ($null -eq $created -or [uint32]$created.ProcessId -eq 0) {
            throw "$Role CreateSuspended returned an invalid owned handle record."
        }
        if ([string]$spec.ProcessClass -ceq 'Xenia') {
            $spawnForegroundAfter = [IntPtr](Invoke-AotContextAdapter `
                -Context $Context -Method GetForegroundWindow)
            if ($spawnForegroundAfter -ne $spawnForeground) {
                throw "$Role suspended spawn changed the foreground window."
            }
        }
        $identity = Invoke-AotContextAdapter -Context $Context `
            -Method GetIdentity -ArgumentList @($created)
        $identityPath = Get-AotCanonicalPath -Value $identity.ImagePath `
            -Label "$Role created image path"
        if ([uint32]$identity.ProcessId -ne [uint32]$created.ProcessId -or
            [uint64]$identity.CreationFileTime -eq 0 -or
            -not [string]::Equals($identityPath, [string]$spec.FilePath,
                [StringComparison]::OrdinalIgnoreCase)) {
            throw "$Role suspended process identity does not match its spec."
        }
        Assert-AotFilePin -Context $Context -Path $identityPath `
            -Bytes ([int64]$spec.ImageBytes) `
            -Sha256 ([string]$spec.ImageSha256) `
            -Label "$Role created image"
        $contract = Invoke-AotContextAdapter -Context $Context `
            -Method SetContract -ArgumentList @(
                $created, [string]$spec.Affinity, [string]$spec.Priority)
        $expectedMask = [Convert]::ToUInt64([string]$spec.Affinity, 16)
        if ([uint64]$contract.Affinity -ne $expectedMask -or
            [uint32]$contract.PriorityClass -ne [uint32]0x80) {
            throw "$Role affinity/priority readback did not match before resume."
        }
        $creationFileTime = ([uint64]$identity.CreationFileTime).ToString(
            [Globalization.CultureInfo]::InvariantCulture)
        $identityStartTime = [DateTime]$identity.StartTimeUtc
        $startTimeUtc = $identityStartTime.ToUniversalTime().ToString('o')
        if ($Context.ExpectedRuntimeIdentities.ContainsKey($Role)) {
            throw "$Role already has a context runtime identity anchor."
        }
        $runtimeIdentity = [pscustomobject][ordered]@{
            Role = $Role
            ProcessId = [uint32]$identity.ProcessId
            CreationFileTime = $creationFileTime
            StartTimeUtc = $startTimeUtc
            HandleClosed = $false
            Native = $created
        }
        $Context.ExpectedRuntimeIdentities.Add($Role, $runtimeIdentity)
        $entry.Pid = [uint32]$runtimeIdentity.ProcessId
        $entry.CreationFileTime = [string]$runtimeIdentity.CreationFileTime
        $entry.StartTimeUtc = [string]$runtimeIdentity.StartTimeUtc
        $entry.FilePath = $identityPath
        $entry.State = 'Ledgered'
        $entry.ContractAssertions = 1
        $observedTime = [DateTime](Invoke-AotContextAdapter `
            -Context $Context -Method UtcNow)
        $entry.LastObservedUtc = $observedTime.ToUniversalTime().ToString('o')
        try {
            Save-AotOwnedLedger -Context $Context
        } catch {
            $entry.State = 'LaunchRolledBack'
            $entry.ErrorCode = 'LEDGER_COMMIT_BEFORE_RESUME_FAILED'
            throw
        }
        $resumeForeground = [IntPtr]::Zero
        if ([string]$spec.ProcessClass -ceq 'Xenia') {
            $resumeForeground = [IntPtr](Invoke-AotContextAdapter `
                -Context $Context -Method GetForegroundWindow)
        }
        $previousSuspendCount = Invoke-AotContextAdapter -Context $Context `
            -Method Resume -ArgumentList @($created)
        if ([uint32]$previousSuspendCount -ne 1) {
            throw "$Role ResumeThread returned unexpected suspend count."
        }
        if ([string]$spec.ProcessClass -ceq 'Xenia') {
            $resumeForegroundAfter = [IntPtr](Invoke-AotContextAdapter `
                -Context $Context -Method GetForegroundWindow)
            if ($resumeForegroundAfter -ne $resumeForeground) {
                throw "$Role resume changed the foreground window."
            }
        }
        [void](Invoke-AotContextAdapter -Context $Context `
            -Method CloseThreadHandle -ArgumentList @($created))
        $entry.State = 'RunningHidden'
        $entry.LastObservedUtc = ([DateTime](Invoke-AotContextAdapter `
                -Context $Context -Method UtcNow)).ToUniversalTime().ToString('o')
        try {
            Save-AotOwnedLedger -Context $Context
        } catch {
            $entry.State = 'LaunchRolledBack'
            $entry.ErrorCode = 'LEDGER_COMMIT_AFTER_RESUME_FAILED'
            throw
        }
        return $entry
    } catch {
        $failure = $_
        if ($null -ne $created) {
            $rollback = Invoke-AotAbortCreated -Context $Context `
                -Created $created
            if ([bool]$rollback.ExitConfirmed -and
                [bool]$rollback.ProcessHandleClosed) {
                $entry.HandleClosed = $true
                if ($Context.ExpectedRuntimeIdentities.ContainsKey($Role)) {
                    $Context.ExpectedRuntimeIdentities[$Role].HandleClosed = $true
                }
                $entry.State = 'LaunchRolledBack'
            } else {
                $entry.HandleClosed = $false
                if ($Context.ExpectedRuntimeIdentities.ContainsKey($Role)) {
                    $Context.ExpectedRuntimeIdentities[$Role].HandleClosed = $false
                }
                $entry.State = 'CleanupIncomplete'
                $entry.StopResult = 'FAILED'
                $entry.ErrorCode = 'LAUNCH_ROLLBACK_INCOMPLETE'
            }
        } else {
            $entry.HandleClosed = $true
            $entry.State = 'LaunchRolledBack'
        }
        if ([string]::IsNullOrEmpty([string]$entry.ErrorCode)) {
            $entry.ErrorCode = 'LAUNCH_FAILED'
        }
        try { Save-AotOwnedLedger -Context $Context } catch {}
        throw $failure
    }
}

function Test-AotOwnedProcessLiveness {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$Context,
        [Parameter(Mandatory = $true)]
        [ValidateSet('XWS', 'FESL', 'Daddy', 'Cj')][string]$Role
    )

    [void](Get-AotBoundContextAdapter -Context $Context)
    if (-not $Context.Entries.ContainsKey($Role)) {
        throw "Owned run has no launched role $Role."
    }
    $entry = $Context.Entries[$Role]
    $identityCheck = Get-AotIdentityCheck -Context $Context -Role $Role `
        -Entry $entry
    if (-not $identityCheck.IsMatch) {
        return [pscustomobject][ordered]@{
            Role = $Role
            Owned = $false
            Alive = $false
            Code = [string]$identityCheck.Code
        }
    }
    $alive = [bool](Invoke-AotContextAdapter -Context $Context `
        -Method IsAlive -ArgumentList @($identityCheck.RuntimeIdentity.Native))
    return [pscustomobject][ordered]@{
        Role = $Role
        Owned = $true
        Alive = $alive
        Code = if ($alive) { 'OWNED_ALIVE' } else { 'OWNED_EXITED' }
    }
}

function Set-AotOwnedProcessContract {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$Context,
        [Parameter(Mandatory = $true)]
        [ValidateSet('XWS', 'FESL', 'Daddy', 'Cj')][string]$Role,
        [switch]$Initialized
    )

    [void](Get-AotBoundContextAdapter -Context $Context)
    if (-not $Context.Entries.ContainsKey($Role)) {
        throw "Owned run has no launched role $Role."
    }
    $entry = $Context.Entries[$Role]
    $identityCheck = Get-AotIdentityCheck -Context $Context -Role $Role `
        -Entry $entry
    if (-not $identityCheck.IsMatch) {
        throw "$Role retained-handle identity refusal: $($identityCheck.Code)"
    }
    if (-not [bool](Invoke-AotContextAdapter -Context $Context `
                -Method IsAlive `
                -ArgumentList @($identityCheck.RuntimeIdentity.Native))) {
        throw "$Role exited before contract reassertion."
    }
    $contract = Invoke-AotContextAdapter -Context $Context `
        -Method SetContract -ArgumentList @(
            $identityCheck.RuntimeIdentity.Native,
            [string]$identityCheck.Spec.Affinity,
            [string]$identityCheck.Spec.Priority)
    $expectedMask = [Convert]::ToUInt64(
        [string]$identityCheck.Spec.Affinity, 16)
    if ([uint64]$contract.Affinity -ne $expectedMask -or
        [uint32]$contract.PriorityClass -ne [uint32]0x80) {
        throw "$Role contract reassertion readback differs."
    }
    $entry.ContractAssertions = [int]$entry.ContractAssertions + 1
    $entry.LastObservedUtc = ([DateTime](Invoke-AotContextAdapter `
            -Context $Context -Method UtcNow)).ToUniversalTime().ToString('o')
    if ($Initialized) {
        $entry.State = 'Initialized'
    }
    Save-AotOwnedLedger -Context $Context
    return $entry
}

function Assert-AotRectangle {
    param([Parameter(Mandatory = $true)][object]$Rectangle)

    Assert-AotExactProperties -InputObject $Rectangle `
        -Expected @('X', 'Y', 'Width', 'Height') -Label 'window rectangle'
    foreach ($field in 'X', 'Y', 'Width', 'Height') {
        if ($Rectangle.$field -isnot [int32]) {
            throw "window rectangle.$field must be Int32."
        }
    }
    if ([int]$Rectangle.Width -le 0 -or [int]$Rectangle.Height -le 0) {
        throw 'window rectangle dimensions must be positive.'
    }
}

function Invoke-AotOwnedWindowNoActivateStep {
    param(
        [Parameter(Mandatory = $true)][object]$Context,
        [Parameter(Mandatory = $true)][string]$Role,
        [Parameter(Mandatory = $true)][object]$Entry,
        [Parameter(Mandatory = $true)][IntPtr]$Window,
        [Parameter(Mandatory = $true)][string]$Method,
        [AllowNull()][object]$Rectangle
    )

    [void](Get-AotBoundContextAdapter -Context $Context)
    $beforeCheck = Get-AotIdentityCheck -Context $Context -Role $Role `
        -Entry $Entry
    if (-not $beforeCheck.IsMatch) {
        throw "$Role identity changed before $Method`: $($beforeCheck.Code)"
    }
    if (-not [bool](Invoke-AotContextAdapter -Context $Context `
                -Method IsAlive `
                -ArgumentList @($beforeCheck.RuntimeIdentity.Native))) {
        throw "$Role exited before $Method."
    }
    $windowPid = Invoke-AotContextAdapter -Context $Context `
        -Method GetWindowProcessId -ArgumentList @($Window)
    if ([uint32]$windowPid -ne
        [uint32]$beforeCheck.RuntimeIdentity.ProcessId) {
        throw "$Role window PID changed before $Method."
    }
    $foregroundBefore = [IntPtr](Invoke-AotContextAdapter `
        -Context $Context -Method GetForegroundWindow)
    $failure = $null
    try {
        $arguments = if ($null -eq $Rectangle) {
            @($Window)
        } else {
            @($Window, $Rectangle)
        }
        [void](Invoke-AotContextAdapter -Context $Context -Method $Method `
            -ArgumentList $arguments)
    } catch {
        $failure = $_
    }
    $foregroundAfter = [IntPtr](Invoke-AotContextAdapter `
        -Context $Context -Method GetForegroundWindow)
    $afterCheck = Get-AotIdentityCheck -Context $Context -Role $Role `
        -Entry $Entry
    if (-not $afterCheck.IsMatch) {
        throw "$Role identity changed after $Method`: $($afterCheck.Code)"
    }
    if (-not [bool](Invoke-AotContextAdapter -Context $Context `
                -Method IsAlive `
                -ArgumentList @($afterCheck.RuntimeIdentity.Native))) {
        throw "$Role exited after $Method."
    }
    $windowPidAfter = Invoke-AotContextAdapter -Context $Context `
        -Method GetWindowProcessId -ArgumentList @($Window)
    if ([uint32]$windowPidAfter -ne
        [uint32]$afterCheck.RuntimeIdentity.ProcessId) {
        throw "$Role window PID changed after $Method."
    }
    if ($foregroundAfter -ne $foregroundBefore) {
        $Entry.State = 'FocusInvariantFailed'
        $Entry.ErrorCode = 'FOREGROUND_CHANGED_DURING_' +
            $Method.ToUpperInvariant()
        try { Save-AotOwnedLedger -Context $Context } catch {}
        throw "$Role $Method changed the foreground window."
    }
    if ($null -ne $failure) {
        throw $failure
    }
}

function Show-AotOwnedWindowNoActivate {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$Context,
        [Parameter(Mandatory = $true)]
        [ValidateSet('Daddy', 'Cj')][string]$Role,
        [Parameter(Mandatory = $true)][object]$Rectangle
    )

    [void](Get-AotBoundContextAdapter -Context $Context)
    Assert-AotRectangle -Rectangle $Rectangle
    $entry = Set-AotOwnedProcessContract -Context $Context -Role $Role
    $discoveryCheck = Get-AotIdentityCheck -Context $Context -Role $Role `
        -Entry $entry
    if (-not $discoveryCheck.IsMatch) {
        throw "$Role identity changed before window discovery."
    }
    if (-not [bool](Invoke-AotContextAdapter -Context $Context `
                -Method IsAlive `
                -ArgumentList @($discoveryCheck.RuntimeIdentity.Native))) {
        throw "$Role exited before window discovery."
    }
    $ownedProcessId = [uint32]$discoveryCheck.RuntimeIdentity.ProcessId
    $first = @(Invoke-AotContextAdapter -Context $Context `
        -Method FindWindows -ArgumentList @($ownedProcessId))
    $second = @(Invoke-AotContextAdapter -Context $Context `
        -Method FindWindows -ArgumentList @($ownedProcessId))
    if ($first.Count -ne 1 -or $second.Count -ne 1 -or
        [IntPtr]$first[0] -eq [IntPtr]::Zero -or
        [IntPtr]$first[0] -ne [IntPtr]$second[0]) {
        throw "$Role does not have one stable owned top-level window."
    }
    $window = [IntPtr]$first[0]
    Invoke-AotOwnedWindowNoActivateStep -Context $Context -Role $Role `
        -Entry $entry -Window $window -Method PlaceHidden `
        -Rectangle $Rectangle
    Invoke-AotOwnedWindowNoActivateStep -Context $Context -Role $Role `
        -Entry $entry -Window $window -Method RevealNoActivate `
        -Rectangle $null
    Invoke-AotOwnedWindowNoActivateStep -Context $Context -Role $Role `
        -Entry $entry -Window $window -Method PlaceVisibleNoActivate `
        -Rectangle $Rectangle
    $entry.State = 'VisibleNoActivate'
    $entry.LastObservedUtc = ([DateTime](Invoke-AotContextAdapter `
            -Context $Context -Method UtcNow)).ToUniversalTime().ToString('o')
    Save-AotOwnedLedger -Context $Context
    return $window
}

function Stop-AotOwnedRun {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$Context,
        [ValidateRange(0, 30000)][int]$GracefulTimeoutMs = 2000,
        [ValidateRange(1, 30000)][int]$TerminateTimeoutMs = 5000
    )

    if ($Context.Contract -cne 'AOT_OWNED_RUN_CONTEXT_V1') {
        throw 'Cleanup requires an owned v1 run context.'
    }
    [void](Get-AotBoundContextAdapter -Context $Context)
    $Context.Status = 'Stopping'
    try { Save-AotOwnedLedger -Context $Context } catch {}
    $results = New-Object 'Collections.Generic.List[object]'
    foreach ($role in 'Cj', 'Daddy', 'FESL', 'XWS') {
        if (-not $Context.Entries.ContainsKey($role)) {
            continue
        }
        $entry = $Context.Entries[$role]
        $binding = Get-AotValidatedEntryBinding -Context $Context `
            -Role $role -Entry $entry
        if (-not $binding.IsMatch) {
            $entry.State = 'StopRefusedIdentityMismatch'
            $entry.StopResult = 'REFUSED'
            $entry.ErrorCode = [string]$binding.Code
            $results.Add([pscustomobject][ordered]@{
                    Role = $role
                    Result = 'REFUSED_IDENTITY_MISMATCH'
                    Code = [string]$binding.Code
                })
            try { Save-AotOwnedLedger -Context $Context } catch {}
            continue
        }
        if ([bool]$binding.RuntimeIdentity.HandleClosed) {
            $results.Add([pscustomobject][ordered]@{
                    Role = $role
                    Result = 'ALREADY_CLEANED'
                    Code = [string]$entry.ErrorCode
                })
            continue
        }
        $entry.State = 'StopRequested'
        $identityCheck = Get-AotIdentityCheck -Context $Context -Role $role `
            -Entry $entry
        if (-not $identityCheck.IsMatch) {
            $entry.State = 'StopRefusedIdentityMismatch'
            $entry.StopResult = 'REFUSED'
            $entry.ErrorCode = [string]$identityCheck.Code
            $results.Add([pscustomobject][ordered]@{
                    Role = $role
                    Result = 'REFUSED_IDENTITY_MISMATCH'
                    Code = [string]$identityCheck.Code
                })
            try { Save-AotOwnedLedger -Context $Context } catch {}
            continue
        }
        $safeToCloseHandle = $false
        $resultName = $null
        $resultCode = $null
        try {
            $alive = [bool](Invoke-AotContextAdapter -Context $Context `
                -Method IsAlive `
                -ArgumentList @($identityCheck.RuntimeIdentity.Native))
            if (-not $alive) {
                $entry.State = 'Exited'
                $entry.StopResult = 'ALREADY_EXITED'
                $resultName = 'ALREADY_EXITED'
                $safeToCloseHandle = $true
            } else {
                if ([string]$identityCheck.Spec.ProcessClass -ceq 'Xenia' -and
                    $GracefulTimeoutMs -gt 0) {
                    $windows = @(Invoke-AotContextAdapter -Context $Context `
                        -Method FindWindows -ArgumentList @(
                            [uint32]$identityCheck.RuntimeIdentity.ProcessId))
                    if ($windows.Count -eq 1 -and
                        [IntPtr]$windows[0] -ne [IntPtr]::Zero) {
                        $window = [IntPtr]$windows[0]
                        $beforeCloseCheck = Get-AotIdentityCheck `
                            -Context $Context -Role $role -Entry $entry
                        if (-not $beforeCloseCheck.IsMatch) {
                            $entry.State = 'StopRefusedIdentityMismatch'
                            $entry.StopResult = 'REFUSED'
                            $entry.ErrorCode = [string]$beforeCloseCheck.Code
                            $resultName = 'REFUSED_IDENTITY_MISMATCH'
                            $resultCode = [string]$beforeCloseCheck.Code
                        } else {
                            $alive = [bool](Invoke-AotContextAdapter `
                                -Context $Context -Method IsAlive `
                                -ArgumentList @(
                                    $beforeCloseCheck.RuntimeIdentity.Native))
                        }
                        if ($null -eq $resultName -and -not $alive) {
                            $entry.State = 'Exited'
                            $entry.StopResult = 'ALREADY_EXITED'
                            $resultName = 'ALREADY_EXITED'
                            $safeToCloseHandle = $true
                        }
                        if ($null -eq $resultName -and $alive) {
                            $windowPid = Invoke-AotContextAdapter `
                                -Context $Context -Method GetWindowProcessId `
                                -ArgumentList @($window)
                        } else {
                            $windowPid = [uint32]0
                        }
                        if ($null -eq $resultName -and $alive -and
                            [uint32]$windowPid -eq
                                [uint32]$beforeCloseCheck.RuntimeIdentity.ProcessId) {
                            $requestCloseIssued = $false
                            try {
                                [void](Invoke-AotContextAdapter `
                                    -Context $Context `
                                    -Method RequestClose `
                                    -ArgumentList @($window))
                                $requestCloseIssued = $true
                            } catch {
                                $requestCloseIssued = $false
                            }
                            $afterCloseCheck = Get-AotIdentityCheck `
                                -Context $Context -Role $role -Entry $entry
                            if (-not $afterCloseCheck.IsMatch) {
                                $entry.State = 'StopRefusedIdentityMismatch'
                                $entry.StopResult = 'REFUSED'
                                $entry.ErrorCode = [string]$afterCloseCheck.Code
                                $resultName = 'REFUSED_IDENTITY_MISMATCH'
                                $resultCode = [string]$afterCloseCheck.Code
                            } else {
                                $aliveAfterClose = [bool](
                                    Invoke-AotContextAdapter `
                                    -Context $Context -Method IsAlive `
                                    -ArgumentList @(
                                        $afterCloseCheck.RuntimeIdentity.Native))
                                $windowPidAfter = Invoke-AotContextAdapter `
                                    -Context $Context `
                                    -Method GetWindowProcessId `
                                    -ArgumentList @($window)
                                $postCloseWindowOwned =
                                    [uint32]$windowPidAfter -eq
                                    [uint32]$afterCloseCheck.RuntimeIdentity.ProcessId
                                if (-not $postCloseWindowOwned) {
                                    $alive = $aliveAfterClose
                                    if (-not $alive) {
                                        $entry.State = 'Exited'
                                        $entry.StopResult = 'ALREADY_EXITED'
                                        $resultName = 'ALREADY_EXITED'
                                        $safeToCloseHandle = $true
                                    }
                                } elseif (-not $requestCloseIssued) {
                                    $alive = $aliveAfterClose
                                    if (-not $alive) {
                                        $entry.State = 'Exited'
                                        $entry.StopResult = 'ALREADY_EXITED'
                                        $resultName = 'ALREADY_EXITED'
                                        $safeToCloseHandle = $true
                                    }
                                } elseif (-not $aliveAfterClose) {
                                    $alive = $false
                                    $entry.StopResult = 'CLOSED_OWNED_WINDOW'
                                    $entry.State = 'Exited'
                                    $resultName = [string]$entry.StopResult
                                    $safeToCloseHandle = $true
                                } elseif ([bool](Invoke-AotContextAdapter `
                                        -Context $Context -Method WaitExit `
                                        -ArgumentList @(
                                            $afterCloseCheck.RuntimeIdentity.Native,
                                            $GracefulTimeoutMs))) {
                                    $alive = $false
                                    $entry.StopResult = 'CLOSED_OWNED_WINDOW'
                                    $entry.State = 'Exited'
                                    $resultName = [string]$entry.StopResult
                                    $safeToCloseHandle = $true
                                } else {
                                    $alive = [bool](Invoke-AotContextAdapter `
                                        -Context $Context -Method IsAlive `
                                        -ArgumentList @(
                                            $afterCloseCheck.RuntimeIdentity.Native))
                                    if (-not $alive) {
                                        $entry.State = 'Exited'
                                        $entry.StopResult = 'ALREADY_EXITED'
                                        $resultName = 'ALREADY_EXITED'
                                        $safeToCloseHandle = $true
                                    }
                                }
                            }
                        }
                    }
                }
                if ($null -eq $resultName -and $alive) {
                    $terminationCheck = Get-AotIdentityCheck `
                        -Context $Context -Role $role -Entry $entry
                    if (-not $terminationCheck.IsMatch) {
                        $entry.State = 'StopRefusedIdentityMismatch'
                        $entry.StopResult = 'REFUSED'
                        $entry.ErrorCode = [string]$terminationCheck.Code
                        $resultName = 'REFUSED_IDENTITY_MISMATCH'
                        $resultCode = [string]$terminationCheck.Code
                    } else {
                        [void](Invoke-AotContextAdapter -Context $Context `
                            -Method Terminate -ArgumentList @(
                                $terminationCheck.RuntimeIdentity.Native,
                                [uint32]2691760130))
                        if (-not [bool](Invoke-AotContextAdapter `
                                -Context $Context -Method WaitExit `
                                -ArgumentList @(
                                    $terminationCheck.RuntimeIdentity.Native,
                                    $TerminateTimeoutMs))) {
                            throw "$role retained handle did not signal after termination."
                        }
                        $entry.StopResult = 'TERMINATED_OWNED_HANDLE'
                        $entry.State = 'Exited'
                        $resultName = [string]$entry.StopResult
                        $safeToCloseHandle = $true
                    }
                } elseif ($null -eq $resultName -and -not $alive) {
                    $entry.StopResult = 'ALREADY_EXITED'
                    $entry.State = 'Exited'
                    $resultName = [string]$entry.StopResult
                    $safeToCloseHandle = $true
                }
            }
        } catch {
            $entry.State = 'CleanupIncomplete'
            $entry.StopResult = 'FAILED'
            $entry.ErrorCode = 'OWNED_HANDLE_STOP_FAILED'
            $resultName = 'FAILED'
            $resultCode = [string]$_.Exception.Message
            $safeToCloseHandle = $false
        }
        if ($safeToCloseHandle) {
            try {
                [void](Invoke-AotContextAdapter -Context $Context `
                    -Method CloseProcessHandle -ArgumentList @(
                        $identityCheck.RuntimeIdentity.Native))
                $identityCheck.RuntimeIdentity.HandleClosed = $true
                $entry.HandleClosed = $true
            } catch {
                $entry.State = 'CleanupIncomplete'
                $entry.StopResult = 'FAILED'
                $entry.ErrorCode = 'OWNED_HANDLE_CLOSE_FAILED'
                $resultName = 'FAILED'
                $resultCode = [string]$_.Exception.Message
            }
        }
        $results.Add([pscustomobject][ordered]@{
                Role = $role
                Result = $resultName
                Code = $resultCode
            })
        $entry.LastObservedUtc = ([DateTime](Invoke-AotContextAdapter `
                -Context $Context -Method UtcNow)).ToUniversalTime().ToString('o')
        try { Save-AotOwnedLedger -Context $Context } catch {}
    }
    $refusedOrFailed = @($Context.Entries.Values | Where-Object {
            $_.State -eq 'StopRefusedIdentityMismatch' -or
            $_.State -eq 'StopFailed' -or
            $_.State -eq 'CleanupIncomplete'
        }).Count
    $Context.Status = if ($refusedOrFailed -eq 0) {
        'Stopped'
    } else {
        'StoppedWithRefusals'
    }
    try { Save-AotOwnedLedger -Context $Context } catch {}
    return $results.ToArray()
}

Export-ModuleMember -Function @(
    'Assert-AotOwnedPlanPair',
    'Assert-AotOwnedServiceSpecs',
    'New-AotOwnedRunToken',
    'New-AotOwnedRunContext',
    'Start-AotOwnedProcess',
    'Test-AotOwnedProcessLiveness',
    'Set-AotOwnedProcessContract',
    'Show-AotOwnedWindowNoActivate',
    'Stop-AotOwnedRun')
