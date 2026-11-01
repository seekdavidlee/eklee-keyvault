#!/usr/bin/env pwsh
#Requires -Version 7.4

<#
.SYNOPSIS
    Runs focused frontend unit tests once, using configured local Vitest tooling.
.PARAMETER TestFiles
    Required existing test paths relative to the UI directory; e2e paths are rejected.
.PARAMETER Build
    Also runs the configured build, including type checking.
.PARAMETER Lint
    Also runs the configured lint command.
.PARAMETER RepoRoot
    Repository checkout; defaults to this script's repository.
.OUTPUTS
    Blocked for missing or unsupported tooling, Preview for WhatIf, or Passed
    with commands and test counts. Never installs packages or runs Playwright.
.EXAMPLE
    ./Invoke-FrontendUnitTests.ps1 -TestFiles src/example.test.tsx -Build -Lint
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string[]]$TestFiles,
    [switch]$Build,
    [switch]$Lint,
    [string]$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../../..')).Path
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '../../_shared/RepositoryTools.ps1')

if ($MyInvocation.InvocationName -ne '.') {
    $UiRoot = Join-Path $RepoRoot 'Eklee.KeyVault.UI'
    Push-Location $UiRoot
    $ReportFile = Join-Path ([IO.Path]::GetTempPath()) "frontend-tests-$([guid]::NewGuid().ToString('N')).json"
    try {
        $Package = Get-Content -LiteralPath 'package.json' -Raw | ConvertFrom-Json -AsHashtable
        $TestScript = @('test:unit', 'test') | Where-Object {
            $Package.scripts[$_] -match '^vitest(?:\s+run)?\s*$'
        } | Select-Object -First 1
        if (-not $TestScript -or
            (-not $Package.devDependencies.vitest -and -not $Package.dependencies.vitest)) {
            return [pscustomobject]@{
                Status = 'Blocked'; Reason = 'No supported unit-test script and Vitest dependency configured. Obtain tooling approval.'
            }
        }
        if (-not (Test-Path -LiteralPath 'node_modules/vitest/package.json')) {
            return [pscustomobject]@{ Status = 'Blocked'; Reason = 'Configured Vitest is not installed. Use approved package sources only.' }
        }
        foreach ($File in $TestFiles) {
            $FullPath = [IO.Path]::GetFullPath((Join-Path $UiRoot $File))
            if (-not $FullPath.StartsWith($UiRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase) -or
                $File.Replace('\', '/') -match '(^|/)e2e(/|$)' -or
                -not (Test-Path -LiteralPath $FullPath -PathType Leaf)) {
                throw "Expected an existing in-project unit-test file: $File"
            }
        }
        $Commands = @([pscustomobject]@{
            Command = 'npm'; Arguments = @('run', $TestScript, '--', '--run', '--reporter=json', "--outputFile=$ReportFile") + $TestFiles
        })
        foreach ($Check in @(@{ Enabled = $Build; Name = 'build' }, @{ Enabled = $Lint; Name = 'lint' })) {
            if ($Check.Enabled) {
                if (-not $Package.scripts[$Check.Name]) { throw "Missing npm script: $($Check.Name)" }
                $Commands += [pscustomobject]@{ Command = 'npm'; Arguments = @('run', $Check.Name) }
            }
        }
        if (-not $PSCmdlet.ShouldProcess($UiRoot, 'Run frontend unit tests and selected checks')) {
            return [pscustomobject]@{ Status = 'Preview'; Commands = $Commands }
        }
        foreach ($Command in $Commands) {
            $Output = Invoke-SkillCommand $Command.Command $Command.Arguments
            Write-Host $Output
        }
        $Report = Get-Content -LiteralPath $ReportFile -Raw | ConvertFrom-Json -AsHashtable
        if (-not $Report.success -or $Report.numPassedTests -le 0 -or
            $Report.numFailedTests -gt 0 -or $Report.numPendingTests -gt 0 -or $Report.numTodoTests -gt 0) {
            throw 'Unit-test report is missing successful execution or contains failed/skipped tests.'
        }
        return [pscustomobject]@{
            Status = 'Passed'; Commands = $Commands; Total = $Report.numTotalTests
            Passed = $Report.numPassedTests; Failed = $Report.numFailedTests
        }
    }
    finally {
        Remove-Item -LiteralPath $ReportFile -Force -ErrorAction SilentlyContinue
        Pop-Location
    }
}