#!/usr/bin/env pwsh
#Requires -Version 7.4

<#
.SYNOPSIS
    Resolves release-aware routing, previews, creates, or reuses one verified PR.
.DESCRIPTION
    Resolve only fetches and resolves routing. Preview and Create require
    published reviewed content, check all open PRs for the source, and reject
    ambiguous or differently targeted PRs. No action commits or pushes.
.PARAMETER Action
    Resolve (default), Preview, or Create. Create supports WhatIf and Confirm.
.PARAMETER Base
    Optional explicit origin branch; otherwise release-aware routing applies.
.PARAMETER Title
    Approved PR title; required for Preview and Create.
.PARAMETER BodyFile
    Approved non-empty Markdown body; required for Preview and Create.
.PARAMETER ReviewedFingerprint
    Fingerprint from passing local review; required for Preview and Create.
.PARAMETER TaskFiles
    Same working-file selection used in the review snapshot, if any.
.PARAMETER RepoRoot
    Repository checkout; defaults to this script's repository.
.OUTPUTS
    Resolved, BaseSelectionRequired, PullRequestSelectionRequired, Preview,
    Created, or Reused, with the verified branch pair and published PR identity.
.EXAMPLE
    ./Invoke-PullRequest.ps1 -Action Resolve
.EXAMPLE
    ./Invoke-PullRequest.ps1 -Action Preview -Base release/1.2.0 `
        -Title 'Fix validation' -BodyFile ./pr.md -ReviewedFingerprint $Fingerprint
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [ValidateSet('Resolve', 'Preview', 'Create')][string]$Action = 'Resolve',
    [string]$Base,
    [string]$Title,
    [string]$BodyFile,
    [string]$ReviewedFingerprint,
    [string[]]$TaskFiles,
    [string]$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../../..')).Path
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '../../_shared/RepositoryTools.ps1')

function Get-SourcePullRequests {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Context)

    $Head = [uri]::EscapeDataString("$($Context.Repository.Split('/')[0]):$($Context.Source)")
    $Pages = Invoke-SkillJson @(
        'api', '--method', 'GET', '--paginate', '--slurp',
        "repos/$($Context.Repository)/pulls?state=open&head=$Head&per_page=100"
    )
    return @($Pages | ForEach-Object { $_ | ForEach-Object { $_ } })
}

if ($MyInvocation.InvocationName -ne '.') {
    Push-Location $RepoRoot
    try {
        $Context = Get-SkillContext
        $Routing = Get-SkillRouting -Source $Context.Source -Base $Base
        if ($Routing.Status -eq 'BaseSelectionRequired') { return $Routing }
        if ($Action -eq 'Resolve') {
            return [pscustomobject]@{ Status = 'Resolved'; Context = $Context; Routing = $Routing }
        }
        if ([string]::IsNullOrWhiteSpace($Title) -or
            [string]::IsNullOrWhiteSpace($ReviewedFingerprint) -or
            -not $BodyFile -or -not (Test-Path -LiteralPath $BodyFile -PathType Leaf) -or
            [string]::IsNullOrWhiteSpace((Get-Content -LiteralPath $BodyFile -Raw))) {
            throw 'Preview/Create require a title, non-empty body file, and passing review fingerprint.'
        }
        $Snapshot = Get-SkillSnapshot -Context $Context -Base $Routing.Base -TaskFiles $TaskFiles
        if ($Snapshot.Fingerprint -cne $ReviewedFingerprint) {
            throw 'Content or base changed after local review. Obtain targeted re-review.'
        }
        if ($Snapshot.WorkingFiles.Count -gt 0) {
            throw 'Reviewed task files have unpublished working changes. Obtain commit and push approval separately.'
        }
        $Published = (Invoke-SkillCommand git @(
            'rev-parse', "refs/remotes/origin/$($Context.Source)"
        )).Trim()
        if ($Context.Head -cne $Published) {
            throw 'Local HEAD is not the published source tip. Obtain named-branch push approval separately.'
        }
        $Matches = @(Get-SourcePullRequests -Context $Context)
        if ($Matches.Count -gt 1 -or
            ($Matches.Count -eq 1 -and $Matches[0].base.ref -cne $Routing.Base)) {
            return [pscustomobject]@{
                Status = 'PullRequestSelectionRequired'; Context = $Context
                Routing = $Routing; PullRequests = $Matches
            }
        }
        $Status = 'Preview'
        $PullRequest = $null
        if ($Matches.Count -eq 1) {
            $PullRequest = Get-SkillPullRequest $Context.Repository $Matches[0].number
            Assert-SkillPullRequest $PullRequest $Context.Repository $Context.Source $Routing.Base $Published
            if ($PullRequest.title -cne $Title -or
                $PullRequest.body -cne (Get-Content -LiteralPath $BodyFile -Raw)) {
                throw 'Existing PR title/body differ from approved content. Obtain approval before updating or reusing its description.'
            }
            $Status = 'Reused'
        }
        elseif ($Action -eq 'Create' -and
            $PSCmdlet.ShouldProcess($Context.Repository, "Create PR $($Context.Source) -> $($Routing.Base)")) {
            $Created = Invoke-SkillCommand gh @(
                'pr', 'create', '--repo', $Context.Repository, '--head', $Context.Source,
                '--base', $Routing.Base, '--title', $Title, '--body-file', $BodyFile
            )
            $Url = ($Created -split "`n" | Select-Object -Last 1).Trim()
            $Prefix = [regex]::Escape("$($Context.RepositoryUrl)/pull/")
            if ($Url -notmatch "^$Prefix(?<number>\d+)$") {
                throw 'Uncertain creation result. Run Preview to inspect server state before retrying.'
            }
            $PullRequest = Get-SkillPullRequest $Context.Repository ([int]$Matches['number'])
            Assert-SkillPullRequest $PullRequest $Context.Repository $Context.Source $Routing.Base $Published
            $Status = 'Created'
        }
        return [pscustomobject]@{
            Status = $Status; Repository = $Context.Repository; Source = $Context.Source
            Base = $Routing.Base; Head = $Published; Routing = $Routing
            Title = $Title; Body = Get-Content -LiteralPath $BodyFile -Raw
            PullRequest = $PullRequest; Fingerprint = $Snapshot.Fingerprint
        }
    }
    finally {
        Pop-Location
    }
}