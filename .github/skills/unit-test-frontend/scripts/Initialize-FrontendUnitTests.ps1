#!/usr/bin/env pwsh
#Requires -Version 7.4

<#
.SYNOPSIS
    Sets up local Vitest and React Testing Library using approved UI sources.
.DESCRIPTION
    Preserves declared versions and existing test configuration. Checks effective
    registries and resolved lockfile URLs before installing. Never changes sources,
    installs Node/npm, runs package lifecycle scripts, or executes tests.
.PARAMETER RepoRoot
    Repository checkout; defaults to this script's repository.
.OUTPUTS
    Ready, Configured, Preview with planned commands, or Blocked with a reason.
    Configured is setup evidence, not a passing test result.
.EXAMPLE
    ./Initialize-FrontendUnitTests.ps1 -WhatIf
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../../..')).Path
)

$ErrorActionPreference = 'Stop'

function Invoke-SetupNpm {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string[]]$Arguments)

    $Output = @(& npm @Arguments 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw 'npm setup operation failed. Check the local npm log; no alternate source was attempted.'
    }
    return ($Output -join "`n")
}

function Assert-SetupRegistry {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Value)

    $RegistryUri = $null
    if (-not [uri]::TryCreate($Value, [UriKind]::Absolute, [ref]$RegistryUri) -or
        $RegistryUri.Scheme -ne 'https' -or $RegistryUri.UserInfo -or
        $RegistryUri.Query -or $RegistryUri.Fragment -or $Value.Contains('${')) {
        throw 'Registry configuration must use a literal HTTPS URL without credentials, query, or fragment.'
    }
    return $RegistryUri.AbsoluteUri.TrimEnd('/') + '/'
}

