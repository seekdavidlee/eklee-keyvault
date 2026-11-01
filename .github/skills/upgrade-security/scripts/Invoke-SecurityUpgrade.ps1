#!/usr/bin/env pwsh
#Requires -Version 7.4

<#
.SYNOPSIS
    Retrieves alerts and executes explicit, approved security-upgrade operations.
.PARAMETER Action
    Discover (default), PrepareBranch, Update, or Verify. Discover is read-only.
    PrepareBranch and Update support WhatIf; no operation commits or pushes.
.PARAMETER Severity
    Alert severities; defaults to critical and high.
.PARAMETER Branch
    Approved security/* branch name for PrepareBranch.
.PARAMETER Manifest
    Repository-relative affected csproj or package.json for Update. Optional
    additional csproj for Verify, which always builds the API and frontend.
.PARAMETER Package
    Existing direct dependency to update. Transitive/override changes require
    an approved owning dependency or a separate code/configuration edit.
.PARAMETER Version
    Explicit approved patched version. Package sources come from existing configuration.
.PARAMETER RepoRoot
    Repository checkout; defaults to this script's repository.
.OUTPUTS
    Alerts with normalized advisory metadata; BranchPrepared, Updated, Verified,
    or Preview. Verified includes builds and current remote alert state, not a
    claim that local fixes have closed remote alerts.
.EXAMPLE
    ./Invoke-SecurityUpgrade.ps1 -Action Discover
.EXAMPLE
    ./Invoke-SecurityUpgrade.ps1 -Action Update -Manifest Eklee.KeyVault.UI/package.json `
        -Package axios -Version 1.20.0 -WhatIf
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [ValidateSet('Discover', 'PrepareBranch', 'Update', 'Verify')][string]$Action = 'Discover',
    [ValidateSet('critical', 'high', 'medium', 'low')][string[]]$Severity = @('critical', 'high'),
    [string]$Branch,
    [string]$Manifest,
    [string]$Package,
    [string]$Version,
    [string]$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../../..')).Path
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '../../_shared/RepositoryTools.ps1')

function Get-SecurityAlerts {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Repository)

    $Severities = $Severity -join ','
    $Pages = Invoke-SkillJson @(
        'api', '--method', 'GET', '--paginate', '--slurp',
        "repos/$Repository/dependabot/alerts?state=open&severity=$Severities&per_page=100"
    )
    return @($Pages | ForEach-Object { $_ | ForEach-Object { $_ } } | ForEach-Object {
        [pscustomobject]@{
            Number = $_.number; Url = $_.html_url; Severity = $_.security_advisory.severity
            Cve = $_.security_advisory.cve_id; Ghsa = $_.security_advisory.ghsa_id
            Package = $_.dependency.package.name; Ecosystem = $_.dependency.package.ecosystem
            Manifest = $_.dependency.manifest_path
            VulnerableRange = $_.security_vulnerability.vulnerable_version_range
            PatchedVersion = $_.security_vulnerability.first_patched_version.identifier
        }
    })
}

if ($MyInvocation.InvocationName -ne '.') {
    Push-Location $RepoRoot
    try {
        $Context = Get-SkillContext
        if ($Action -eq 'Discover') {
            return [pscustomobject]@{ Status = 'Discovered'; Context = $Context; Alerts = @(Get-SecurityAlerts $Context.Repository) }
        }
        if ($Action -eq 'PrepareBranch') {
            if ($Branch -cnotmatch '^security/.+' -or $Context.Worktree) {
                throw 'An approved security/* name and a clean worktree are required; preserve existing changes.'
            }
            $null = Invoke-SkillCommand git @('check-ref-format', '--branch', $Branch)
            $null = Invoke-SkillCommand git @('fetch', 'origin', 'main')
            if (-not $PSCmdlet.ShouldProcess($Branch, 'Create security branch from origin/main')) {
                return [pscustomobject]@{ Status = 'Preview'; Branch = $Branch }
            }
            $null = Invoke-SkillCommand git @('switch', '--create', $Branch, '--no-track', 'origin/main')
            $ActualBranch = (Invoke-SkillCommand git @('branch', '--show-current')).Trim()
            $Upstream = (Invoke-SkillCommand git @('for-each-ref', '--format=%(upstream)', "refs/heads/$Branch")).Trim()
            if ($ActualBranch -cne $Branch -or $Upstream) { throw 'Security branch or upstream verification failed.' }
            return [pscustomobject]@{ Status = 'BranchPrepared'; Branch = $Branch }
        }
        $FullManifest = $null
        if ($Manifest) {
            $FullManifest = [IO.Path]::GetFullPath((Join-Path $RepoRoot $Manifest))
            if (-not $FullManifest.StartsWith($RepoRoot.TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase) -or
                -not (Test-Path -LiteralPath $FullManifest -PathType Leaf)) {
                throw 'Manifest must be an existing file inside the repository.'
            }
        }
        if ($Action -eq 'Update') {
            if (-not $FullManifest -or $Package -notmatch '^(?!-)[@A-Za-z0-9][A-Za-z0-9._/@-]*$' -or
                $Version -notmatch '^[0-9][A-Za-z0-9.+-]*$') {
                throw 'Update requires an affected manifest, package, and explicit patched version.'
            }
            $Command = 'dotnet'
            if ($FullManifest.EndsWith('.csproj', [StringComparison]::OrdinalIgnoreCase)) {
                [xml]$Project = Get-Content -LiteralPath $FullManifest -Raw
                $Declared = @($Project.SelectNodes('//PackageReference') | Where-Object { $_.Include -ieq $Package })
                if ($Declared.Count -ne 1) { throw 'Choose an existing direct dependency; do not promote a transitive package.' }
                $Arguments = @('add', $FullManifest, 'package', $Package, '--version', $Version)
            }
            elseif ([IO.Path]::GetFileName($FullManifest) -ceq 'package.json') {
                $Config = Get-Content -LiteralPath $FullManifest -Raw | ConvertFrom-Json -AsHashtable
                $Kinds = @('dependencies', 'devDependencies', 'optionalDependencies' | Where-Object { $Config[$_] -and $Config[$_].ContainsKey($Package) })
                if ($Kinds.Count -ne 1) { throw 'Choose a package declared in exactly one supported dependency section.' }
                $Save = @{ dependencies = '--save-prod'; devDependencies = '--save-dev'; optionalDependencies = '--save-optional' }[$Kinds[0]]
                $Command = 'npm'
                $Arguments = @('install', "$Package@$Version", $Save)
            }
            else { throw 'Only csproj and package.json manifests are supported.' }
            if (-not $PSCmdlet.ShouldProcess($Manifest, "Update $Package to $Version using configured package sources")) {
                return [pscustomobject]@{ Status = 'Preview'; Command = $Command; Arguments = $Arguments }
            }
            Push-Location (Split-Path $FullManifest)
            try { Write-Host (Invoke-SkillCommand $Command $Arguments) }
            finally { Pop-Location }
            return [pscustomobject]@{ Status = 'Updated'; Manifest = $Manifest; Package = $Package; Version = $Version }
        }
        $Projects = @('Eklee.KeyVault.Api/Eklee.KeyVault.Api.csproj')
        if ($FullManifest -and $FullManifest.EndsWith('.csproj', [StringComparison]::OrdinalIgnoreCase)) {
            $Projects += $FullManifest
        }
        if (-not $PSCmdlet.ShouldProcess($Context.Repository, 'Build affected backend projects and frontend; read resolved dependencies and remote alerts')) {
            return [pscustomobject]@{ Status = 'Preview'; Projects = $Projects }
        }
        $Dependencies = @()
        foreach ($Project in @($Projects | Sort-Object -Unique)) {
            Write-Host (Invoke-SkillCommand dotnet @('build', $Project))
            $Resolved = Invoke-SkillCommand dotnet @('list', $Project, 'package', '--include-transitive', '--format', 'json')
            $Dependencies += [pscustomobject]@{ Manifest = $Project; Resolved = ($Resolved | ConvertFrom-Json -AsHashtable) }
        }
        Push-Location (Join-Path $RepoRoot 'Eklee.KeyVault.UI')
        try {
            Write-Host (Invoke-SkillCommand npm @('run', 'build'))
            $Resolved = Invoke-SkillCommand npm @('ls', '--all', '--json')
            $Dependencies += [pscustomobject]@{ Manifest = 'Eklee.KeyVault.UI/package.json'; Resolved = ($Resolved | ConvertFrom-Json -AsHashtable) }
        }
        finally { Pop-Location }
        return [pscustomobject]@{
            Status = 'Verified'; Context = $Context; Dependencies = $Dependencies
            Alerts = @(Get-SecurityAlerts $Context.Repository)
        }
    }
    finally {
        Pop-Location
    }
}