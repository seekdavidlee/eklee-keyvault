#!/usr/bin/env pwsh
#Requires -Version 7.4

<#
.SYNOPSIS
    Runs an explicit unit-test filter using the repository's xUnit/VSTest setup.
.PARAMETER Filter
    Required VSTest expression selecting isolated tests, not hosted tests.
.PARAMETER RepoRoot
    Repository checkout; defaults to this script's repository.
.OUTPUTS
    Passed with command and test counts. Throws on unsupported configuration,
    failed execution, missing report, zero executed tests, or skipped tests.
.EXAMPLE
    ./Invoke-BackendUnitTests.ps1 -Filter 'FullyQualifiedName~SecretGenerationServiceTests'
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Filter,
    [string]$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../../..')).Path
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '../../_shared/RepositoryTools.ps1')

if ($MyInvocation.InvocationName -ne '.') {
    Push-Location $RepoRoot
    $ResultsDirectory = Join-Path ([IO.Path]::GetTempPath()) "backend-tests-$([guid]::NewGuid().ToString('N'))"
    try {
        $Project = Join-Path $RepoRoot 'Eklee.KeyVault.Api.Tests/Eklee.KeyVault.Api.Tests.csproj'
        [xml]$Configuration = Get-Content -LiteralPath $Project -Raw
        $Packages = @($Configuration.SelectNodes('//PackageReference') | ForEach-Object { $_.Include })
        if ('xunit' -notin $Packages -or 'Microsoft.NET.Test.Sdk' -notin $Packages) {
            throw 'Unsupported test platform. Update the runner using the run-tests skill before execution.'
        }
        foreach ($Directory in @($RepoRoot, (Split-Path $Project))) {
            $GlobalFile = Join-Path $Directory 'global.json'
            if (Test-Path -LiteralPath $GlobalFile) {
                $GlobalConfig = Get-Content -LiteralPath $GlobalFile -Raw | ConvertFrom-Json -AsHashtable
                if ($GlobalConfig.test.runner -eq 'Microsoft.Testing.Platform') {
                    throw 'MTP configuration requires updating this VSTest runner before execution.'
                }
            }
            foreach ($Name in @('Directory.Build.props', 'Directory.Packages.props')) {
                $Props = Join-Path $Directory $Name
                if ((Test-Path -LiteralPath $Props) -and
                    (Get-Content -LiteralPath $Props -Raw) -match '<TestingPlatformDotnetTestSupport>\s*true\s*</') {
                    throw 'MTP configuration requires updating this VSTest runner before execution.'
                }
            }
        }
        if ($Configuration.SelectSingleNode('//TestingPlatformDotnetTestSupport[text()="true"]')) {
            throw 'MTP configuration requires updating this VSTest runner before execution.'
        }
        $Arguments = @(
            'test', $Project, '--filter', $Filter, '--logger', 'trx;LogFileName=unit-tests.trx',
            '--results-directory', $ResultsDirectory
        )
        if (-not $PSCmdlet.ShouldProcess($Project, "Run unit tests matching $Filter")) {
            return [pscustomobject]@{ Status = 'Preview'; Command = 'dotnet'; Arguments = $Arguments }
        }
        $Output = Invoke-SkillCommand dotnet $Arguments
        Write-Host $Output
        [xml]$Report = Get-Content -LiteralPath (Join-Path $ResultsDirectory 'unit-tests.trx') -Raw
        $Counters = $Report.SelectSingleNode('//*[local-name()="Counters"]')
        if (-not $Counters -or [int]$Counters.passed -le 0 -or
            [int]$Counters.failed -gt 0 -or [int]$Counters.notExecuted -gt 0) {
            throw 'Unit-test report is missing successful execution or contains failed/skipped tests.'
        }
        return [pscustomobject]@{
            Status = 'Passed'; Command = 'dotnet'; Arguments = $Arguments
            Total = [int]$Counters.total; Passed = [int]$Counters.passed
            Failed = [int]$Counters.failed; Skipped = [int]$Counters.notExecuted
        }
    }
    finally {
        Remove-Item -LiteralPath $ResultsDirectory -Recurse -Force -ErrorAction SilentlyContinue
        Pop-Location
    }
}