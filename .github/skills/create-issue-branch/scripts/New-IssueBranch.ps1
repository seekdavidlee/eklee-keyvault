#!/usr/bin/env pwsh
#Requires -Version 7.4

<#
.SYNOPSIS
    Resolves or creates a typed issue branch from a remote release tip.
.DESCRIPTION
    Fetches origin and reuses release routing without falling back to main.
    Creation requires a clean checkout and supports WhatIf and Confirm.
.PARAMETER Issue
    Issue number or URL in the checkout repository.
.PARAMETER Type
    Work category: feature, fix, doc, or refactor.
.PARAMETER Slug
    Optional lowercase hyphenated description; otherwise derived from the title.
.PARAMETER Base
    Optional explicit release/* branch when discovery is ambiguous.
.PARAMETER ExpectedBaseSha
    Verified release SHA from Resolve; required with Base and Slug for Create.
.PARAMETER CreationEvidence
    Recorded Created result required for Resume. Verifies repository, issue,
    source, release base, and starting-commit ancestry without switching branches.
.PARAMETER Action
    Resolve (default), Create, or read-only Resume. Only Create switches branches.
.PARAMETER Repository
    Optional owner/name, verified against the checkout.
.PARAMETER RepoRoot
    Repository checkout; defaults to this script's repository.
.OUTPUTS
    Resolved, BaseSelectionRequired, Preview, Created, or Resumed, with issue, source,
    release base, and the exact release commit used as the starting point.
.EXAMPLE
    ./New-IssueBranch.ps1 -Issue 60 -Type feature
.EXAMPLE
    ./New-IssueBranch.ps1 -Issue 60 -Type feature -Action Resume -CreationEvidence $Created
.NOTES
    Does not commit, push, or create a release branch.
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Issue,
    [Parameter(Mandatory)][ValidateSet('feature', 'fix', 'doc', 'refactor')][string]$Type,
    [ValidatePattern('^[a-z0-9]+(?:-[a-z0-9]+)*$')][string]$Slug,
    [string]$Base,
    [string]$ExpectedBaseSha,
    [pscustomobject]$CreationEvidence,
    [ValidateSet('Resolve', 'Create', 'Resume')][string]$Action = 'Resolve',
    [string]$Repository,
    [string]$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../../..')).Path
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '../../_shared/RepositoryTools.ps1')

if ($MyInvocation.InvocationName -ne '.') {
    Push-Location $RepoRoot
    try {
        if ($Action -eq 'Create' -and (-not $Base -or -not $Slug -or -not $ExpectedBaseSha)) {
            throw 'Create requires the verified Base, Slug, and ExpectedBaseSha from Resolve.'
        }
        $InputContext = & (Join-Path $PSScriptRoot '../../implement-issue/scripts/Get-IssueContext.ps1') `
            -Issue $Issue -Repository $Repository -RepoRoot $RepoRoot
        if ($Action -eq 'Resume') {
            if (-not $CreationEvidence -or $CreationEvidence.Status -cne 'Created' -or
                $CreationEvidence.Base -cnotlike 'release/*' -or
                $CreationEvidence.BaseSha -cnotmatch '^(?:[0-9a-f]{40}|[0-9a-f]{64})$' -or
                $CreationEvidence.Slug -cnotmatch '^[a-z0-9]+(?:-[a-z0-9]+)*$') {
                throw 'Resume requires complete recorded branch-creation evidence from Created.'
            }
            $Context = $InputContext.Context
            $ExpectedSource = "$($Type.ToLowerInvariant())/$($InputContext.Issue.number)-$($CreationEvidence.Slug)"
            if ($CreationEvidence.Context.Repository -cne $Context.Repository -or
                $CreationEvidence.Issue.number -ne $InputContext.Issue.number -or
                $CreationEvidence.Source -cne $ExpectedSource -or
                $Context.Source -cne $CreationEvidence.Source -or
                ($Base -and $Base -cne $CreationEvidence.Base) -or
                ($Slug -and $Slug -cne $CreationEvidence.Slug) -or
                ($ExpectedBaseSha -and $ExpectedBaseSha -cne $CreationEvidence.BaseSha)) {
                throw 'Resume evidence does not match the checkout repository, issue, source, or selected release.'
            }
            $Routing = Get-SkillRouting -Source $Context.Source -Base $CreationEvidence.Base
            try {
                $null = Invoke-SkillCommand git @('merge-base', '--is-ancestor', $CreationEvidence.BaseSha, 'HEAD')
            }
            catch {
                throw "Recorded starting SHA is not a verified ancestor of HEAD: $($_.Exception.Message)"
            }
            return [pscustomobject]@{
                Status = 'Resumed'; Context = $Context; Issue = $InputContext.Issue
                Source = $Context.Source; Slug = $CreationEvidence.Slug
                Base = $CreationEvidence.Base; BaseSha = $CreationEvidence.BaseSha; Routing = $Routing
            }
        }
        if ($CreationEvidence) { throw 'CreationEvidence is only supported with Action Resume.' }
        if (-not $Slug) {
            $Slug = [regex]::Replace($InputContext.Issue.title.ToLowerInvariant(), '[^a-z0-9]+', '-').Trim('-')
        }
        if ([string]::IsNullOrWhiteSpace($Slug)) {
            throw 'The issue title has no ASCII slug. Supply an explicit Slug.'
        }
        if ($Base -and $Base -cnotlike 'release/*') {
            throw 'Issue branches must start from a release/* branch, not main or another work branch.'
        }
        $Source = "$($Type.ToLowerInvariant())/$($InputContext.Issue.number)-$Slug"
        $null = Invoke-SkillCommand git @('check-ref-format', '--branch', $Source)
        $Routing = Get-SkillRouting -Source $Source -Base $Base
        if ($Routing.Status -eq 'BaseSelectionRequired') { return $Routing }
        $BaseSha = (Invoke-SkillCommand git @('rev-parse', "refs/remotes/origin/$($Routing.Base)")).Trim()
        if ($ExpectedBaseSha -and $ExpectedBaseSha -cne $BaseSha) {
            throw 'The release tip changed after resolution. Resolve again and verify the new starting SHA before retrying.'
        }
        $Existing = @((Invoke-SkillCommand git @(
            'for-each-ref', '--format=%(refname)', "refs/heads/$Source", "refs/remotes/origin/$Source"
        )) -split "`n")
        if ($Existing -contains "refs/heads/$Source" -or $Existing -contains "refs/remotes/origin/$Source") {
            throw "Branch $Source already exists locally or on origin. Select another Slug or explicitly resume the existing work."
        }
        $Context = Get-SkillContext -Repository $Repository
        $Status = 'Resolved'
        if ($Action -eq 'Create') {
            if (-not [string]::IsNullOrWhiteSpace($Context.Worktree)) {
                throw 'Branch creation requires a clean worktree. Preserve existing changes and retry; do not stash or reset automatically.'
            }
            $Status = 'Preview'
            if ($PSCmdlet.ShouldProcess($Source, "Create branch from $($Routing.Base) at $BaseSha")) {
                $null = Invoke-SkillCommand git @('switch', '--create', $Source, '--no-track', $BaseSha)
                $Context = Get-SkillContext -Repository $Repository
                if ($Context.Source -cne $Source -or $Context.Head -cne $BaseSha) {
                    throw 'Issue branch verification failed: source or starting commit differs from the selected release.'
                }
                $Status = 'Created'
            }
        }
        [pscustomobject]@{
            Status = $Status; Context = $Context; Issue = $InputContext.Issue
            Source = $Source; Slug = $Slug; Base = $Routing.Base; BaseSha = $BaseSha; Routing = $Routing
        }
    }
    finally {
        Pop-Location
    }
}