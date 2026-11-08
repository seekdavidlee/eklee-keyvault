#!/usr/bin/env pwsh
#Requires -Version 7.4

<#
.SYNOPSIS
    Preserves an issue milestone or assigns the verified release milestone.
.PARAMETER Issue
    Issue number or URL in the checkout repository.
.PARAMETER Base
    Verified release/* base. Its version is the exact open milestone title.
.PARAMETER Action
    Resolve is read-only; Ensure assigns only when no milestone exists.
.PARAMETER Repository
    Optional owner/name verified against the checkout.
.PARAMETER RepoRoot
    Checkout to inspect.
.OUTPUTS
    AlreadyAssigned, Resolved, Preview, or Assigned with verified issue metadata.
.EXAMPLE
    ./Set-IssueMilestone.ps1 -Issue 60 -Base release/1.2.0 -Action Ensure -WhatIf
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
param(
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Issue,
    [Parameter(Mandatory)][ValidatePattern('^release/.+$')][string]$Base,
    [ValidateSet('Resolve', 'Ensure')][string]$Action = 'Resolve',
    [string]$Repository,
    [string]$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../../..')).Path
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '../../_shared/RepositoryTools.ps1')

function Get-MilestoneIssue {
    param($Context, [string]$Issue)
    $Details = Invoke-SkillJson @(
        'issue', 'view', $Issue, '--repo', $Context.Repository,
        '--json', 'number,url,milestone'
    )
    if ($Details.url -cne "$($Context.RepositoryUrl)/issues/$($Details.number)") {
        throw 'The issue does not belong to the checkout repository.'
    }
    return $Details
}

if ($MyInvocation.InvocationName -ne '.') {
    Push-Location $RepoRoot
    try {
        $Context = Get-SkillContext -Repository $Repository
        $Details = Get-MilestoneIssue -Context $Context -Issue $Issue
        $Status = 'AlreadyAssigned'
        $Milestone = $Details.milestone
        if (-not $Milestone) {
            $Title = $Base.Substring('release/'.Length)
            $Pages = Invoke-SkillJson @(
                'api', '--method', 'GET', '--paginate', '--slurp',
                "repos/$($Context.Repository)/milestones?state=open&per_page=100"
            )
            $Matches = @($Pages | ForEach-Object { $_ } | Where-Object {
                $_.title -ceq $Title -and $_.state -ceq 'open'
            })
            if ($Matches.Count -ne 1) {
                throw "Expected one open milestone '$Title' for '$Base'; found $($Matches.Count). Select the correct release base or create/reopen its milestone. No assignment was made."
            }
            $Milestone = $Matches[0]
            $Status = 'Resolved'
            if ($Action -eq 'Ensure') {
                $Details = Get-MilestoneIssue -Context $Context -Issue "$($Details.number)"
                if ($Details.milestone) {
                    $Milestone = $Details.milestone
                    $Status = 'AlreadyAssigned'
                }
                else {
                    $Status = 'Preview'
                    if ($PSCmdlet.ShouldProcess($Details.url, "Assign milestone '$Title'")) {
                        $null = Invoke-SkillCommand gh @(
                            'issue', 'edit', "$($Details.number)", '--repo', $Context.Repository,
                            '--milestone', $Title
                        )
                        $Details = Get-MilestoneIssue -Context $Context -Issue "$($Details.number)"
                        if (-not $Details.milestone -or $Details.milestone.title -cne $Title) {
                            throw 'Milestone assignment could not be verified. Inspect the issue before retrying.'
                        }
                        $Milestone = $Details.milestone
                        $Status = 'Assigned'
                    }
                }
            }
        }
        [pscustomobject]@{
            Status = $Status; Repository = $Context.Repository; Issue = $Details
            Base = $Base; Milestone = $Milestone
        }
    }
    finally { Pop-Location }
}