[CmdletBinding()]
param(
    [string]$RepoRoot = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
    $RepoRoot = Split-Path -Parent $PSScriptRoot
}
$resolvedRootText = @(& git -C $RepoRoot rev-parse --show-toplevel 2>&1 |
    ForEach-Object { "$_" }) -join "`n"
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($resolvedRootText)) {
    throw "cannot resolve Git repository root: $resolvedRootText"
}
$RepoRoot = [IO.Path]::GetFullPath($resolvedRootText.Trim())
$repoPrefix = $RepoRoot.TrimEnd('\') + '\'
$gitCommand = Get-Command git.exe -ErrorAction Stop | Select-Object -First 1
$gitExe = $gitCommand.Source

$allowlistRelative = 'release/portable-runtime-source.allowlist.psd1'
$selfRelative = 'tests/test_portable_runtime_source_allowlist.ps1'

function Get-IndexEntry {
    param([Parameter(Mandatory = $true)][string]$RelativePath)

    $lines = @(& git -C $RepoRoot ls-files --stage -- $RelativePath 2>&1 |
        ForEach-Object { "$_" })
    if ($LASTEXITCODE -ne 0) {
        throw "git index query failed for $RelativePath`: $($lines -join ' ')"
    }
    if ($lines.Count -ne 1 -or $lines[0] -notmatch
        '^(?<mode>[0-7]{6}) (?<blob>[0-9a-f]{40,64}) (?<stage>[0-3])\t(?<path>.+)$') {
        throw "source candidate path is absent or conflicted in the Git index: $RelativePath"
    }
    if ([int]$Matches.stage -ne 0 -or
        $Matches.path.Replace('\', '/') -cne $RelativePath) {
        throw "source candidate path lacks one exact stage-0 index entry: $RelativePath"
    }
    if ($Matches.mode -notin '100644', '100755') {
        throw "source candidate path is not a regular indexed file: $RelativePath"
    }
    return [pscustomobject]@{
        Mode = $Matches.mode
        Blob = $Matches.blob
        Path = $Matches.path.Replace('\', '/')
    }
}

function Export-IndexFile {
    param(
        [Parameter(Mandatory = $true)][string]$RelativePath,
        [Parameter(Mandatory = $true)][string]$DestinationRoot)

    $entry = Get-IndexEntry -RelativePath $RelativePath
    $destinationPath = [IO.Path]::GetFullPath(
        (Join-Path $DestinationRoot $RelativePath))
    $destinationPrefix = [IO.Path]::GetFullPath($DestinationRoot).TrimEnd('\') + '\'
    if (-not ($destinationPath + '\').StartsWith(
            $destinationPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "indexed blob destination escaped its extraction root: $RelativePath"
    }
    [void][IO.Directory]::CreateDirectory(
        [IO.Path]::GetDirectoryName($destinationPath))

    # Read the indexed blob directly. checkout-index applies worktree EOL
    # conversion, which would change the pinned patch/template byte hashes.
    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $gitExe
    $startInfo.WorkingDirectory = $RepoRoot
    $startInfo.Arguments = "cat-file blob $($entry.Blob)"
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    $stream = $null
    try {
        if (-not $process.Start()) {
            throw "could not start git cat-file for $RelativePath"
        }
        $errorTask = $process.StandardError.ReadToEndAsync()
        $stream = [IO.File]::Create($destinationPath)
        $process.StandardOutput.BaseStream.CopyTo($stream)
        $stream.Flush()
        $stream.Dispose()
        $stream = $null
        $process.WaitForExit()
        $errorText = $errorTask.GetAwaiter().GetResult()
        if ($process.ExitCode -ne 0) {
            throw "could not extract indexed blob for $RelativePath`: $errorText"
        }
    } finally {
        if ($null -ne $stream) { $stream.Dispose() }
        $process.Dispose()
    }
}

function Get-MapValue {
    param([object]$Map, [string]$Key)
    if ($Map -is [Collections.IDictionary] -and $Map.Contains($Key)) {
        return $Map[$Key]
    }
    return $null
}

function Assert-PowerShellParses {
    param([Parameter(Mandatory = $true)][string]$Path)
    $tokens = $null
    $errors = $null
    [void][Management.Automation.Language.Parser]::ParseFile(
        $Path, [ref]$tokens, [ref]$errors)
    if (@($errors).Count -ne 0) {
        $rendered = @($errors | ForEach-Object {
            "line=$($_.Extent.StartLineNumber) $($_.Message)"
        }) -join '; '
        throw "PowerShell parse failed for $Path`: $rendered"
    }
}

# Bootstrap the manifest from the index too. Importing the working-tree copy
# here would let an unstaged allowlist silently control a supposedly clean
# source snapshot.
[void](Get-IndexEntry -RelativePath $allowlistRelative)
[void](Get-IndexEntry -RelativePath $selfRelative)

$tempBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
$bootstrapRoot = Join-Path $tempBase ('AoT runtime manifest {0}' -f
    [Guid]::NewGuid().ToString('N'))
$cleanRoot = Join-Path $tempBase ('AoT runtime source {0}' -f
    [Guid]::NewGuid().ToString('N'))
foreach ($candidateRoot in $bootstrapRoot, $cleanRoot) {
    $resolvedCandidate = [IO.Path]::GetFullPath($candidateRoot)
    if (-not ($resolvedCandidate + '\').StartsWith(
            $tempBase, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'source-candidate test directory escaped the system temp directory'
    }
}

try {
    [void][IO.Directory]::CreateDirectory($bootstrapRoot)
    Export-IndexFile -RelativePath $allowlistRelative `
        -DestinationRoot $bootstrapRoot
    $indexedAllowlistPath = Join-Path $bootstrapRoot $allowlistRelative
    $allowlist = Import-PowerShellDataFile -LiteralPath $indexedAllowlistPath

    if ([int]$allowlist.SchemaVersion -ne 1 -or
        [string]$allowlist.ArtifactClass -cne
            'SOURCE_RUNTIME_CANDIDATE_NOT_PLAYER_KIT' -or
        [bool]$allowlist.PlayerKitReady -or
        [bool]$allowlist.RuntimeTested -or
        [string]$allowlist.SnapshotSource -cne 'GIT_INDEX_STAGE_0') {
        throw 'portable runtime source allowlist overstates readiness or loses its index boundary'
    }

    $files = @($allowlist.Files | ForEach-Object {
        ([string]$_).Replace('\', '/')
    })
    if ($files.Count -eq 0) {
        throw 'portable runtime source allowlist is empty'
    }
    $uniqueFiles = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::OrdinalIgnoreCase)
    foreach ($relativePath in $files) {
        if (-not $uniqueFiles.Add($relativePath)) {
            throw "portable runtime source allowlist contains a duplicate: $relativePath"
        }
    }

    $requiredClosure = @(
        'README.md'
        'LICENSE'
        'PACKAGING.md'
        'PUBLIC_ALPHA.md'
        'PROFILE_BOOTSTRAP.md'
        'ALPHA_MANIFEST.md'
        'THIRD_PARTY_NOTICES.md'
        '.gitattributes'
        '.github/workflows/validate-source-alpha.yml'
        'docs/b19_same_pc_physical_acceptance_20260826.md'
        'PLAY-AOT-COOP.cmd'
        'Start-AOT-Coop.ps1'
        'Setup-AOT-Coop.ps1'
        'aot-coop.portable.example.psd1'
        'profiles/b19/profile.psd1'
        'profiles/b19/daddy.launch.template.txt'
        'profiles/b19/cj.launch.template.txt'
        'profiles/b19/patches/454108D8 - coop-bind-6000.patch.toml'
        'profiles/b19/patches/454108D8 - coop-cod-unaddressed.patch.toml'
        'profiles/b19/patches/454108D8 - coop-hold-connecting-v2.patch.toml'
        'tools/runtime/AotPortableHardware.psm1'
        'tools/runtime/New-AotPortableLaunchPlan.ps1'
        'tools/runtime/backup_retail_acceptance_saves.ps1'
        'tools/runtime/confirm_daddy_continue.ps1'
        'tools/runtime/confirm_cj_empty_slot.ps1'
        'tools/runtime/fesl_server.py'
        'tools/runtime/test_service_contract.ps1'
        'tools/runtime/test_xws_session_gate.ps1'
        'tools/release/New-AotPublicSourceSnapshot.ps1'
        'classify_screen.ps1'
        'dump_aot_ui.ps1'
        'tools/runtime/aot_top_level_window.ps1'
        'tests/test_portable_launch_plan.ps1'
        'tests/test_portable_hardware.ps1'
        'tests/test_portable_save_backup.ps1'
        'tests/test_public_source_snapshot.ps1'
        'tests/test_setup_aot_coop.ps1'
        'tests/test_start_aot_coop.ps1'
        'tests/test_confirm_daddy_continue.ps1'
        'tests/test_confirm_cj_empty_slot.ps1'
        'tests/test_cj_armed_join_monitor.ps1'
        'tests/test_xws_session_gate.ps1'
        'tests/test_hidden_window_discovery.ps1'
        'tests/test_fesl_ecnl_transaction.py'
        'tests/test_fesl_game_lifecycle.py'
        'tests/test_host_self_egrq_transaction.py'
        $selfRelative
        $allowlistRelative
        'release/public-source.gitignore'
    )
    foreach ($requiredPath in $requiredClosure) {
        if (-not $uniqueFiles.Contains($requiredPath)) {
            throw "portable runtime source closure is missing: $requiredPath"
        }
    }

    $forbiddenExtensions = @(
        '.exe', '.dll', '.pdb', '.xex', '.iso', '.bin', '.upk', '.gpd',
        '.sav', '.header', '.xtr', '.zip', '.7z', '.dmp', '.png', '.jpg',
        '.jpeg', '.bmp', '.log', '.out', '.err', '.tmp', '.flag', '.jsonl',
        '.js', '.node'
    )
    $forbiddenFragments = @(
        'my_xbox/', 'cjs_xbox/', 'rigs/', '_runs/', '_backups/',
        '_driver_shots/', '_mongo/', 'gproj/', 'node_modules/', 'dist/',
        'xenia_canary_netplay.exe', 'xconfig.settings',
        'aot-coop.local.psd1', 'aot-coop.portable.psd1',
        'Army of Two The 40th Day.patch.toml', 'src/xenia/'
    )

    $indexEntries = @{}
    foreach ($relativePath in $files) {
        if ([string]::IsNullOrWhiteSpace($relativePath) -or
            [IO.Path]::IsPathRooted($relativePath) -or
            $relativePath.StartsWith('/') -or
            $relativePath -match '(^|/)\.\.(?:/|$)') {
            throw "unsafe portable runtime source path: $relativePath"
        }
        $extension = [IO.Path]::GetExtension($relativePath).ToLowerInvariant()
        if ($forbiddenExtensions -contains $extension) {
            throw "proprietary/generated extension is allowlisted: $relativePath"
        }
        foreach ($fragment in $forbiddenFragments) {
            if ($relativePath.IndexOf($fragment,
                    [StringComparison]::OrdinalIgnoreCase) -ge 0) {
                throw "forbidden runtime/source artifact is allowlisted: $relativePath"
            }
        }
        $resolvedPath = [IO.Path]::GetFullPath((Join-Path $RepoRoot $relativePath))
        if (-not ($resolvedPath + '\').StartsWith(
                $repoPrefix, [StringComparison]::OrdinalIgnoreCase)) {
            throw "portable runtime source path escaped the repository: $relativePath"
        }

        $entry = Get-IndexEntry -RelativePath $relativePath
        $indexEntries[$relativePath] = $entry
        $blobType = @(& git -C $RepoRoot cat-file -t $entry.Blob 2>&1 |
            ForEach-Object { "$_" }) -join ''
        if ($LASTEXITCODE -ne 0 -or $blobType -cne 'blob') {
            throw "indexed source candidate object is not a blob: $relativePath"
        }
        $blobSizeText = @(& git -C $RepoRoot cat-file -s $entry.Blob 2>&1 |
            ForEach-Object { "$_" }) -join ''
        [int64]$blobSize = 0
        if ($LASTEXITCODE -ne 0 -or
            -not [int64]::TryParse($blobSizeText, [ref]$blobSize) -or
            $blobSize -ge 5MB) {
            throw "indexed source candidate blob is invalid or 5 MiB and larger: $relativePath"
        }
    }

    [void][IO.Directory]::CreateDirectory($cleanRoot)
    foreach ($relativePath in $files) {
        Export-IndexFile -RelativePath $relativePath `
            -DestinationRoot $cleanRoot
    }

    $extracted = @(Get-ChildItem -LiteralPath $cleanRoot -Recurse -File |
        ForEach-Object {
            $_.FullName.Substring($cleanRoot.Length).TrimStart('\').Replace('\', '/')
        })
    if ($extracted.Count -ne $files.Count -or
        @($extracted | Where-Object { -not $uniqueFiles.Contains($_) }).Count -ne 0) {
        throw 'clean source extraction differs from the indexed allowlist'
    }

    $scanText = @($files | ForEach-Object {
        Get-Content -Raw -LiteralPath (Join-Path $cleanRoot $_)
    }) -join "`n"

    # Compare both ignored config schemas, when present, without copying either
    # file into the candidate. Scan every rooted machine path plus both sides'
    # persisted identities and routes. Normalize slash direction and compare
    # case-insensitively so spelling variants cannot bypass the boundary.
    $normalizedScanText = $scanText.Replace('\', '/')
    foreach ($privateConfigName in 'aot-coop.local.psd1',
                                    'aot-coop.portable.psd1') {
        $privateConfigPath = Join-Path $RepoRoot $privateConfigName
        if (-not (Test-Path -LiteralPath $privateConfigPath -PathType Leaf)) {
            continue
        }
        $privateConfig = Import-PowerShellDataFile -LiteralPath $privateConfigPath
        $privateValues = [Collections.Generic.List[string]]::new()
        foreach ($topKey in 'WorkspaceRoot', 'InstallRoot', 'XwsRoot',
                            'NodeExe', 'PythonExe', 'GamePath') {
            $value = [string](Get-MapValue -Map $privateConfig -Key $topKey)
            if (-not [string]::IsNullOrWhiteSpace($value) -and
                [IO.Path]::IsPathRooted($value)) {
                $privateValues.Add($value)
            }
        }
        foreach ($sideName in 'Daddy', 'Cj') {
            $side = Get-MapValue -Map $privateConfig -Key $sideName
            foreach ($sideKey in 'RigDir', 'ProfileXuid', 'OnlineXuid',
                                  'MacAddress', 'HostAddress') {
                $value = [string](Get-MapValue -Map $side -Key $sideKey)
                if (-not [string]::IsNullOrWhiteSpace($value)) {
                    $privateValues.Add($value)
                }
            }
        }
        foreach ($privateValue in @($privateValues | Sort-Object -Unique)) {
            $normalizedPrivateValue = $privateValue.Replace('\', '/')
            if ($normalizedScanText.IndexOf($normalizedPrivateValue,
                    [StringComparison]::OrdinalIgnoreCase) -ge 0) {
                throw "indexed source candidate retained a value from $privateConfigName"
            }
        }
    }

    $privateUserRoot = [Environment]::GetFolderPath('UserProfile')
    $opaqueWorkflowPrefix = 'w' + 'f_'
    $oldAiAuthor = 'author = "' + 'claude' + '"'
    foreach ($forbiddenContent in $privateUserRoot, ('C:' + '\Users\'),
                                $opaqueWorkflowPrefix, $oldAiAuthor) {
        $normalizedForbiddenContent = $forbiddenContent.Replace('\', '/')
        if (-not [string]::IsNullOrWhiteSpace($normalizedForbiddenContent) -and
            $normalizedScanText.IndexOf($normalizedForbiddenContent,
                [StringComparison]::OrdinalIgnoreCase) -ge 0) {
            throw 'indexed source candidate retained private/internal provenance text'
        }
    }

    $powerShellFiles = @($files | Where-Object {
        [IO.Path]::GetExtension($_).ToLowerInvariant() -in
            '.ps1', '.psm1', '.psd1'
    })
    foreach ($relativePath in $powerShellFiles) {
        Assert-PowerShellParses -Path (Join-Path $cleanRoot $relativePath)
    }

    $pythonCommand = Get-Command python.exe -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($null -eq $pythonCommand) {
        throw 'python.exe is required to parse the portable FESL source'
    }
    $pythonFiles = @($files | Where-Object {
        [IO.Path]::GetExtension($_).ToLowerInvariant() -eq '.py'
    })
    foreach ($relativePath in $pythonFiles) {
        $pythonParseArguments = @(
            '-c'
            "import ast,pathlib,sys; ast.parse(pathlib.Path(sys.argv[1]).read_text(encoding='utf-8'), filename=sys.argv[1])"
            (Join-Path $cleanRoot $relativePath)
        )
        $savedErrorPreference = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            $pythonParse = @(& $pythonCommand.Source @pythonParseArguments 2>&1 |
                ForEach-Object { "$_" }) -join "`n"
            $pythonParseExit = $LASTEXITCODE
        } finally {
            $ErrorActionPreference = $savedErrorPreference
        }
        if ($pythonParseExit -ne 0) {
            throw "portable Python parse failed ($relativePath): $pythonParse"
        }
    }

    $doubleClickPath = Join-Path $cleanRoot 'PLAY-AOT-COOP.cmd'
    $doubleClickSource = Get-Content -Raw -LiteralPath $doubleClickPath
    if ($doubleClickSource -notmatch '(?i)portable-check' -or
        $doubleClickSource -notmatch '(?i)Start-AOT-Coop\.ps1') {
        throw 'indexed double-click launcher lacks the portable source entry points'
    }

    $licenseText = Get-Content -Raw -LiteralPath (Join-Path $cleanRoot 'LICENSE')
    if ($licenseText -notmatch '(?m)^MIT License$' -or
        $licenseText -notmatch '(?m)^Copyright \(c\) 2026 eternalgr3y$' -or
        $licenseText -notmatch 'Permission is hereby granted, free of charge') {
        throw 'indexed source candidate lacks the approved MIT license grant'
    }

    $windowsPowerShell = Join-Path $env:SystemRoot `
        'System32\WindowsPowerShell\v1.0\powershell.exe'
    $safeTests = @(
        'tests/test_portable_launch_plan.ps1'
        'tests/test_portable_hardware.ps1'
        'tests/test_portable_save_backup.ps1'
        'tests/test_public_source_snapshot.ps1'
        'tests/test_setup_aot_coop.ps1'
        'tests/test_start_aot_coop.ps1'
        'tests/test_confirm_daddy_continue.ps1'
        'tests/test_confirm_cj_empty_slot.ps1'
        'tests/test_cj_armed_join_monitor.ps1'
        'tests/test_xws_session_gate.ps1'
        'tests/test_hidden_window_discovery.ps1'
    )
    foreach ($relativeTest in $safeTests) {
        $testArguments = @(
            '-NoProfile'
            '-NonInteractive'
            '-ExecutionPolicy'
            'Bypass'
            '-File'
            (Join-Path $cleanRoot $relativeTest)
        )
        if ($relativeTest -ceq 'tests/test_start_aot_coop.ps1') {
            $testArguments += '-SourceOnly'
        }
        $testOutput = @(& $windowsPowerShell @testArguments 2>&1 |
            ForEach-Object { "$_" }) -join "`n"
        if ($LASTEXITCODE -ne 0 -or $testOutput -notmatch '(?m)^PASS:') {
            throw "indexed clean-source test failed ($relativeTest): $testOutput"
        }
        if ($relativeTest -ceq 'tests/test_portable_launch_plan.ps1' -and
            $testOutput -notmatch 'local_golden=skipped_no_private_config') {
            throw "clean launch-plan test consumed private state: $testOutput"
        }
    }

    $safePythonTests = @(
        'tests/test_fesl_ecnl_transaction.py'
        'tests/test_fesl_game_lifecycle.py'
        'tests/test_host_self_egrq_transaction.py'
    )
    foreach ($relativeTest in $safePythonTests) {
        $savedErrorPreference = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            $testOutput = @(& $pythonCommand.Source `
                (Join-Path $cleanRoot $relativeTest) 2>&1 |
                ForEach-Object { "$_" }) -join "`n"
            $testExit = $LASTEXITCODE
        } finally {
            $ErrorActionPreference = $savedErrorPreference
        }
        if ($testExit -ne 0 -or
            $testOutput -notmatch '(?m)^Ran [1-9][0-9]* tests? in ' -or
            $testOutput -notmatch '(?m)^OK\s*$') {
            throw "indexed clean-source Python test failed ($relativeTest): $testOutput"
        }
    }

    # Exercise the service gate only through a synthetic fixture. This proves
    # process/listener checks without starting or querying any backend.
    $serviceScript = Join-Path $cleanRoot 'tools/runtime/test_service_contract.ps1'
    $feslScript = Join-Path $cleanRoot 'tools/runtime/fesl_server.py'
    $fixtureLog = Join-Path $cleanRoot '_fixture/fesl.txt'
    $fixturePath = Join-Path $cleanRoot '_fixture/service.json'
    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($fixturePath))
    $fixture = [ordered]@{
        Listeners = @(
            @{ LocalAddress = '127.0.0.1'; LocalPort = 36000; OwningProcess = 51001 }
            @{ LocalAddress = '127.0.0.1'; LocalPort = 18131; OwningProcess = 52001 }
            @{ LocalAddress = '127.0.0.1'; LocalPort = 18275; OwningProcess = 52001 }
            @{ LocalAddress = '127.0.0.1'; LocalPort = 13505; OwningProcess = 52001 }
        )
        Processes = @(
            @{ Id = 51001; Name = 'node'; Path = 'C:\AotFixture\Node\node.exe'
                CommandLine = '"C:\AotFixture\Node\node.exe" dist/main'
                PriorityClass = 'Normal'; Affinity = '0xC000000000000000' }
            @{ Id = 52001; Name = 'python'; Path = 'C:\AotFixture\Python\python.exe'
                CommandLine = (('"C:\AotFixture\Python\python.exe" "{0}" --memcheck c0 ' +
                    '--seconds 7200 --log "{1}"') -f $feslScript, $fixtureLog)
                PriorityClass = 'High'; Affinity = '0x4000000000000000' }
        )
        HealthSamples = @(
            @{ StatusCode = 200; LatencyMs = 10; Body = '[]' }
            @{ StatusCode = 200; LatencyMs = 12; Body = '[]' }
            @{ StatusCode = 200; LatencyMs = 11; Body = '[]' }
        )
    }
    [IO.File]::WriteAllText($fixturePath,
        ($fixture | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
    $serviceArguments = @(
        '-NoProfile'
        '-NonInteractive'
        '-ExecutionPolicy'
        'Bypass'
        '-File'
        $serviceScript
        '-Stage'
        'PreReset'
        '-ExpectedFeslLogPath'
        $fixtureLog
        '-FixturePath'
        $fixturePath
        '-ExpectedNodePath'
        'C:\AotFixture\Node\node.exe'
        '-ExpectedFeslScriptPath'
        $feslScript
        '-ExpectedXwsAffinity'
        'C000000000000000'
        '-ExpectedFeslAffinity'
        '4000000000000000'
    )
    $serviceOutput = @(& $windowsPowerShell @serviceArguments 2>&1 |
        ForEach-Object { "$_" }) -join "`n"
    if ($LASTEXITCODE -ne 0 -or
        $serviceOutput -notmatch '(?m)^ALLOW aot_services ') {
        throw "indexed clean-source service fixture failed: $serviceOutput"
    }

    Write-Host (("PASS: portable runtime source candidate files={0} " +
        "powershell_parsed={1} python_parsed={2} safe_tests={3} " +
        "service_fixtures=1 snapshot=index player_kit_ready=false " +
        "runtime_tested=false") -f $files.Count, $powerShellFiles.Count,
        $pythonFiles.Count, ($safeTests.Count + $safePythonTests.Count))
} finally {
    foreach ($candidateRoot in $bootstrapRoot, $cleanRoot) {
        $resolvedCandidate = [IO.Path]::GetFullPath($candidateRoot)
        if (($resolvedCandidate + '\').StartsWith(
                $tempBase, [StringComparison]::OrdinalIgnoreCase) -and
            (Test-Path -LiteralPath $resolvedCandidate)) {
            Remove-Item -LiteralPath $resolvedCandidate -Recurse -Force
        }
    }
}