function Assert-SetupLock {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$Registries,
        [switch]$AllowRegistryOmission
    )

    $Lock = Get-Content -LiteralPath 'package-lock.json' -Raw | ConvertFrom-Json -AsHashtable
    if ($Lock.lockfileVersion -lt 2 -or -not $Lock.packages) { throw 'A supported npm lockfile is required for source verification.' }
    foreach ($Entry in $Lock.packages.GetEnumerator()) {
        if (-not $Entry.Key) { continue }
        if ($Entry.Value.link -or -not $Entry.Value.integrity) {
            throw 'Lockfile dependency lacks a verifiable registry download and integrity hash.'
        }
        if (-not $Entry.Value.resolved -and $AllowRegistryOmission -and
            $Entry.Value.version -match '^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?$') {
            continue
        }
        $DownloadUri = $null
        if (-not [uri]::TryCreate([string]$Entry.Value.resolved, [UriKind]::Absolute, [ref]$DownloadUri) -or
            $DownloadUri.Scheme -ne 'https' -or $DownloadUri.UserInfo -or
            -not @($Registries.Values | Where-Object {
                $DownloadUri.AbsoluteUri.StartsWith($_, [StringComparison]::Ordinal)
            }).Count) {
            throw 'Lockfile contains downloads outside the approved UI registries.'
        }
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    $UiRoot = Join-Path $RepoRoot 'Eklee.KeyVault.UI'
    if (-not (Test-Path -LiteralPath (Join-Path $UiRoot 'package.json'))) {
        return [pscustomobject]@{ Status = 'Blocked'; Reason = 'UI package.json is missing.' }
    }
    foreach ($Tool in @('node', 'npm')) {
        if (-not (Get-Command $Tool -ErrorAction SilentlyContinue)) {
            return [pscustomobject]@{ Status = 'Blocked'; Reason = "$Tool is missing; install the approved runtime separately." }
        }
    }
    Push-Location $UiRoot
    $ManifestBefore = Get-Content -LiteralPath 'package.json' -Raw
    $LockBefore = if (Test-Path -LiteralPath 'package-lock.json') { Get-Content -LiteralPath 'package-lock.json' -Raw } else { $null }
    $RestoreManifests = $false
    try {
        $Package = $ManifestBefore | ConvertFrom-Json -AsHashtable
        if (Test-Path -LiteralPath 'npm-shrinkwrap.json') { throw 'npm-shrinkwrap.json requires manual setup.' }
        if (-not $Package.scripts) { $Package.scripts = @{} }
        $TestScript = @('test:unit', 'test') | Where-Object {
            $Package.scripts[$_] -match '^vitest(?:\s+run)?\s*$'
        } | Select-Object -First 1
        if (-not $TestScript -and $Package.scripts['test:unit']) {
            throw 'Existing test:unit command is unsupported; preserve it and configure manually.'
        }
        $Configs = @(Get-ChildItem -File -Path 'vitest.config.*' -ErrorAction SilentlyContinue)
        $CreateConfig = $Configs.Count -eq 0
        if ($CreateConfig -and @(Get-ChildItem -File -Path 'vitest.workspace.*' -ErrorAction SilentlyContinue).Count) {
            throw 'Existing Vitest workspace requires manual configuration.'
        }
        if ($CreateConfig -and -not (Test-Path -LiteralPath 'vite.config.ts')) {
            throw 'Automatic configuration requires the existing vite.config.ts.'
        }
        if ($CreateConfig -and (Test-Path -LiteralPath '.frontend-test-setup.mjs')) {
            throw 'Existing .frontend-test-setup.mjs must be preserved; configure manually.'
        }
        $Required = @('vitest', 'jsdom', '@testing-library/react', '@testing-library/dom', '@testing-library/jest-dom', '@testing-library/user-event')
        $Missing = @($Required | Where-Object {
            -not ($Package.dependencies -and $Package.dependencies[$_]) -and
            -not ($Package.devDependencies -and $Package.devDependencies[$_])
        })
        $Install = $Missing.Count -gt 0 -or @($Required | Where-Object {
            -not (Test-Path -LiteralPath "node_modules/$_/package.json")
        }).Count -gt 0
        $Commands = @()
        $Registries = @{}
        if ($Install) {
            if (-not (Test-Path -LiteralPath '.npmrc')) { throw 'UI .npmrc must explicitly configure the approved registry.' }
            foreach ($Line in Get-Content -LiteralPath '.npmrc') {
                if ($Line -match '^\s*(?<Key>(?:@[A-Za-z0-9._-]+:)?registry)\s*=\s*(?<Value>.*?)\s*$') {
                    $Registries[$Matches.Key] = Assert-SetupRegistry $Matches.Value
                }
            }
            if (-not $Registries.registry) { throw 'UI .npmrc must explicitly configure the approved registry.' }
            $Effective = Invoke-SetupNpm @('config', 'list', '--json') | ConvertFrom-Json -AsHashtable
            $Keys = @(@('registry') + @($Registries.Keys) + @($Effective.Keys | Where-Object { $_ -match '^@[^:]+:registry$' }) | Sort-Object -Unique)
            foreach ($Key in $Keys) {
                $Expected = if ($Registries[$Key]) { $Registries[$Key] } else { $Registries.registry }
                $Actual = if ($Effective[$Key]) { Assert-SetupRegistry $Effective[$Key] } else { Assert-SetupRegistry $Effective.registry }
                if ($Expected -cne $Actual) { throw 'Effective npm registries differ from the UI approved source configuration.' }
            }
            foreach ($Kind in @('dependencies', 'devDependencies', 'optionalDependencies')) {
                foreach ($Spec in @($Package[$Kind].Values)) {
                    if ($Spec -match '[:/\\]') { throw 'Non-registry dependency specs require manual source verification.' }
                }
            }
            if ($null -ne $LockBefore) {
                Assert-SetupLock $Registries -AllowRegistryOmission:($Effective['omit-lockfile-registry-resolved'] -eq $true)
            }
            $Commands += [pscustomobject]@{ Command = 'npm'; Arguments = @('install', '--package-lock-only', '--omit-lockfile-registry-resolved=false', '--include=dev', '--ignore-scripts', '--engine-strict', '--no-audit', '--no-fund', '--save-dev', '--save-exact') + @($Missing | ForEach-Object { "$_@latest" }) }
            $Commands += [pscustomobject]@{ Command = 'npm'; Arguments = @('ci', '--include=dev', '--ignore-scripts', '--engine-strict', '--no-audit', '--no-fund') }
        }
        if (-not $Install -and -not $CreateConfig -and $TestScript) {
            return [pscustomobject]@{ Status = 'Ready'; Commands = @(); ChangedFiles = @() }
        }
        if (-not $PSCmdlet.ShouldProcess($UiRoot, 'Set up frontend unit-test dependencies and missing configuration')) {
            return [pscustomobject]@{ Status = 'Preview'; Commands = $Commands; CreateConfig = $CreateConfig; AddTestScript = -not $TestScript }
        }
        $ChangedFiles = @()
        if ($Install) {
            $RestoreManifests = $true
            $null = Invoke-SetupNpm $Commands[0].Arguments
            Assert-SetupLock $Registries
            $null = Invoke-SetupNpm $Commands[1].Arguments
            $Package = Get-Content -LiteralPath 'package.json' -Raw | ConvertFrom-Json -AsHashtable
            foreach ($Name in $Required) {
                if (-not (Test-Path -LiteralPath "node_modules/$Name/package.json")) {
                    throw 'npm completed without installing all required test packages.'
                }
            }
            $ChangedFiles += @('package.json', 'package-lock.json')
        }
        if (-not $TestScript) {
            if (-not $Package.scripts) { $Package.scripts = @{} }
            $Package.scripts['test:unit'] = 'vitest run'
            $Package | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath 'package.json' -Encoding utf8
            $ChangedFiles += 'package.json'
        }
        if ($CreateConfig) {
            @'
import { defineConfig, mergeConfig } from 'vitest/config';
import viteConfig from './vite.config.ts';

export default defineConfig(async (environment) => mergeConfig(
  typeof viteConfig === 'function' ? await viteConfig(environment) : await viteConfig,
  defineConfig({
    test: {
      environment: 'jsdom',
      include: ['src/**/*.test.{ts,tsx}', 'src/**/*.spec.{ts,tsx}'],
      setupFiles: ['./.frontend-test-setup.mjs'],
      clearMocks: true,
      restoreMocks: true,
    },
  }),
));
'@ | Set-Content -LiteralPath 'vitest.config.mjs' -Encoding utf8
            @'
import '@testing-library/jest-dom/vitest';
import { cleanup } from '@testing-library/react';
import { afterEach } from 'vitest';

afterEach(() => cleanup());
'@ | Set-Content -LiteralPath '.frontend-test-setup.mjs' -Encoding utf8
            $ChangedFiles += @('vitest.config.mjs', '.frontend-test-setup.mjs')
        }
        $RestoreManifests = $false
        return [pscustomobject]@{ Status = 'Configured'; Commands = $Commands; ChangedFiles = @($ChangedFiles | Sort-Object -Unique) }
    }
    catch {
        return [pscustomobject]@{ Status = 'Blocked'; Reason = $_.Exception.Message }
    }
    finally {
        if ($RestoreManifests) {
            [IO.File]::WriteAllText((Join-Path $UiRoot 'package.json'), $ManifestBefore)
            if ($null -ne $LockBefore) { [IO.File]::WriteAllText((Join-Path $UiRoot 'package-lock.json'), $LockBefore) }
            else { Remove-Item -LiteralPath 'package-lock.json' -Force -ErrorAction SilentlyContinue }
        }
        Pop-Location
    }
}