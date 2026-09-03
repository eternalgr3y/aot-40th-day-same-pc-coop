[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$modulePath = Join-Path $repoRoot 'tools\runtime\AotOwnedProcess.psm1'
$script:ownedModule = Import-Module -Force -Name $modulePath -PassThru

$script:assertions = 0
$script:cases = 0
$script:fixtureRoots = New-Object 'Collections.Generic.List[string]'
$script:localApplicationData = [Environment]::GetFolderPath(
    [Environment+SpecialFolder]::LocalApplicationData)
$script:tempRoot = [IO.Path]::GetFullPath((Join-Path `
        $script:localApplicationData 'Temp')).TrimEnd('\')

function Assert-True {
    param([bool]$Condition, [string]$Message)
    $script:assertions++
    if (-not $Condition) { throw $Message }
}

function Assert-Equal {
    param($Actual, $Expected, [string]$Message)
    $script:assertions++
    if ([string]$Actual -cne [string]$Expected) {
        throw "$Message actual=[$Actual] expected=[$Expected]"
    }
}

function Assert-Throws {
    param(
        [Parameter(Mandatory = $true)][scriptblock]$Action,
        [Parameter(Mandatory = $true)][string]$Pattern,
        [Parameter(Mandatory = $true)][string]$Message
    )
    $script:assertions++
    $caught = $null
    try { & $Action } catch { $caught = $_ }
    if ($null -eq $caught) {
        throw "$Message did not fail closed."
    }
    if ([string]$caught.Exception.Message -notmatch $Pattern) {
        throw "$Message failed for the wrong reason: $($caught.Exception.Message)"
    }
}

function Invoke-Case {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][scriptblock]$Action
    )
    & $Action
    $script:cases++
}

function Get-TestFileHash {
    param([Parameter(Mandatory = $true)][string]$Path)
    $algorithm = [Security.Cryptography.SHA256]::Create()
    $stream = [IO.File]::OpenRead($Path)
    try {
        return ([BitConverter]::ToString(
                $algorithm.ComputeHash($stream))).Replace('-', '')
    } finally {
        $stream.Dispose()
        $algorithm.Dispose()
    }
}

function Get-TestTextHash {
    param([Parameter(Mandatory = $true)][string]$Text)
    $algorithm = [Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString($algorithm.ComputeHash(
                    [Text.Encoding]::UTF8.GetBytes($Text)))).Replace('-', '')
    } finally {
        $algorithm.Dispose()
    }
}

function Write-TestBytes {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Text
    )
    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Path))
    [IO.File]::WriteAllBytes($Path, [Text.Encoding]::UTF8.GetBytes($Text))
}

function Copy-TestObject {
    param([Parameter(Mandatory = $true)][object]$InputObject)
    $copy = [ordered]@{}
    foreach ($property in $InputObject.PSObject.Properties) {
        $copy[[string]$property.Name] = $property.Value
    }
    return [pscustomobject]$copy
}

function New-TestPlanReceipt {
    param(
        [Parameter(Mandatory = $true)][object]$Fixture,
        [Parameter(Mandatory = $true)][ValidateSet('Daddy', 'Cj')]
        [string]$Side
    )

    $runtimeGates = @(
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
    $markers = @(
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
    $isDaddy = $Side -ceq 'Daddy'
    $workingDirectory = if ($isDaddy) {
        $Fixture.DaddyDirectory
    } else {
        $Fixture.CjDirectory
    }
    $filePath = if ($isDaddy) { $Fixture.DaddyExe } else { $Fixture.CjExe }
    $controller = if ($isDaddy) { '0x1234/0x0001' } else { '0x1234/0x0002' }
    $profileXuid = if ($isDaddy) {
        'E000A1A152111111'
    } else {
        'E000B2B252222222'
    }
    $peerAddress = if ($isDaddy) { '127.34.34.34' } else { '127.17.17.17' }
    $argumentListBuilder = New-Object 'Collections.Generic.List[string]'
    foreach ($token in '--portable=true', '--hid=sdl',
            ("--hid_sdl_allowed_devices=$controller")) {
        $argumentListBuilder.Add($token)
    }
    if (-not $isDaddy) {
        $argumentListBuilder.Add('--hid_sdl_invert_right_x=true')
    }
    $gameArgument = if ($Fixture.GamePath -match '\s') {
        '"' + $Fixture.GamePath + '"'
    } else {
        $Fixture.GamePath
    }
    foreach ($token in
            ("--logged_profile_slot_0_xuid=$profileXuid"),
            '--network_mode=2', '--upnp=false',
            '--network_synthetic_loopback=true',
            '--api_address=http://127.0.0.1:36000/',
            ("--aot_runtime_peer_ipv4=$peerAddress"),
            '--aot_runtime_sa2=true',
            '--aot_runtime_leg_destination_repair=true',
            '--aot_runtime_xport_control_load_repair=true',
            '--apply_patches=true', '--auto_check_updates=false',
            '--log_level=2', $gameArgument) {
        $argumentListBuilder.Add($token)
    }
    $argumentTokens = $argumentListBuilder.ToArray()
    $argumentList = $argumentTokens -join ' '
    return [pscustomobject][ordered]@{
        SchemaVersion = [int]1
        Profile = 'B19-Runtime-Core-Acceptance'
        Side = $Side
        LaunchCapable = $false
        LaunchCapability = 'NONE_OFFLINE_PLAN_ONLY'
        RuntimeProof = 'SYNTHETIC FIXTURE - NO CANDIDATE RUNTIME PROOF'
        ProfileTrust = 'UNTRUSTED_SYNTHETIC_TEST_ONLY'
        ProductionPinVerified = $false
        ProfileSha256 = ('A' * 64)
        SourceCommit = ('a' * 40)
        SourceTree = ('b' * 40)
        XeniaBytes = [int64]([IO.FileInfo]::new($filePath).Length)
        XeniaSha256 = Get-TestFileHash -Path $filePath
        WorkingDirectory = $workingDirectory
        FilePath = $filePath
        Affinity = if ($isDaddy) { '00000003' } else { '0000000C' }
        Priority = 'High'
        ArgumentList = $argumentList
        ArgumentTokens = $argumentTokens
        ArgumentListSha256 = Get-TestTextHash -Text $argumentList
        TemplateSha256 = ('B' * 64)
        ArgumentCount = [int]$argumentTokens.Count
        OptionCount = [int]($argumentTokens.Count - 1)
        PatchCount = [int]3
        RuntimeGateStatus = 'PENDING_NOT_EXECUTED'
        PendingRuntimeGates = $runtimeGates
        RuntimeGateCount = [int]$runtimeGates.Count
        Sa2AcceptanceMarkerStatus = 'PENDING_NOT_EXECUTED'
        RequiredSa2AcceptanceMarkers = $markers
        Sa2AcceptanceMarkerCount = [int]$markers.Count
        GamePath = $Fixture.GamePath
        GameSha256 = Get-TestFileHash -Path $Fixture.GamePath
        GameHashVerified = $true
        SaveSlot = [int]1
        InstallRoot = $Fixture.InstallRoot
        CpuAllocationPolicy = 'WholeCoreTierSplitV1'
        CpuTopologySignature = ('C' * 64)
        ReservedCpuMask = '00000000'
        ProfileXuid = $profileXuid
        OnlineXuid = if ($isDaddy) {
            '0009000000000001'
        } else {
            '0009000000000002'
        }
        MacAddress = if ($isDaddy) { '7C1E52111111' } else { '7C1E52222222' }
        OwnHostAddress = if ($isDaddy) { '127.17.17.17' } else { '127.34.34.34' }
        PeerHostAddress = $peerAddress
        PlayerPort = if ($isDaddy) { [int]36274 } else { [int]36547 }
        Controller = $controller
        InvertRightX = -not $isDaddy
    }
}

function New-TestServiceSpec {
    param(
        [Parameter(Mandatory = $true)][object]$Fixture,
        [Parameter(Mandatory = $true)][ValidateSet('XWS', 'FESL')]
        [string]$Role
    )
    $isXws = $Role -ceq 'XWS'
    $filePath = if ($isXws) { $Fixture.NodeExe } else { $Fixture.PythonExe }
    $payloadPath = if ($isXws) { $Fixture.XwsPayload } else { $Fixture.FeslPayload }
    $secondArgument = if ($isXws) {
        '--listen=127.0.0.1'
    } else {
        '--seconds=7200'
    }
    $argumentTokens = @(
        ('"{0}"' -f $payloadPath),
        $secondArgument)
    $argumentList = $argumentTokens -join ' '
    return [pscustomobject][ordered]@{
        SchemaVersion = [int]1
        Role = $Role
        SpecTrust = 'UNTRUSTED_SYNTHETIC_TEST_ONLY'
        ProductionPinVerified = $false
        FilePath = $filePath
        ExecutableBytes = [int64]([IO.FileInfo]::new($filePath).Length)
        ExecutableSha256 = Get-TestFileHash -Path $filePath
        WorkingDirectory = if ($isXws) { $Fixture.XwsDirectory } else { $Fixture.FeslDirectory }
        ArgumentList = $argumentList
        ArgumentTokens = $argumentTokens
        ArgumentListSha256 = Get-TestTextHash -Text $argumentList
        ArgumentCount = [int]$argumentTokens.Count
        PayloadPath = $payloadPath
        PayloadBytes = [int64]([IO.FileInfo]::new($payloadPath).Length)
        PayloadSha256 = Get-TestFileHash -Path $payloadPath
        Affinity = if ($isXws) { '00000030' } else { '00000010' }
        Priority = 'High'
        NoWindow = $true
    }
}

function Set-TestProductionReceiptPins {
    param([Parameter(Mandatory = $true)][object]$Receipt)

    $Receipt.RuntimeProof =
        'SOURCE-BUILT CANDIDATE - RUNTIME ACCEPTANCE PENDING'
    $Receipt.ProfileTrust = 'PRODUCTION_REVIEWED_PROFILE'
    $Receipt.ProductionPinVerified = $true
    $Receipt.ProfileSha256 =
        '87987BECC70800C3D7CA3434E7BE15365A8E3053185E04121AE38525BFA5E891'
    $Receipt.SourceCommit = 'b8c0c49520e841a97309e7c742570c0a8769c4f6'
    $Receipt.SourceTree = '1194169c7723b1bbf314105c5255a7ea2e2e7c97'
    $Receipt.XeniaBytes = [int64]17942016
    $Receipt.XeniaSha256 =
        'E0AE2C785BC19637E83019FE921E0D3CEE83B229D1CDF9B82F6508A50336C629'
    $Receipt.GameSha256 =
        '7C2008F53D4569D4079311B36CF2555E5FDC26B48A2C2E3578580B9F07EC16EF'
    $Receipt.TemplateSha256 =
        'FCDFFB2CB25300BF32D19AE64DB62A7343FF330EA4FFF9A22390AA8B7738FB2E'
}

function New-TestFixture {
    $root = Join-Path $script:tempRoot (
        'AotOwnedProcess-{0}' -f [Guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($root)
    $script:fixtureRoots.Add($root)
    $installRoot = Join-Path $root 'portable'
    $daddyDirectory = Join-Path $installRoot 'rigs\daddy'
    $cjDirectory = Join-Path $installRoot 'rigs\cj'
    $xwsDirectory = Join-Path $installRoot 'services\xws'
    $feslDirectory = Join-Path $installRoot 'services\fesl'
    $daddyExe = Join-Path $daddyDirectory 'xenia.exe'
    $cjExe = Join-Path $cjDirectory 'xenia.exe'
    $nodeExe = Join-Path $installRoot 'tools\node.exe'
    $pythonExe = Join-Path $installRoot 'tools\python.exe'
    $xwsPayload = Join-Path $xwsDirectory 'server.js'
    $feslPayload = Join-Path $feslDirectory 'fesl.py'
    $gamePath = Join-Path $installRoot 'game\aot.iso'
    Write-TestBytes -Path $daddyExe -Text 'synthetic-xenia-image'
    Write-TestBytes -Path $cjExe -Text 'synthetic-xenia-image'
    Write-TestBytes -Path $nodeExe -Text 'synthetic-node-image'
    Write-TestBytes -Path $pythonExe -Text 'synthetic-python-image'
    Write-TestBytes -Path $xwsPayload -Text 'synthetic-xws-payload'
    Write-TestBytes -Path $feslPayload -Text 'synthetic-fesl-payload'
    Write-TestBytes -Path $gamePath -Text 'synthetic-game-image'
    $fixture = [pscustomobject]@{
        Root = $root
        RunRoot = Join-Path $root 'runs'
        InstallRoot = $installRoot
        DaddyDirectory = $daddyDirectory
        CjDirectory = $cjDirectory
        XwsDirectory = $xwsDirectory
        FeslDirectory = $feslDirectory
        DaddyExe = $daddyExe
        CjExe = $cjExe
        NodeExe = $nodeExe
        PythonExe = $pythonExe
        XwsPayload = $xwsPayload
        FeslPayload = $feslPayload
        GamePath = $gamePath
    }
    [void][IO.Directory]::CreateDirectory($fixture.RunRoot)
    $fixture | Add-Member -NotePropertyName DaddyPlan `
        -NotePropertyValue (New-TestPlanReceipt -Fixture $fixture -Side Daddy)
    $fixture | Add-Member -NotePropertyName CjPlan `
        -NotePropertyValue (New-TestPlanReceipt -Fixture $fixture -Side Cj)
    $fixture | Add-Member -NotePropertyName XwsSpec `
        -NotePropertyValue (New-TestServiceSpec -Fixture $fixture -Role XWS)
    $fixture | Add-Member -NotePropertyName FeslSpec `
        -NotePropertyValue (New-TestServiceSpec -Fixture $fixture -Role FESL)
    return $fixture
}

function Get-TestAdapterRecord {
    param($State, $Created)
    return $State.Records[[string]$Created.ProcessId]
}

function New-TestAdapter {
    $state = [pscustomobject]@{
        Events = New-Object 'Collections.Generic.List[string]'
        Records = @{}
        NextPid = [uint32]7100
        NextFileTime = [uint64]133800000000000000
        CommitCount = 0
        CurrentLedgerPath = $null
        FailCommitNumber = 0
        FailContractRole = $null
        IdentityMismatchRole = $null
        IdentityCalls = @{}
        IdentityMismatchOnCall = @{}
        IdentityPathMismatchRole = $null
        ResumeResultRole = $null
        ResumeResult = [uint32]1
        ResumeSawLedgered = @{}
        CreateSawLaunchIntent = @{}
        CreatedArguments = @{}
        Foreground = [IntPtr]900
        ForegroundChangeOnRead = 0
        ForegroundReads = 0
        WindowByRole = @{}
        ExitDuringFindWindows = @{}
        WindowPidCalls = @{}
        WindowPidMismatchOnCall = @{}
        IsAliveCalls = @{}
        ExitOnIsAliveCall = @{}
        ExitAfterWindowOperation = @{}
        CloseExitsRole = @{}
        TerminateFailuresRemaining = @{}
        TerminateAttempts = @{}
        TerminatedRoles = New-Object 'Collections.Generic.List[string]'
        ClosedProcessRoles = New-Object 'Collections.Generic.List[string]'
    }
    return [pscustomobject][ordered]@{
        Kind = 'SyntheticV1'
        IsSynthetic = $true
        State = $state
        UtcNow = {
            param($self)
            return [DateTime]::Parse('2026-08-28T12:00:00Z').AddSeconds(
                $self.State.Events.Count)
        }
        HashFile = {
            param($self, [string]$path)
            $self.State.Events.Add('Hash:' + [IO.Path]::GetFileName($path))
            return Get-TestFileHash -Path $path
        }
        FileLength = {
            param($self, [string]$path)
            $self.State.Events.Add('Length:' + [IO.Path]::GetFileName($path))
            return [int64]([IO.FileInfo]::new($path).Length)
        }
        CreateSuspended = {
            param($self, $spec)
            $role = [string]$spec.Role
            $self.State.Events.Add("CreateSuspended:$role")
            $sawIntent = $false
            if ([IO.File]::Exists([string]$self.State.CurrentLedgerPath)) {
                $ledger = Get-Content -Raw `
                    -LiteralPath ([string]$self.State.CurrentLedgerPath) |
                    ConvertFrom-Json
                $matchingIntent = @($ledger.Entries | Where-Object {
                        $_.Role -ceq $role -and
                        $_.State -ceq 'LaunchIntent'
                    })
                $sawIntent = $matchingIntent.Count -eq 1
            }
            $self.State.CreateSawLaunchIntent[$role] = $sawIntent
            $processId = [uint32]$self.State.NextPid
            $self.State.NextPid = [uint32]($processId + 1)
            $fileTime = [uint64]$self.State.NextFileTime
            $self.State.NextFileTime = [uint64]($fileTime + 10000000)
            $created = [pscustomobject]@{
                Role = $role
                ProcessId = $processId
                ProcessHandle = "process-handle-$processId"
                ThreadHandle = "thread-handle-$processId"
            }
            $self.State.Records[[string]$processId] = [pscustomobject]@{
                Role = $role
                Pid = $processId
                FileTime = $fileTime
                ImagePath = [string]$spec.FilePath
                Alive = $true
                Created = $created
            }
            $self.State.WindowByRole[$role] = [IntPtr]($processId + 10000)
            $self.State.CreatedArguments[$role] = [string]$spec.ArgumentList
            return $created
        }
        GetIdentity = {
            param($self, $created)
            $record = Get-TestAdapterRecord -State $self.State -Created $created
            $self.State.Events.Add("Identity:$($record.Role)")
            $role = [string]$record.Role
            $identityCalls = if ($self.State.IdentityCalls.ContainsKey($role)) {
                [int]$self.State.IdentityCalls[$role] + 1
            } else { 1 }
            $self.State.IdentityCalls[$role] = $identityCalls
            $fileTime = [uint64]$record.FileTime
            if ([string]$self.State.IdentityMismatchRole -ceq
                    $role -or
                ($self.State.IdentityMismatchOnCall.ContainsKey($role) -and
                    [int]$self.State.IdentityMismatchOnCall[$role] -eq
                        $identityCalls)) {
                $fileTime++
            }
            $path = [string]$record.ImagePath
            if ([string]$self.State.IdentityPathMismatchRole -ceq
                [string]$record.Role) {
                $path = Join-Path ([IO.Path]::GetDirectoryName($path)) 'foreign.exe'
            }
            return [pscustomobject]@{
                ProcessId = [uint32]$record.Pid
                CreationFileTime = $fileTime
                StartTimeUtc = [DateTime]::FromFileTimeUtc([int64]$record.FileTime)
                ImagePath = $path
            }
        }
        SetContract = {
            param($self, $created, [string]$affinity, [string]$priority)
            $record = Get-TestAdapterRecord -State $self.State -Created $created
            $self.State.Events.Add(
                "SetContract:$($record.Role):${affinity}:${priority}")
            if ([string]$self.State.FailContractRole -ceq [string]$record.Role) {
                throw 'synthetic contract failure'
            }
            return [pscustomobject]@{
                Affinity = [Convert]::ToUInt64($affinity, 16)
                PriorityClass = [uint32]0x80
            }
        }
        Resume = {
            param($self, $created)
            $record = Get-TestAdapterRecord -State $self.State -Created $created
            $role = [string]$record.Role
            $self.State.Events.Add("Resume:$role")
            $ledgerPath = [string]$self.State.CurrentLedgerPath
            $saw = $false
            if ([IO.File]::Exists($ledgerPath)) {
                $ledger = Get-Content -Raw -LiteralPath $ledgerPath |
                    ConvertFrom-Json
                $matching = @($ledger.Entries | Where-Object {
                        $_.Role -ceq $role -and $_.State -ceq 'Ledgered'
                    })
                $saw = $matching.Count -eq 1
            }
            $self.State.ResumeSawLedgered[$role] = $saw
            if ([string]$self.State.ResumeResultRole -ceq $role) {
                return [uint32]$self.State.ResumeResult
            }
            return [uint32]1
        }
        CloseThreadHandle = {
            param($self, $created)
            $record = Get-TestAdapterRecord -State $self.State -Created $created
            $self.State.Events.Add("CloseThread:$($record.Role)")
            $created.ThreadHandle = $null
        }
        CloseProcessHandle = {
            param($self, $created)
            $record = Get-TestAdapterRecord -State $self.State -Created $created
            $self.State.Events.Add("CloseProcess:$($record.Role)")
            $self.State.ClosedProcessRoles.Add([string]$record.Role)
            $created.ProcessHandle = $null
        }
        IsAlive = {
            param($self, $created)
            $record = Get-TestAdapterRecord -State $self.State -Created $created
            $role = [string]$record.Role
            $calls = if ($self.State.IsAliveCalls.ContainsKey($role)) {
                [int]$self.State.IsAliveCalls[$role] + 1
            } else { 1 }
            $self.State.IsAliveCalls[$role] = $calls
            $self.State.Events.Add("IsAlive:${role}:$calls")
            if ($self.State.ExitOnIsAliveCall.ContainsKey($role) -and
                [int]$self.State.ExitOnIsAliveCall[$role] -eq $calls) {
                $record.Alive = $false
            }
            return [bool]$record.Alive
        }
        FindWindows = {
            param($self, [uint32]$processId)
            $record = $self.State.Records[[string]$processId]
            $self.State.Events.Add("FindWindows:$($record.Role)")
            if ($self.State.ExitDuringFindWindows.ContainsKey(
                    [string]$record.Role) -and
                [bool]$self.State.ExitDuringFindWindows[
                    [string]$record.Role]) {
                $record.Alive = $false
            }
            return [IntPtr]$self.State.WindowByRole[[string]$record.Role]
        }
        GetWindowProcessId = {
            param($self, [IntPtr]$window)
            foreach ($record in $self.State.Records.Values) {
                if ([IntPtr]$self.State.WindowByRole[[string]$record.Role] -eq
                    $window) {
                    $role = [string]$record.Role
                    $calls = if ($self.State.WindowPidCalls.ContainsKey($role)) {
                        [int]$self.State.WindowPidCalls[$role] + 1
                    } else { 1 }
                    $self.State.WindowPidCalls[$role] = $calls
                    $self.State.Events.Add("WindowPid:${role}:$calls")
                    if ($self.State.WindowPidMismatchOnCall.ContainsKey($role) -and
                        [int]$self.State.WindowPidMismatchOnCall[$role] -eq
                            $calls) {
                        return [uint32]([uint32]$record.Pid + 99)
                    }
                    return [uint32]$record.Pid
                }
            }
            return [uint32]0
        }
        GetForegroundWindow = {
            param($self)
            $self.State.ForegroundReads++
            $self.State.Events.Add('GetForeground')
            if ([int]$self.State.ForegroundChangeOnRead -eq
                [int]$self.State.ForegroundReads) {
                return [IntPtr]([int64]$self.State.Foreground + 1)
            }
            return [IntPtr]$self.State.Foreground
        }
        PlaceHidden = {
            param($self, [IntPtr]$window, $rectangle)
            $self.State.Events.Add("PlaceHidden:$window")
            foreach ($record in $self.State.Records.Values) {
                if ([IntPtr]$self.State.WindowByRole[[string]$record.Role] -eq
                    $window -and
                    [string]$self.State.ExitAfterWindowOperation[
                        [string]$record.Role] -ceq 'PlaceHidden') {
                    $record.Alive = $false
                }
            }
        }
        RevealNoActivate = {
            param($self, [IntPtr]$window)
            $self.State.Events.Add("RevealNoActivate:$window")
            foreach ($record in $self.State.Records.Values) {
                if ([IntPtr]$self.State.WindowByRole[[string]$record.Role] -eq
                    $window -and
                    [string]$self.State.ExitAfterWindowOperation[
                        [string]$record.Role] -ceq 'RevealNoActivate') {
                    $record.Alive = $false
                }
            }
        }
        PlaceVisibleNoActivate = {
            param($self, [IntPtr]$window, $rectangle)
            $self.State.Events.Add("PlaceVisibleNoActivate:$window")
            foreach ($record in $self.State.Records.Values) {
                if ([IntPtr]$self.State.WindowByRole[[string]$record.Role] -eq
                    $window -and
                    [string]$self.State.ExitAfterWindowOperation[
                        [string]$record.Role] -ceq
                            'PlaceVisibleNoActivate') {
                    $record.Alive = $false
                }
            }
        }
        RequestClose = {
            param($self, [IntPtr]$window)
            foreach ($record in $self.State.Records.Values) {
                if ([IntPtr]$self.State.WindowByRole[[string]$record.Role] -eq
                    $window) {
                    $role = [string]$record.Role
                    $self.State.Events.Add("RequestClose:$role")
                    if ($self.State.CloseExitsRole.ContainsKey($role) -and
                        [bool]$self.State.CloseExitsRole[$role]) {
                        $record.Alive = $false
                    }
                    return
                }
            }
            throw 'unknown synthetic window'
        }
        WaitExit = {
            param($self, $created, [int]$milliseconds)
            $record = Get-TestAdapterRecord -State $self.State -Created $created
            $self.State.Events.Add("WaitExit:$($record.Role):$milliseconds")
            return -not [bool]$record.Alive
        }
        Terminate = {
            param($self, $created, [uint32]$exitCode)
            $record = Get-TestAdapterRecord -State $self.State -Created $created
            $role = [string]$record.Role
            $attempts = if ($self.State.TerminateAttempts.ContainsKey($role)) {
                [int]$self.State.TerminateAttempts[$role] + 1
            } else { 1 }
            $self.State.TerminateAttempts[$role] = $attempts
            $self.State.Events.Add("Terminate:${role}:$attempts")
            if ($self.State.TerminateFailuresRemaining.ContainsKey($role) -and
                [int]$self.State.TerminateFailuresRemaining[$role] -gt 0) {
                $self.State.TerminateFailuresRemaining[$role] =
                    [int]$self.State.TerminateFailuresRemaining[$role] - 1
                throw 'synthetic terminate failure'
            }
            $self.State.TerminatedRoles.Add($role)
            $record.Alive = $false
        }
        CommitLedger = {
            param($self, [string]$path, [string]$json, [string]$token)
            $self.State.CommitCount++
            $self.State.CurrentLedgerPath = $path
            $self.State.Events.Add("Commit:$($self.State.CommitCount)")
            if ([int]$self.State.FailCommitNumber -eq
                [int]$self.State.CommitCount) {
                throw 'synthetic ledger commit failure'
            }
            [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($path))
            $temporary = "$path.$token.synthetic.tmp"
            [IO.File]::WriteAllText($temporary, $json,
                [Text.UTF8Encoding]::new($false))
            if ([IO.File]::Exists($path)) {
                $backup = "$path.$token.synthetic.bak"
                [IO.File]::Replace($temporary, $path, $backup, $true)
                if ([IO.File]::Exists($backup)) {
                    [IO.File]::Delete($backup)
                }
            } else {
                [IO.File]::Move($temporary, $path)
            }
        }
    }
}

