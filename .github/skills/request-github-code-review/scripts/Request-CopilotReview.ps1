#!/usr/bin/env pwsh
#Requires -Version 7.4

<#
.SYNOPSIS
    Requests Copilot code review on an exact, verified PR head.
.PARAMETER Repository
    Expected owner/name, verified against the checkout.
.PARAMETER Number
    Existing PR number.
.PARAMETER Source
    Expected source branch.
.PARAMETER Base
    Expected base branch.
.PARAMETER Head
    Reviewed published commit SHA.
.PARAMETER ReReview
    Allows an explicitly approved repeat review of an already reviewed head.
.PARAMETER RepoRoot
    Repository checkout; defaults to this script's repository.
.OUTPUTS
    Preview, AlreadyPending, ReReviewApprovalRequired, Requested, or Blocked,
    with PR URL and observed pending requests or reviews. Never waits for approval.
.EXAMPLE
    ./Request-CopilotReview.ps1 -Repository owner/repo -Number 61 `
        -Source feature/60 -Base release/1.2.0 -Head $Sha -WhatIf
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)][ValidatePattern('^[^/\s]+/[^/\s]+$')][string]$Repository,
    [Parameter(Mandatory)][ValidateRange(1, [int]::MaxValue)][int]$Number,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Source,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Base,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Head,
    [switch]$ReReview,
    [string]$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../../..')).Path
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '../../_shared/RepositoryTools.ps1')

function Get-CopilotReviewState {
    [CmdletBinding()]
    param()

    $Pending = Invoke-SkillJson @('api', '--method', 'GET', "repos/$Repository/pulls/$Number/requested_reviewers")
    $Pages = Invoke-SkillJson @(
        'api', '--method', 'GET', '--paginate', '--slurp', "repos/$Repository/pulls/$Number/reviews?per_page=100"
    )
    $BotPattern = '^(copilot|copilot-pull-request-reviewer(\[bot\])?)$'
    $Reviews = @($Pages | ForEach-Object { $_ | ForEach-Object { $_ } } | Where-Object {
        $_.user.login -match $BotPattern -and $_.commit_id -ceq $Head
    })
    return [pscustomobject]@{
        Pending = @($Pending.users | Where-Object { $_.login -match $BotPattern })
        Reviews = $Reviews
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    Push-Location $RepoRoot
    try {
        $Context = Get-SkillContext -Repository $Repository
        $PullRequest = Get-SkillPullRequest $Context.Repository $Number
        Assert-SkillPullRequest $PullRequest $Context.Repository $Source $Base $Head
        $Before = Get-CopilotReviewState
        $Status = 'Preview'
        if ($Before.Pending.Count -gt 0) { $Status = 'AlreadyPending' }
        elseif ($Before.Reviews.Count -gt 0 -and -not $ReReview) { $Status = 'ReReviewApprovalRequired' }
        elseif ($PSCmdlet.ShouldProcess($PullRequest.html_url, 'Request Copilot code review')) {
            $null = Invoke-SkillCommand gh @(
                'pr', 'edit', "$Number", '--repo', $Context.Repository, '--add-reviewer', '@copilot'
            )
            $PullRequest = Get-SkillPullRequest $Context.Repository $Number
            Assert-SkillPullRequest $PullRequest $Context.Repository $Source $Base $Head
            $After = Get-CopilotReviewState
            $NewReviews = @($After.Reviews | Where-Object { $_.id -notin $Before.Reviews.id })
            $Status = 'Blocked'
            if ($After.Pending.Count -gt 0 -or $NewReviews.Count -gt 0) { $Status = 'Requested' }
            $Before = $After
        }
        return [pscustomobject]@{
            Status = $Status; Repository = $Context.Repository; Number = $Number
            Url = $PullRequest.html_url; Source = $Source; Base = $Base; Head = $Head
            Evidence = $Before
        }
    }
    finally {
        Pop-Location
    }
}