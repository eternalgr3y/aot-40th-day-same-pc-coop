$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$builder = Join-Path $root `
    'tools\release\New-AotPublicSourceSnapshot.ps1'
. $builder -Version 'v0.0.0-test' -SourceOnly

$tempBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
$tempRoot = Join-Path $tempBase `
    ('AoT public source snapshot ' + [Guid]::NewGuid().ToString('N'))
$resolvedTemp = [IO.Path]::GetFullPath($tempRoot)
if (-not ($resolvedTemp + '\').StartsWith(
        $tempBase, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'snapshot fixture escaped the system temp directory'
}

try {
    [void][IO.Directory]::CreateDirectory((Join-Path $resolvedTemp 'sub'))
    [IO.File]::WriteAllText((Join-Path $resolvedTemp 'alpha.txt'), 'alpha',
        [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $resolvedTemp 'sub\beta.ps1'),
        "Write-Output 'beta'`n", [Text.UTF8Encoding]::new($false))

    $records = @(Get-SourceFileRecords -Root $resolvedTemp `
        -RelativePaths @('sub/beta.ps1', 'alpha.txt'))
    if ($records.Count -ne 2 -or $records[0].Path -cne 'alpha.txt' -or
        $records[1].Path -cne 'sub/beta.ps1' -or
        @($records | Where-Object { $_.SHA256 -notmatch '^[A-F0-9]{64}$' }).Count) {
        throw 'deterministic source record generation failed'
    }
    Assert-SourceFileRecords -Root $resolvedTemp -Records $records

    [IO.File]::AppendAllText((Join-Path $resolvedTemp 'alpha.txt'), 'changed')
    $changedMessage = ''
    try {
        Assert-SourceFileRecords -Root $resolvedTemp -Records $records
    } catch {
        $changedMessage = $_.Exception.Message
    }
    if ($changedMessage -notmatch 'verified snapshot file changed') {
        throw 'hash verification accepted a changed source file'
    }

    $escapeMessage = ''
    try {
        [void](Resolve-ContainedPath -Root $resolvedTemp `
            -RelativePath '..\outside.txt')
    } catch {
        $escapeMessage = $_.Exception.Message
    }
    if ($escapeMessage -notmatch 'unsafe relative path') {
        throw 'contained-path helper accepted parent traversal'
    }
} finally {
    if (($resolvedTemp + '\').StartsWith(
            $tempBase, [StringComparison]::OrdinalIgnoreCase) -and
        (Test-Path -LiteralPath $resolvedTemp)) {
        Remove-Item -LiteralPath $resolvedTemp -Recurse -Force
    }
}

Write-Host 'PASS: public source snapshot records are deterministic, traversal-safe, and tamper-detecting'