function New-TestContext {
    param(
        [Parameter(Mandatory = $true)][object]$Fixture,
        [Parameter(Mandatory = $true)][object]$Adapter
    )
    $pair = Assert-AotOwnedPlanPair -Daddy $Fixture.DaddyPlan `
        -Cj $Fixture.CjPlan -SyntheticFixture
    $services = Assert-AotOwnedServiceSpecs `
        -ServiceSpec @($Fixture.XwsSpec, $Fixture.FeslSpec) -SyntheticFixture
    return New-AotOwnedRunContext -RunRoot $Fixture.RunRoot `
        -PlanPair $pair -ServiceSpecs $services -Adapter $Adapter `
        -SyntheticFixture
}

function New-TestProductionAdapter {
    return & $script:ownedModule { New-AotOwnedProductionAdapter }
}

try {
    Invoke-Case 'cryptographic token and source policy' {
        $first = New-AotOwnedRunToken
        $second = New-AotOwnedRunToken
        Assert-True ($first -cmatch '^[0-9A-F]{32}$') `
            'Run token is not canonical 128-bit hex.'
        Assert-True ($first -cne $second) 'Run tokens unexpectedly repeated.'
        $source = Get-Content -Raw -LiteralPath $modulePath
        foreach ($forbidden in 'Start-Process', 'Stop-Process', 'taskkill',
                'SetForegroundWindow', 'AppActivate', 'SendKeys') {
            Assert-True ($source.IndexOf($forbidden,
                    [StringComparison]::OrdinalIgnoreCase) -lt 0) `
                "Production module contains forbidden primitive $forbidden."
        }
        Assert-True ($source.Contains('CreateProcessW')) `
            'Production module does not use CreateProcessW.'
        Assert-True ($source.Contains('CREATE_SUSPENDED')) `
            'Production module does not create suspended.'
    }

    Invoke-Case 'production adapter is private and every callback is inert' {
        Assert-True (-not $script:ownedModule.ExportedFunctions.ContainsKey(
                'New-AotOwnedProductionAdapter')) `
            'Production adapter constructor remains exported.'
        $source = Get-Content -Raw -LiteralPath $modulePath
        $exportOffset = $source.LastIndexOf('Export-ModuleMember',
            [StringComparison]::Ordinal)
        Assert-True ($exportOffset -ge 0) `
            'Module export declaration is absent.'
        $exportText = $source.Substring($exportOffset)
        Assert-True ($exportText.IndexOf('New-AotOwnedProductionAdapter',
                [StringComparison]::Ordinal) -lt 0) `
            'Static export list exposes the production adapter constructor.'

        $nativeTypeBefore = 'AotOwnedProcessNativeV1' -as [type]
        $adapter = New-TestProductionAdapter
        Assert-Equal $adapter.Kind 'WindowsNativeV1' `
            'Production adapter kind differs.'
        Assert-True (-not [bool]$adapter.IsSynthetic) `
            'Production adapter is incorrectly synthetic.'
        foreach ($methodName in 'UtcNow', 'HashFile', 'FileLength',
                'CreateSuspended', 'GetIdentity', 'SetContract', 'Resume',
                'CloseThreadHandle', 'CloseProcessHandle', 'IsAlive',
                'FindWindows', 'GetWindowProcessId', 'GetForegroundWindow',
                'PlaceHidden', 'RevealNoActivate',
                'PlaceVisibleNoActivate', 'RequestClose', 'WaitExit',
                'Terminate', 'CommitLedger') {
            $callback = $adapter.PSObject.Properties[$methodName].Value
            Assert-True ($callback -is [scriptblock]) `
                "Production adapter lacks inert callback $methodName."
            Assert-Throws {
                & $callback $adapter $null $null $null
            } '^PRODUCTION_LAUNCH_CLOSURE_DEFERRED$' `
                "Direct production callback $methodName"
        }
        $nativeTypeAfter = 'AotOwnedProcessNativeV1' -as [type]
        Assert-True ($null -eq $nativeTypeBefore -and
                $null -eq $nativeTypeAfter) `
            'Inert production adapter initialized the native process type.'
    }

    Invoke-Case 'exact synthetic plan and service contracts validate' {
        $fixture = New-TestFixture
        $pair = Assert-AotOwnedPlanPair -Daddy $fixture.DaddyPlan `
            -Cj $fixture.CjPlan -SyntheticFixture
        $services = Assert-AotOwnedServiceSpecs `
            -ServiceSpec @($fixture.XwsSpec, $fixture.FeslSpec) `
            -SyntheticFixture
        Assert-Equal $pair.Contract 'AOT_OWNED_PLAN_PAIR_V1' `
            'Plan pair contract differs.'
        Assert-Equal $pair.TrustMode 'SYNTHETIC_TEST_ONLY' `
            'Plan pair trust label differs.'
        Assert-Equal $pair.Specs.Count 2 'Plan pair role count differs.'
        Assert-Equal $services.Specs.Count 2 'Service role count differs.'
        Assert-Equal $services.Specs.XWS.ProcessClass 'Service' `
            'XWS normalized class differs.'
        Assert-True ($pair.PlanFingerprintSha256 -cmatch
                '^[0-9A-F]{64}$') 'Plan fingerprint is not canonical.'
    }

    Invoke-Case 'production planner receipts require every exact reviewed pin' {
        $fixture = New-TestFixture
        $daddy = Copy-TestObject $fixture.DaddyPlan
        $cj = Copy-TestObject $fixture.CjPlan
        Set-TestProductionReceiptPins -Receipt $daddy
        Set-TestProductionReceiptPins -Receipt $cj
        $pair = Assert-AotOwnedPlanPair -Daddy $daddy -Cj $cj
        Assert-Equal $pair.TrustMode 'PRODUCTION_PINNED' `
            'Exact production receipt pair trust differs.'
        $daddy.ProfileSha256 = 'D' * 64
        $cj.ProfileSha256 = 'D' * 64
        Assert-Throws {
            Assert-AotOwnedPlanPair -Daddy $daddy -Cj $cj
        } 'exact reviewed production pins' `
            'Shape-valid but unreviewed production profile pin'
        Set-TestProductionReceiptPins -Receipt $daddy
        Set-TestProductionReceiptPins -Receipt $cj
        $daddy.TemplateSha256 = 'E' * 64
        $cj.TemplateSha256 = 'E' * 64
        Assert-Throws {
            Assert-AotOwnedPlanPair -Daddy $daddy -Cj $cj
        } 'exact reviewed production pins' `
            'Shape-valid but unreviewed production template pin'
    }

    Invoke-Case 'plan schema, case, argument, and pair mutations fail closed' {
        $fixture = New-TestFixture
        $extra = Copy-TestObject $fixture.DaddyPlan
        $extra | Add-Member -NotePropertyName Extra -NotePropertyValue 1
        Assert-Throws {
            Assert-AotOwnedPlanPair -Daddy $extra -Cj $fixture.CjPlan `
                -SyntheticFixture
        } 'exactly|unknown' 'Extra planner property'
        $wrongCase = Copy-TestObject $fixture.DaddyPlan
        $value = $wrongCase.Profile
        $wrongCase.PSObject.Properties.Remove('Profile')
        $wrongCase | Add-Member -NotePropertyName profile `
            -NotePropertyValue $value -Force
        Assert-Throws {
            Assert-AotOwnedPlanPair -Daddy $wrongCase -Cj $fixture.CjPlan `
                -SyntheticFixture
        } 'incorrectly-cased|missing' 'Incorrectly-cased planner property'
        $argument = Copy-TestObject $fixture.DaddyPlan
        $argument.ArgumentList = [string]$argument.ArgumentList + ' --tamper'
        Assert-Throws {
            Assert-AotOwnedPlanPair -Daddy $argument -Cj $fixture.CjPlan `
                -SyntheticFixture
        } 'exact ordered token join|SHA-256' 'Tampered argument receipt'
        $peer = Copy-TestObject $fixture.CjPlan
        $peer.PeerHostAddress = '127.99.99.99'
        $peer.ArgumentTokens = @($peer.ArgumentTokens)
        $peer.ArgumentTokens[9] =
            '--aot_runtime_peer_ipv4=127.99.99.99'
        $peer.ArgumentList = $peer.ArgumentTokens -join ' '
        $peer.ArgumentListSha256 = Get-TestTextHash -Text $peer.ArgumentList
        Assert-Throws {
            Assert-AotOwnedPlanPair -Daddy $fixture.DaddyPlan -Cj $peer `
                -SyntheticFixture
        } 'reciprocal' 'Nonreciprocal planner pair'
        $overlap = Copy-TestObject $fixture.CjPlan
        $overlap.Affinity = '00000002'
        Assert-Throws {
            Assert-AotOwnedPlanPair -Daddy $fixture.DaddyPlan -Cj $overlap `
                -SyntheticFixture
        } 'overlap' 'Overlapping Xenia masks'
        $outsideGamePath = Join-Path ([Environment]::SystemDirectory) `
            'kernel32.dll'
        Assert-True ([IO.File]::Exists($outsideGamePath)) `
            'Known outside-root test file is absent.'
        $outsideGameSha256 = Get-TestFileHash -Path $outsideGamePath
        $outsideGameArgument = if ($outsideGamePath -match '\s') {
            '"' + $outsideGamePath + '"'
        } else {
            $outsideGamePath
        }
        $outsideDaddy = Copy-TestObject $fixture.DaddyPlan
        $outsideCj = Copy-TestObject $fixture.CjPlan
        foreach ($outsidePlan in $outsideDaddy, $outsideCj) {
            $outsidePlan.GamePath = $outsideGamePath
            $outsidePlan.GameSha256 = $outsideGameSha256
            $outsidePlan.ArgumentTokens = @(
                @($outsidePlan.ArgumentTokens)[0..(
                    @($outsidePlan.ArgumentTokens).Count - 2)] +
                @($outsideGameArgument))
            $outsidePlan.ArgumentList = $outsidePlan.ArgumentTokens -join ' '
            $outsidePlan.ArgumentListSha256 = Get-TestTextHash `
                -Text $outsidePlan.ArgumentList
        }
        Assert-Throws {
            Assert-AotOwnedPlanPair -Daddy $outsideDaddy `
                -Cj $outsideCj -SyntheticFixture
        } 'trusted synthetic root' 'Synthetic planner path escape'
    }

    Invoke-Case 'service schema rejects unknown roles, duplicates, and trust drift' {
        $fixture = New-TestFixture
        $mongo = Copy-TestObject $fixture.XwsSpec
        $mongo.Role = 'MongoDB'
        Assert-Throws {
            Assert-AotOwnedServiceSpecs `
                -ServiceSpec @($mongo, $fixture.FeslSpec) -SyntheticFixture
        } 'XWS/FESL' 'MongoDB ownership request'
        Assert-Throws {
            Assert-AotOwnedServiceSpecs `
                -ServiceSpec @($fixture.XwsSpec, $fixture.XwsSpec) `
                -SyntheticFixture
        } 'duplicate' 'Duplicate service role'
        $trust = Copy-TestObject $fixture.FeslSpec
        $trust.ProductionPinVerified = $true
        Assert-Throws {
            Assert-AotOwnedServiceSpecs `
                -ServiceSpec @($fixture.XwsSpec, $trust) -SyntheticFixture
        } 'explicitly synthetic' 'Synthetic service trust drift'
        $outside = Copy-TestObject $fixture.XwsSpec
        $outsidePayloadPath = Join-Path ([Environment]::SystemDirectory) `
            'kernel32.dll'
        Assert-True ([IO.File]::Exists($outsidePayloadPath)) `
            'Known outside-root service payload is absent.'
        $outside.PayloadPath = $outsidePayloadPath
        $outside.PayloadBytes =
            [int64]([IO.FileInfo]::new($outsidePayloadPath).Length)
        $outside.PayloadSha256 = Get-TestFileHash -Path $outsidePayloadPath
        $outside.WorkingDirectory = [Environment]::SystemDirectory
        $outsidePayloadArgument = if ($outsidePayloadPath -match '\s') {
            '"' + $outsidePayloadPath + '"'
        } else {
            $outsidePayloadPath
        }
        $outside.ArgumentTokens = @(
            $outsidePayloadArgument,
            [string]$outside.ArgumentTokens[1])
        $outside.ArgumentList = $outside.ArgumentTokens -join ' '
        $outside.ArgumentListSha256 = Get-TestTextHash `
            -Text $outside.ArgumentList
        Assert-Throws {
            Assert-AotOwnedServiceSpecs `
                -ServiceSpec @($outside, $fixture.FeslSpec) -SyntheticFixture
        } 'trusted synthetic root' 'Synthetic service path escape'
        $productionXws = Copy-TestObject $fixture.XwsSpec
        $productionFesl = Copy-TestObject $fixture.FeslSpec
        foreach ($productionSpec in $productionXws, $productionFesl) {
            $productionSpec.SpecTrust = 'PRODUCTION_REVIEWED_SERVICE_SPEC'
            $productionSpec.ProductionPinVerified = $true
        }
        Assert-Throws {
            Assert-AotOwnedServiceSpecs `
                -ServiceSpec @($productionXws, $productionFesl)
        } 'PRODUCTION_SERVICE_AUTHORITY_DEFERRED' `
            'Self-asserted production service authority'
    }

    Invoke-Case 'synthetic context is temp-confined and atomically initialized' {
        $fixture = New-TestFixture
        $adapter = New-TestAdapter
        $context = New-TestContext -Fixture $fixture -Adapter $adapter
        Assert-True ([IO.File]::Exists($context.LedgerPath)) `
            'Initial ownership ledger is absent.'
        $ledger = Get-Content -Raw -LiteralPath $context.LedgerPath |
            ConvertFrom-Json
        Assert-Equal $ledger.Status 'Intent' 'Initial ledger state differs.'
        Assert-Equal $ledger.TrustMode 'SYNTHETIC_TEST_ONLY' `
            'Initial ledger trust label differs.'
        Assert-Equal @($ledger.Entries).Count 0 `
            'Initial ledger unexpectedly owns a process.'
        $pair = Assert-AotOwnedPlanPair -Daddy $fixture.DaddyPlan `
            -Cj $fixture.CjPlan -SyntheticFixture
        $services = Assert-AotOwnedServiceSpecs `
            -ServiceSpec @($fixture.XwsSpec, $fixture.FeslSpec) `
            -SyntheticFixture
        $outsideRunRoot = [Environment]::SystemDirectory
        Assert-True ([IO.Directory]::Exists($outsideRunRoot)) `
            'Known outside-root run directory is absent.'
        Assert-Throws {
            New-AotOwnedRunContext -RunRoot $outsideRunRoot -PlanPair $pair `
                -ServiceSpecs $services -Adapter $adapter -SyntheticFixture
        } 'trusted synthetic root' 'Synthetic RunRoot escape'
        $production = New-TestProductionAdapter
        Assert-Throws {
            New-AotOwnedRunContext -RunRoot $fixture.RunRoot `
                -PlanPair $pair -ServiceSpecs $services `
                -Adapter $production -SyntheticFixture
        } 'SyntheticV1' 'Production adapter used as synthetic'
    }

    Invoke-Case 'relative paths fail before normalization' {
        $fixture = New-TestFixture
        $relativePlan = Copy-TestObject $fixture.DaddyPlan
        $relativePlan.WorkingDirectory = 'rigs\relative-daddy'
        Assert-Throws {
            Assert-AotOwnedPlanPair -Daddy $relativePlan `
                -Cj $fixture.CjPlan -SyntheticFixture
        } 'absolute before normalization' 'Relative planner working directory'
        $relativeService = Copy-TestObject $fixture.XwsSpec
        $relativeService.FilePath = 'tools\node.exe'
        Assert-Throws {
            Assert-AotOwnedServiceSpecs -ServiceSpec @(
                $relativeService, $fixture.FeslSpec) -SyntheticFixture
        } 'absolute before normalization' 'Relative service executable'
        $adapter = New-TestAdapter
        $pair = Assert-AotOwnedPlanPair -Daddy $fixture.DaddyPlan `
            -Cj $fixture.CjPlan -SyntheticFixture
        $services = Assert-AotOwnedServiceSpecs -ServiceSpec @(
            $fixture.XwsSpec, $fixture.FeslSpec) -SyntheticFixture
        Assert-Throws {
            New-AotOwnedRunContext -RunRoot 'relative-runs' `
                -PlanPair $pair -ServiceSpecs $services -Adapter $adapter `
                -SyntheticFixture
        } 'absolute before normalization' 'Relative run root'
    }

    Invoke-Case 'production ownership remains explicitly hard blocked' {
        $fixture = New-TestFixture
        $adapter = New-TestAdapter
        $pair = Assert-AotOwnedPlanPair -Daddy $fixture.DaddyPlan `
            -Cj $fixture.CjPlan -SyntheticFixture
        $services = Assert-AotOwnedServiceSpecs -ServiceSpec @(
            $fixture.XwsSpec, $fixture.FeslSpec) -SyntheticFixture
        $pair.SyntheticFixture = $false
        $pair.TrustMode = 'PRODUCTION_PINNED'
        $services.SyntheticFixture = $false
        $services.TrustMode = 'PRODUCTION_PINNED'
        Assert-Throws {
            New-AotOwnedRunContext -RunRoot $fixture.RunRoot `
                -PlanPair $pair -ServiceSpecs $services -Adapter $adapter
        } 'PRODUCTION_LAUNCH_CLOSURE_DEFERRED' `
            'Production context without retained patch/image closure'

        $fixture2 = New-TestFixture
        $adapter2 = New-TestAdapter
        $context = New-TestContext -Fixture $fixture2 -Adapter $adapter2
        $context.TrustMode = 'PRODUCTION_PINNED'
        $context.SyntheticFixture = $false
        Assert-Throws {
            Start-AotOwnedProcess -Context $context -Role Daddy
        } 'PRODUCTION_LAUNCH_CLOSURE_DEFERRED' `
            'Production Xenia start bypass'
        Assert-True (-not (@($adapter2.State.Events) -contains
                'CreateSuspended:Daddy')) `
            'Hard-blocked production context reached process creation.'
    }

    Invoke-Case 'private adapter anchor rejects replacement before callbacks' {
        $fixture = New-TestFixture
        $adapter = New-TestAdapter
        $context = New-TestContext -Fixture $fixture -Adapter $adapter
        $replacement = New-TestAdapter
        $replacement.Kind = 'WindowsNativeV1'
        $replacement.IsSynthetic = $false
        $originalEvents = $adapter.State.Events.Count
        $replacementEvents = $replacement.State.Events.Count
        $context.Adapter = $replacement
        Assert-Throws {
            Start-AotOwnedProcess -Context $context -Role Daddy
        } 'ADAPTER_BINDING_MISMATCH' 'Production-labeled adapter replacement'
        Assert-Equal $adapter.State.Events.Count $originalEvents `
            'Adapter replacement invoked the original adapter.'
        Assert-Equal $replacement.State.Events.Count $replacementEvents `
            'Adapter replacement invoked the replacement adapter.'

        $fixture2 = New-TestFixture
        $adapter2 = New-TestAdapter
        $context2 = New-TestContext -Fixture $fixture2 -Adapter $adapter2
        [void](Start-AotOwnedProcess -Context $context2 -Role Daddy)
        $replacement2 = New-TestAdapter
        $context2.Adapter = $replacement2
        $originalEvents2 = $adapter2.State.Events.Count
        $replacementEvents2 = $replacement2.State.Events.Count
        Assert-Throws {
            Test-AotOwnedProcessLiveness -Context $context2 -Role Daddy
        } 'ADAPTER_BINDING_MISMATCH' 'Liveness adapter replacement'
        Assert-Throws {
            Set-AotOwnedProcessContract -Context $context2 -Role Daddy
        } 'ADAPTER_BINDING_MISMATCH' 'Contract adapter replacement'
        $rectangle = [pscustomobject][ordered]@{
            X = [int]0; Y = [int]0; Width = [int]1280; Height = [int]720
        }
        Assert-Throws {
            Show-AotOwnedWindowNoActivate -Context $context2 -Role Daddy `
                -Rectangle $rectangle
        } 'ADAPTER_BINDING_MISMATCH' 'Window adapter replacement'
        Assert-Throws {
            Stop-AotOwnedRun -Context $context2 -GracefulTimeoutMs 0 `
                -TerminateTimeoutMs 1
        } 'ADAPTER_BINDING_MISMATCH' 'Cleanup adapter replacement'
        Assert-Equal $adapter2.State.Events.Count $originalEvents2 `
            'Rejected operations invoked the original adapter.'
        Assert-Equal $replacement2.State.Events.Count $replacementEvents2 `
            'Rejected operations invoked the replacement adapter.'
        $context2.Adapter = $adapter2
        [void](Stop-AotOwnedRun -Context $context2 -GracefulTimeoutMs 0 `
            -TerminateTimeoutMs 1)

        $fixture3 = New-TestFixture
        $adapter3 = New-TestAdapter
        $context3 = New-TestContext -Fixture $fixture3 -Adapter $adapter3
        $eventsBeforeMutation = $adapter3.State.Events.Count
        $adapter3.CreateSuspended = { throw 'MUTATED_CALLBACK_REACHED' }
        Assert-Throws {
            Start-AotOwnedProcess -Context $context3 -Role Daddy
        } 'ADAPTER_BINDING_MISMATCH' 'In-place adapter method mutation'
        Assert-Equal $adapter3.State.Events.Count $eventsBeforeMutation `
            'Adapter method mutation reached any adapter callback.'
    }

    Invoke-Case 'poisoned TEMP and TMP cannot move the synthetic boundary' {
        $fixture = New-TestFixture
        $adapter = New-TestAdapter
        $oldTemp = $env:TEMP
        $oldTmp = $env:TMP
        try {
            $volumeRoot = [IO.Path]::GetPathRoot($repoRoot)
            $env:TEMP = $volumeRoot
            $env:TMP = $volumeRoot
            $context = New-TestContext -Fixture $fixture -Adapter $adapter
            $trustedPrefix = $script:tempRoot + '\'
            Assert-True (($context.RunDirectory + '\').StartsWith(
                    $trustedPrefix, [StringComparison]::OrdinalIgnoreCase)) `
                'Poisoned TEMP/TMP redirected the synthetic run directory.'
            Assert-Equal $context.TrustMode 'SYNTHETIC_TEST_ONLY' `
                'Synthetic context trust label differs under poisoned TEMP/TMP.'
        } finally {
            $env:TEMP = $oldTemp
            $env:TMP = $oldTmp
        }
    }

    Invoke-Case 'launch ledger, contract, resume, and direct argument ordering' {
        $fixture = New-TestFixture
        $adapter = New-TestAdapter
        $context = New-TestContext -Fixture $fixture -Adapter $adapter
        $entry = Start-AotOwnedProcess -Context $context -Role Daddy
        Assert-Equal $entry.State 'RunningHidden' 'Daddy state after launch differs.'
        Assert-True ([bool]$adapter.State.ResumeSawLedgered.Daddy) `
            'Resume occurred without a committed Ledgered identity.'
        Assert-True ([bool]$adapter.State.CreateSawLaunchIntent.Daddy) `
            'CreateSuspended occurred without a committed LaunchIntent.'
        Assert-Equal $adapter.State.CreatedArguments.Daddy `
            $fixture.DaddyPlan.ArgumentList `
            'CreateSuspended did not receive the reviewed argument tail.'
        $events = @($adapter.State.Events)
        $contractIndex = [Array]::IndexOf($events,
            'SetContract:Daddy:00000003:High')
        $resumeIndex = [Array]::IndexOf($events, 'Resume:Daddy')
        $ledgerIndex = -1
        for ($index = 0; $index -lt $events.Count; $index++) {
            if ($events[$index] -like 'Commit:*' -and
                $index -gt $contractIndex -and $index -lt $resumeIndex) {
                $ledgerIndex = $index
            }
        }
        Assert-True ($contractIndex -ge 0 -and $ledgerIndex -gt $contractIndex `
                -and $resumeIndex -gt $ledgerIndex) `
            'Affinity/ledger/resume order is not fail closed.'
        Assert-Equal $entry.ContractAssertions 1 `
            'Initial contract assertion count differs.'
        $ledger = Get-Content -Raw -LiteralPath $context.LedgerPath |
            ConvertFrom-Json
        Assert-Equal $ledger.Entries[0].RunToken $context.RunToken `
            'Ledger entry lost its run token.'
        Assert-Equal $ledger.Entries[0].CreationFileTime `
            $entry.CreationFileTime 'Ledger lost exact creation FILETIME.'
        Assert-Equal $ledger.Entries[0].ArgumentListSha256 `
            $fixture.DaddyPlan.ArgumentListSha256 `
            'Ledger lost exact argument hash.'
        Assert-Equal $ledger.Entries[0].SpecFingerprintSha256 `
            $entry.SpecFingerprintSha256 `
            'Ledger lost exact normalized-spec fingerprint.'
    }

    Invoke-Case 'freshly rehashed spec mutation is rejected before creation' {
        $fixture = New-TestFixture
        $adapter = New-TestAdapter
        $context = New-TestContext -Fixture $fixture -Adapter $adapter
        $alternate = Join-Path $fixture.DaddyDirectory 'alternate.exe'
        Write-TestBytes -Path $alternate -Text 'freshly-hashed-alternate-image'
        $context.AllowedSpecs.Daddy.FilePath = $alternate
        $context.AllowedSpecs.Daddy.ImageBytes = `
            [int64]([IO.FileInfo]::new($alternate).Length)
        $context.AllowedSpecs.Daddy.ImageSha256 = Get-TestFileHash -Path $alternate
        Assert-Throws {
            Start-AotOwnedProcess -Context $context -Role Daddy
        } 'spec was mutated' 'Freshly rehashed normalized-spec mutation'
        Assert-True (-not (@($adapter.State.Events) -contains
                'CreateSuspended:Daddy')) `
            'Freshly rehashed spec mutation reached process creation.'
    }

    Invoke-Case 'preflight image drift prevents creation' {
        $fixture = New-TestFixture
        $adapter = New-TestAdapter
        $context = New-TestContext -Fixture $fixture -Adapter $adapter
        [IO.File]::AppendAllText($fixture.DaddyExe, 'drift')
        Assert-Throws {
            Start-AotOwnedProcess -Context $context -Role Daddy
        } 'length|SHA-256' 'Drifted executable pin'
        Assert-True (-not (@($adapter.State.Events) -contains
                'CreateSuspended:Daddy')) `
            'Executable drift still reached process creation.'
    }

    Invoke-Case 'created identity mismatch aborts exact suspended handle' {
        $fixture = New-TestFixture
        $adapter = New-TestAdapter
        $adapter.State.IdentityPathMismatchRole = 'Daddy'
        $context = New-TestContext -Fixture $fixture -Adapter $adapter
        Assert-Throws {
            Start-AotOwnedProcess -Context $context -Role Daddy
        } 'identity|canonicalizable' 'Created image identity mismatch'
        Assert-Equal ($adapter.State.TerminatedRoles -join ',') 'Daddy' `
            'Identity mismatch did not terminate only its created handle.'
        Assert-True (-not (@($adapter.State.Events) -contains 'Resume:Daddy')) `
            'Identity mismatch resumed the suspended process.'
    }

    Invoke-Case 'contract failure and pre-resume ledger failure roll back' {
        $fixture = New-TestFixture
        $adapter = New-TestAdapter
        $adapter.State.FailContractRole = 'Daddy'
        $context = New-TestContext -Fixture $fixture -Adapter $adapter
        Assert-Throws {
            Start-AotOwnedProcess -Context $context -Role Daddy
        } 'synthetic contract failure' 'Pre-resume contract failure'
        Assert-Equal ($adapter.State.TerminatedRoles -join ',') 'Daddy' `
            'Contract failure did not roll back its handle.'
        Assert-True (-not (@($adapter.State.Events) -contains 'Resume:Daddy')) `
            'Contract failure resumed the process.'

        $fixture2 = New-TestFixture
        $adapter2 = New-TestAdapter
        $context2 = New-TestContext -Fixture $fixture2 -Adapter $adapter2
        $adapter2.State.FailCommitNumber = [int]($adapter2.State.CommitCount + 2)
        Assert-Throws {
            Start-AotOwnedProcess -Context $context2 -Role Daddy
        } 'synthetic ledger commit failure' 'Pre-resume ledger failure'
        Assert-Equal ($adapter2.State.TerminatedRoles -join ',') 'Daddy' `
            'Ledger failure did not roll back its handle.'
        Assert-True (-not (@($adapter2.State.Events) -contains 'Resume:Daddy')) `
            'Ledger failure resumed the process.'

        $fixture3 = New-TestFixture
        $adapter3 = New-TestAdapter
        $context3 = New-TestContext -Fixture $fixture3 -Adapter $adapter3
        $adapter3.State.FailCommitNumber = [int]($adapter3.State.CommitCount + 1)
        Assert-Throws {
            Start-AotOwnedProcess -Context $context3 -Role Daddy
        } 'synthetic ledger commit failure' 'LaunchIntent ledger failure'
        Assert-True (-not (@($adapter3.State.Events) -contains
                'CreateSuspended:Daddy')) `
            'LaunchIntent ledger failure still created a process.'
    }

    Invoke-Case 'unexpected resume count is treated as launch failure' {
        $fixture = New-TestFixture
        $adapter = New-TestAdapter
        $adapter.State.ResumeResultRole = 'Daddy'
        $adapter.State.ResumeResult = [uint32]2
        $context = New-TestContext -Fixture $fixture -Adapter $adapter
        Assert-Throws {
            Start-AotOwnedProcess -Context $context -Role Daddy
        } 'unexpected suspend count' 'Unexpected ResumeThread count'
        Assert-Equal ($adapter.State.TerminatedRoles -join ',') 'Daddy' `
            'Unexpected resume count did not stop its exact handle.'
    }

    Invoke-Case 'failed resume rollback retains exact handle for cleanup retry' {
        $fixture = New-TestFixture
        $adapter = New-TestAdapter
        $adapter.State.ResumeResultRole = 'Daddy'
        $adapter.State.ResumeResult = [uint32]2
        $adapter.State.TerminateFailuresRemaining.Daddy = 1
        $context = New-TestContext -Fixture $fixture -Adapter $adapter
        Assert-Throws {
            Start-AotOwnedProcess -Context $context -Role Daddy
        } 'unexpected suspend count' 'Resume failure with failed rollback'
        Assert-Equal $context.Entries.Daddy.State 'CleanupIncomplete' `
            'Unconfirmed launch rollback did not remain retryable.'
        Assert-Equal $context.Entries.Daddy.ErrorCode `
            'LAUNCH_ROLLBACK_INCOMPLETE' `
            'Unconfirmed launch rollback error code differs.'
        Assert-True (-not [bool]$context.Entries.Daddy.HandleClosed) `
            'Unconfirmed launch rollback marked the entry handle closed.'
        Assert-True (-not [bool](
                $context.ExpectedRuntimeIdentities.Daddy.HandleClosed)) `
            'Unconfirmed launch rollback marked its runtime handle closed.'
        Assert-Equal $adapter.State.TerminateAttempts.Daddy 1 `
            'Launch rollback did not make exactly one terminate attempt.'
        Assert-Equal $adapter.State.ClosedProcessRoles.Count 0 `
            'Unconfirmed launch rollback released the process handle.'
        Assert-True ($null -ne
                $context.ExpectedRuntimeIdentities.Daddy.Native.ProcessHandle) `
            'Unconfirmed launch rollback cleared the retained process handle.'

        $retry = @(Stop-AotOwnedRun -Context $context `
            -GracefulTimeoutMs 0 -TerminateTimeoutMs 1)
        Assert-Equal $retry[0].Result 'TERMINATED_OWNED_HANDLE' `
            'Cleanup did not retry the failed launch rollback handle.'
        Assert-Equal $adapter.State.TerminateAttempts.Daddy 2 `
            'Cleanup did not make exactly one retained-handle retry.'
        Assert-Equal ($adapter.State.ClosedProcessRoles -join ',') 'Daddy' `
            'Cleanup did not close exactly the retained Daddy handle.'
        Assert-True ([bool]$context.Entries.Daddy.HandleClosed) `
            'Successful rollback retry did not mark the entry handle closed.'
    }

    Invoke-Case 'retained-handle liveness and contract reassertion reject reuse' {
        $fixture = New-TestFixture
        $adapter = New-TestAdapter
        $context = New-TestContext -Fixture $fixture -Adapter $adapter
        [void](Start-AotOwnedProcess -Context $context -Role Daddy)
        $live = Test-AotOwnedProcessLiveness -Context $context -Role Daddy
        Assert-True ($live.Owned -and $live.Alive) `
            'Fresh retained handle is not reported alive.'
        $entry = Set-AotOwnedProcessContract -Context $context -Role Daddy `
            -Initialized
        Assert-Equal $entry.State 'Initialized' `
            'Initialized reassertion state differs.'
        Assert-Equal $entry.ContractAssertions 2 `
            'Contract reassertion count differs.'
        $adapter.State.IdentityMismatchRole = 'Daddy'
        $reused = Test-AotOwnedProcessLiveness -Context $context -Role Daddy
        Assert-True (-not $reused.Owned -and -not $reused.Alive) `
            'Creation-FILETIME mismatch was accepted as owned.'
        Assert-Equal $reused.Code 'IDENTITY_CREATION_TIME_MISMATCH' `
            'PID-reuse refusal code differs.'
        Assert-Throws {
            Set-AotOwnedProcessContract -Context $context -Role Daddy
        } 'identity refusal' 'Contract reassertion after identity drift'
    }

    Invoke-Case 'mutable entry operational fields never become authority' {
        $mutations = @(
            [pscustomobject]@{ Field = 'TrustMode'; Value = 'PRODUCTION_PINNED';
                Code = 'IDENTITY_ENTRY_CONTRACT_MISMATCH' },
            [pscustomobject]@{ Field = 'Role'; Value = 'Cj';
                Code = 'IDENTITY_ENTRY_CONTRACT_MISMATCH' },
            [pscustomobject]@{ Field = 'ProcessClass'; Value = 'Service';
                Code = 'IDENTITY_ENTRY_CONTRACT_MISMATCH' },
            [pscustomobject]@{ Field = 'FilePath'; Value = 'C:\foreign.exe';
                Code = 'IDENTITY_ENTRY_CONTRACT_MISMATCH' },
            [pscustomobject]@{ Field = 'ImageBytes'; Value = [int64]999;
                Code = 'IDENTITY_ENTRY_CONTRACT_MISMATCH' },
            [pscustomobject]@{ Field = 'ImageSha256'; Value = ('D' * 64);
                Code = 'IDENTITY_ENTRY_CONTRACT_MISMATCH' },
            [pscustomobject]@{ Field = 'ArgumentListSha256'; Value = ('E' * 64);
                Code = 'IDENTITY_ENTRY_CONTRACT_MISMATCH' },
            [pscustomobject]@{ Field = 'Affinity'; Value = '00000004';
                Code = 'IDENTITY_ENTRY_CONTRACT_MISMATCH' },
            [pscustomobject]@{ Field = 'Priority'; Value = 'Normal';
                Code = 'IDENTITY_ENTRY_CONTRACT_MISMATCH' },
            [pscustomobject]@{ Field = 'SpecFingerprintSha256'; Value = ('F' * 64);
                Code = 'IDENTITY_ENTRY_CONTRACT_MISMATCH' },
            [pscustomobject]@{ Field = 'Pid'; Value = [uint32]9999;
                Code = 'IDENTITY_ENTRY_RUNTIME_MISMATCH' },
            [pscustomobject]@{ Field = 'Native'; Value = [pscustomobject]@{};
                Code = 'IDENTITY_ENTRY_RUNTIME_MISMATCH' })
        foreach ($mutation in $mutations) {
            $fixture = New-TestFixture
            $adapter = New-TestAdapter
            $context = New-TestContext -Fixture $fixture -Adapter $adapter
            [void](Start-AotOwnedProcess -Context $context -Role Daddy)
            $context.Entries.Daddy.($mutation.Field) = $mutation.Value
            $live = Test-AotOwnedProcessLiveness -Context $context -Role Daddy
            Assert-True (-not $live.Owned -and -not $live.Alive) `
                "Entry mutation $($mutation.Field) became authority."
            Assert-Equal $live.Code $mutation.Code `
                "Entry mutation $($mutation.Field) refusal code differs."
            $contractEventsBefore = @($adapter.State.Events | Where-Object {
                    $_ -like 'SetContract:Daddy:*'
                }).Count
            Assert-Throws {
                Set-AotOwnedProcessContract -Context $context -Role Daddy
            } 'identity refusal' `
                "Entry mutation $($mutation.Field) contract reassertion"
            $contractEventsAfter = @($adapter.State.Events | Where-Object {
                    $_ -like 'SetContract:Daddy:*'
                }).Count
            Assert-Equal $contractEventsAfter $contractEventsBefore `
                "Entry mutation $($mutation.Field) reached SetContract."
        }

        $fixture = New-TestFixture
        $adapter = New-TestAdapter
        $context = New-TestContext -Fixture $fixture -Adapter $adapter
        [void](Start-AotOwnedProcess -Context $context -Role Daddy)
        $context.AllowedSpecs.Daddy.Affinity = '00000004'
        $context.Entries.Daddy.Affinity = '00000004'
        $live = Test-AotOwnedProcessLiveness -Context $context -Role Daddy
        Assert-Equal $live.Code 'IDENTITY_CONTEXT_SPEC_FINGERPRINT_MISMATCH' `
            'Mutated context spec bypassed its expected fingerprint.'
    }

    Invoke-Case 'Xenia spawn and resume preserve the foreground' {
        $fixture = New-TestFixture
        $adapter = New-TestAdapter
        $adapter.State.ForegroundChangeOnRead = 2
        $context = New-TestContext -Fixture $fixture -Adapter $adapter
        Assert-Throws {
            Start-AotOwnedProcess -Context $context -Role Daddy
        } 'spawn changed the foreground' 'Xenia spawn foreground drift'
        Assert-Equal ($adapter.State.TerminatedRoles -join ',') 'Daddy' `
            'Spawn foreground drift did not roll back exact handle.'

        $fixture2 = New-TestFixture
        $adapter2 = New-TestAdapter
        $adapter2.State.ForegroundChangeOnRead = 4
        $context2 = New-TestContext -Fixture $fixture2 -Adapter $adapter2
        Assert-Throws {
            Start-AotOwnedProcess -Context $context2 -Role Daddy
        } 'resume changed the foreground' 'Xenia resume foreground drift'
        Assert-Equal ($adapter2.State.TerminatedRoles -join ',') 'Daddy' `
            'Resume foreground drift did not roll back exact handle.'
    }

    Invoke-Case 'window reveal uses stable owned HWND and preserves foreground' {
        $fixture = New-TestFixture
        $adapter = New-TestAdapter
        $context = New-TestContext -Fixture $fixture -Adapter $adapter
        [void](Start-AotOwnedProcess -Context $context -Role Daddy)
        $rectangle = [pscustomobject][ordered]@{
            X = [int]0; Y = [int]0; Width = [int]1280; Height = [int]720
        }
        $window = Show-AotOwnedWindowNoActivate -Context $context `
            -Role Daddy -Rectangle $rectangle
        Assert-Equal $window $adapter.State.WindowByRole.Daddy `
            'No-activate reveal returned wrong HWND.'
        Assert-Equal $context.Entries.Daddy.State 'VisibleNoActivate' `
            'No-activate lifecycle state differs.'
        $events = @($adapter.State.Events)
        $hidden = [Array]::IndexOf($events, "PlaceHidden:$window")
        $reveal = [Array]::IndexOf($events, "RevealNoActivate:$window")
        $visible = [Array]::IndexOf($events,
            "PlaceVisibleNoActivate:$window")
        Assert-True ($hidden -ge 0 -and $reveal -gt $hidden -and
                $visible -gt $reveal) `
            'No-activate reveal ordering differs.'
        $successfulWindowPidChecks = @($adapter.State.Events |
            Where-Object { $_ -like 'WindowPid:Daddy:*' }).Count
        Assert-Equal $successfulWindowPidChecks 6 `
            'Successful reveal lacked pre/post HWND ownership checks.'

        $fixture2 = New-TestFixture
        $adapter2 = New-TestAdapter
        $context2 = New-TestContext -Fixture $fixture2 -Adapter $adapter2
        [void](Start-AotOwnedProcess -Context $context2 -Role Daddy)
        $adapter2.State.ForegroundReads = 0
        $adapter2.State.ForegroundChangeOnRead = 2
        Assert-Throws {
            Show-AotOwnedWindowNoActivate -Context $context2 `
                -Role Daddy -Rectangle $rectangle
        } 'changed the foreground' 'Foreground invariance violation'
        Assert-Equal $context2.Entries.Daddy.State 'FocusInvariantFailed' `
            'Foreground failure state differs.'
        $windowPidChecks = @($adapter2.State.Events | Where-Object {
                $_ -like 'WindowPid:Daddy:*'
            }).Count
        Assert-Equal $windowPidChecks 2 `
            'Failed window call lacked its own pre/post HWND ownership checks.'
    }

    Invoke-Case 'window operations stop on exit or HWND ownership drift' {
        $rectangle = [pscustomobject][ordered]@{
            X = [int]0; Y = [int]0; Width = [int]1280; Height = [int]720
        }

        $fixture = New-TestFixture
        $adapter = New-TestAdapter
        $context = New-TestContext -Fixture $fixture -Adapter $adapter
        [void](Start-AotOwnedProcess -Context $context -Role Daddy)
        $adapter.State.ExitOnIsAliveCall.Daddy = 3
        Assert-Throws {
            Show-AotOwnedWindowNoActivate -Context $context -Role Daddy `
                -Rectangle $rectangle
        } 'exited before PlaceHidden' 'Exit between discovery and first step'
        Assert-Equal @($adapter.State.Events | Where-Object {
                $_ -like 'PlaceHidden:*'
            }).Count 0 `
            'Exited process still received PlaceHidden.'
        Assert-Equal @($adapter.State.Events | Where-Object {
                $_ -like 'RevealNoActivate:*'
            }).Count 0 `
            'Exited process still received reveal.'

        $fixture2 = New-TestFixture
        $adapter2 = New-TestAdapter
        $context2 = New-TestContext -Fixture $fixture2 -Adapter $adapter2
        [void](Start-AotOwnedProcess -Context $context2 -Role Daddy)
        $adapter2.State.ExitAfterWindowOperation.Daddy = 'PlaceHidden'
        Assert-Throws {
            Show-AotOwnedWindowNoActivate -Context $context2 -Role Daddy `
                -Rectangle $rectangle
        } 'exited after PlaceHidden' 'Exit during PlaceHidden'
        Assert-Equal @($adapter2.State.Events | Where-Object {
                $_ -like 'PlaceHidden:*'
            }).Count 1 `
            'PlaceHidden exit fixture did not execute its first step.'
        Assert-Equal @($adapter2.State.Events | Where-Object {
                $_ -like 'RevealNoActivate:*'
            }).Count 0 `
            'Window reveal continued after process exit.'
        Assert-Equal @($adapter2.State.Events | Where-Object {
                $_ -like 'PlaceVisibleNoActivate:*'
            }).Count 0 `
            'Visible placement continued after process exit.'

        $fixture3 = New-TestFixture
        $adapter3 = New-TestAdapter
        $context3 = New-TestContext -Fixture $fixture3 -Adapter $adapter3
        [void](Start-AotOwnedProcess -Context $context3 -Role Daddy)
        $adapter3.State.WindowPidMismatchOnCall.Daddy = 1
        Assert-Throws {
            Show-AotOwnedWindowNoActivate -Context $context3 -Role Daddy `
                -Rectangle $rectangle
        } 'window PID changed before PlaceHidden' `
            'HWND PID reuse before PlaceHidden'
        Assert-Equal @($adapter3.State.Events | Where-Object {
                $_ -like 'PlaceHidden:*'
            }).Count 0 `
            'PID-reused HWND received PlaceHidden.'

        $fixture4 = New-TestFixture
        $adapter4 = New-TestAdapter
        $context4 = New-TestContext -Fixture $fixture4 -Adapter $adapter4
        [void](Start-AotOwnedProcess -Context $context4 -Role Daddy)
        $adapter4.State.WindowPidMismatchOnCall.Daddy = 2
        Assert-Throws {
            Show-AotOwnedWindowNoActivate -Context $context4 -Role Daddy `
                -Rectangle $rectangle
        } 'window PID changed after PlaceHidden' `
            'HWND PID reuse after PlaceHidden'
        Assert-Equal @($adapter4.State.Events | Where-Object {
                $_ -like 'PlaceHidden:*'
            }).Count 1 `
            'Post-step PID drift fixture skipped PlaceHidden.'
        Assert-Equal @($adapter4.State.Events | Where-Object {
                $_ -like 'RevealNoActivate:*'
            }).Count 0 `
            'Window reveal continued after post-step PID drift.'
    }

    Invoke-Case 'cleanup is reverse-role, exact-handle, and identity refusing' {
        $fixture = New-TestFixture
        $adapter = New-TestAdapter
        $context = New-TestContext -Fixture $fixture -Adapter $adapter
        foreach ($role in 'XWS', 'FESL', 'Daddy', 'Cj') {
            [void](Start-AotOwnedProcess -Context $context -Role $role)
        }
        $adapter.State.IdentityMismatchRole = 'Daddy'
        $result = @(Stop-AotOwnedRun -Context $context `
            -GracefulTimeoutMs 1 -TerminateTimeoutMs 1)
        Assert-Equal ($result.Role -join ',') 'Cj,Daddy,FESL,XWS' `
            'Cleanup role order is not exact reverse order.'
        Assert-Equal $result[1].Result 'REFUSED_IDENTITY_MISMATCH' `
            'Cleanup did not refuse mutated Daddy identity.'
        Assert-Equal ($adapter.State.TerminatedRoles -join ',') `
            'Cj,FESL,XWS' `
            'Cleanup terminated a foreign or wrong-order handle.'
        Assert-True (-not ($adapter.State.TerminatedRoles -contains 'Daddy')) `
            'Cleanup terminated the identity-mismatched role.'
        Assert-Equal $context.Status 'StoppedWithRefusals' `
            'Cleanup refusal status differs.'
        Assert-True (-not ($context.Entries.ContainsKey('MongoDB'))) `
            'Cleanup acquired MongoDB ownership.'
        Assert-Equal ($adapter.State.ClosedProcessRoles -join ',') `
            'Cj,FESL,XWS' `
            'Identity-refused handle was incorrectly released.'
        $adapter.State.IdentityMismatchRole = $null
        $second = @(Stop-AotOwnedRun -Context $context `
            -GracefulTimeoutMs 1 -TerminateTimeoutMs 1)
        Assert-Equal ($second.Result -join ',') `
            ('ALREADY_CLEANED,TERMINATED_OWNED_HANDLE,' +
                'ALREADY_CLEANED,ALREADY_CLEANED') `
            'Second cleanup did not retry only the retained refused handle.'
        Assert-Equal ($adapter.State.TerminatedRoles -join ',') `
            'Cj,FESL,XWS,Daddy' `
            'Second cleanup repeated or skipped the wrong termination.'
    }

    Invoke-Case 'run-token mutation refuses stop and retains its handle' {
        $fixture = New-TestFixture
        $adapter = New-TestAdapter
        $context = New-TestContext -Fixture $fixture -Adapter $adapter
        [void](Start-AotOwnedProcess -Context $context -Role Daddy)
        $context.Entries.Daddy.RunToken = '0' * 32
        $result = @(Stop-AotOwnedRun -Context $context `
            -GracefulTimeoutMs 1 -TerminateTimeoutMs 1)
        Assert-Equal $result[0].Result 'REFUSED_IDENTITY_MISMATCH' `
            'Run-token mutation did not refuse cleanup.'
        Assert-Equal $result[0].Code 'IDENTITY_RUN_TOKEN_MISMATCH' `
            'Run-token refusal code differs.'
        Assert-Equal $adapter.State.TerminatedRoles.Count 0 `
            'Run-token mutation terminated a process.'
        Assert-Equal $adapter.State.ClosedProcessRoles.Count 0 `
            'Run-token refusal released the retained process handle.'
        Assert-True (-not [bool]$context.Entries.Daddy.HandleClosed) `
            'Run-token refusal marked the retained handle closed.'
    }

    Invoke-Case 'incomplete termination retains and retries the exact handle' {
        $fixture = New-TestFixture
        $adapter = New-TestAdapter
        $context = New-TestContext -Fixture $fixture -Adapter $adapter
        [void](Start-AotOwnedProcess -Context $context -Role XWS)
        $adapter.State.TerminateFailuresRemaining.XWS = 1
        $first = @(Stop-AotOwnedRun -Context $context `
            -GracefulTimeoutMs 0 -TerminateTimeoutMs 1)
        Assert-Equal $first[0].Result 'FAILED' `
            'First synthetic terminate failure result differs.'
        Assert-Equal $context.Entries.XWS.State 'CleanupIncomplete' `
            'Failed cleanup did not retain CleanupIncomplete state.'
        Assert-True (-not [bool]$context.Entries.XWS.HandleClosed) `
            'Failed cleanup marked the retained handle closed.'
        Assert-True (-not [bool]$context.ExpectedRuntimeIdentities.XWS.HandleClosed) `
            'Failed cleanup marked the runtime anchor handle closed.'
        Assert-Equal $adapter.State.ClosedProcessRoles.Count 0 `
            'Failed cleanup released the retained handle.'
        Assert-Equal $adapter.State.TerminateAttempts.XWS 1 `
            'First cleanup did not make exactly one terminate attempt.'

        $second = @(Stop-AotOwnedRun -Context $context `
            -GracefulTimeoutMs 0 -TerminateTimeoutMs 1)
        Assert-Equal $second[0].Result 'TERMINATED_OWNED_HANDLE' `
            'Second cleanup did not retry the retained handle.'
        Assert-Equal $adapter.State.TerminateAttempts.XWS 2 `
            'Second cleanup did not make exactly one retry.'
        Assert-True ([bool]$context.Entries.XWS.HandleClosed) `
            'Successful retry did not mark the ledger handle closed.'
        Assert-True ([bool]$context.ExpectedRuntimeIdentities.XWS.HandleClosed) `
            'Successful retry did not mark the runtime handle closed.'
        Assert-Equal ($adapter.State.ClosedProcessRoles -join ',') 'XWS' `
            'Successful retry did not close exactly the XWS handle.'

        $third = @(Stop-AotOwnedRun -Context $context `
            -GracefulTimeoutMs 0 -TerminateTimeoutMs 1)
        Assert-Equal $third[0].Result 'ALREADY_CLEANED' `
            'Third cleanup was not idempotent.'
        Assert-Equal $adapter.State.TerminateAttempts.XWS 2 `
            'Idempotent cleanup repeated termination.'
    }

    Invoke-Case 'graceful close revalidates exit and PID reuse interleavings' {
        $fixture = New-TestFixture
        $adapter = New-TestAdapter
        $context = New-TestContext -Fixture $fixture -Adapter $adapter
        [void](Start-AotOwnedProcess -Context $context -Role Cj)
        $adapter.State.ExitDuringFindWindows.Cj = $true
        $exitResult = @(Stop-AotOwnedRun -Context $context `
            -GracefulTimeoutMs 1 -TerminateTimeoutMs 1)
        Assert-Equal $exitResult[0].Result 'ALREADY_EXITED' `
            'Exit during FindWindows was attributed to graceful close.'
        Assert-True (-not (@($adapter.State.Events) -contains
                'RequestClose:Cj')) `
            'Exit during FindWindows still received RequestClose.'
        Assert-Equal $adapter.State.TerminatedRoles.Count 0 `
            'Already-exited process was force terminated.'

        $fixture2 = New-TestFixture
        $adapter2 = New-TestAdapter
        $context2 = New-TestContext -Fixture $fixture2 -Adapter $adapter2
        [void](Start-AotOwnedProcess -Context $context2 -Role Cj)
        $adapter2.State.IdentityMismatchOnCall.Cj = 3
        $reuseResult = @(Stop-AotOwnedRun -Context $context2 `
            -GracefulTimeoutMs 1 -TerminateTimeoutMs 1)
        Assert-Equal $reuseResult[0].Result `
            'REFUSED_IDENTITY_MISMATCH' `
            'PID reuse during FindWindows was not refused.'
        Assert-Equal $reuseResult[0].Code `
            'IDENTITY_CREATION_TIME_MISMATCH' `
            'PID-reuse interleaving refusal code differs.'
        Assert-True (-not (@($adapter2.State.Events) -contains
                'RequestClose:Cj')) `
            'PID-reused process received RequestClose.'
        Assert-Equal $adapter2.State.TerminatedRoles.Count 0 `
            'PID-reuse refusal terminated a process.'
        Assert-Equal $adapter2.State.ClosedProcessRoles.Count 0 `
            'PID-reuse refusal released the retained handle.'

        $fixture3 = New-TestFixture
        $adapter3 = New-TestAdapter
        $context3 = New-TestContext -Fixture $fixture3 -Adapter $adapter3
        [void](Start-AotOwnedProcess -Context $context3 -Role Cj)
        $adapter3.State.WindowPidMismatchOnCall.Cj = 2
        $postReuseResult = @(Stop-AotOwnedRun -Context $context3 `
            -GracefulTimeoutMs 1 -TerminateTimeoutMs 1)
        Assert-True (@($adapter3.State.Events) -contains 'RequestClose:Cj') `
            'Post-request PID-reuse fixture never issued the owned close.'
        Assert-Equal $postReuseResult[0].Result `
            'TERMINATED_OWNED_HANDLE' `
            'Post-request HWND PID drift was reported as graceful close.'
        Assert-Equal ($adapter3.State.TerminatedRoles -join ',') 'Cj' `
            'Post-request HWND drift did not use exact-handle termination.'
    }

    Invoke-Case 'graceful exact-window close avoids forced termination' {
        $fixture = New-TestFixture
        $adapter = New-TestAdapter
        $context = New-TestContext -Fixture $fixture -Adapter $adapter
        [void](Start-AotOwnedProcess -Context $context -Role Cj)
        $adapter.State.CloseExitsRole.Cj = $true
        $result = @(Stop-AotOwnedRun -Context $context `
            -GracefulTimeoutMs 1 -TerminateTimeoutMs 1)
        Assert-Equal $result[0].Result 'CLOSED_OWNED_WINDOW' `
            'Graceful owned-window close result differs.'
        Assert-Equal $adapter.State.TerminatedRoles.Count 0 `
            'Graceful exit was unnecessarily terminated.'
        Assert-Equal $context.Status 'Stopped' 'Clean stop status differs.'
    }

    Write-Output ("PASS: AOT_OWNED_PROCESS assertions={0} cases={1}" -f
        $script:assertions, $script:cases)
} finally {
    foreach ($root in $script:fixtureRoots) {
        $resolved = [IO.Path]::GetFullPath($root)
        if (($resolved + '\').StartsWith($script:tempRoot + '\',
                [StringComparison]::OrdinalIgnoreCase) -and
            [IO.Directory]::Exists($resolved)) {
            [IO.Directory]::Delete($resolved, $true)
        }
    }
}
