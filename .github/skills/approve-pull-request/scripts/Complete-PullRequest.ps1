#!/usr/bin/env pwsh
#Requires -Version 7.4

[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [ValidateSet('Preview', 'Complete')][string]$Action = 'Preview',
    [ValidateRange(1, [int]::MaxValue)][int]$PullRequest,
    [string]$ExpectedHead,
    [string]$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../../..')).Path
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '../../_shared/RepositoryTools.ps1')

Push-Location $RepoRoot
try {
    $Context = Get-SkillContext
    if ($Context.Worktree) { throw 'A clean worktree is required; no changes will be stashed or discarded.' }
    if ($Context.Source -eq 'main' -or $Context.Source -like 'release/*') {
        throw 'Check out the task branch, not main or a release branch.'
    }
    $Origin = (Invoke-SkillCommand git @('remote', 'get-url', '--push', 'origin')).Trim()
    $RepositoryPattern = [regex]::Escape($Context.Repository)
    if ($Origin -notmatch "^(https://github\.com/|git@github\.com:|ssh://git@github\.com/)$RepositoryPattern(\.git)?/?$") {
        throw 'origin must point to the GitHub repository resolved by gh.'
    }
    if (-not $PullRequest) {
        $Candidates = @(Invoke-SkillJson @(
            'pr', 'list', '--repo', $Context.Repository, '--head', $Context.Source,
            '--state', 'open', '--json', 'number', '--limit', '100'
        ))
        if ($Candidates.Count -ne 1) { throw 'Select an explicit PR number; no unique open PR was found.' }
        $PullRequest = $Candidates[0].number
    }
    $Fields = 'number,url,state,isDraft,headRefName,headRefOid,baseRefName,isCrossRepository,mergeable,mergeStateStatus,reviewDecision,statusCheckRollup,mergeCommit'
    $Pull = Invoke-SkillJson @('pr', 'view', "$PullRequest", '--repo', $Context.Repository, '--json', $Fields)
    if ($Pull.isCrossRepository -or $Pull.headRefName -cne $Context.Source -or
        $Pull.headRefOid -cne $Context.Head -or $Pull.baseRefName -cnotlike 'release/*') {
        throw 'PR must be same-repository, target release/*, and match the current branch and HEAD exactly.'
    }
    $Base = $Pull.baseRefName
    $null = Invoke-SkillCommand git @('check-ref-format', '--branch', $Base)
    $null = Invoke-SkillCommand git @('fetch', '--prune', 'origin')
    $BaseRef = "refs/remotes/origin/$Base"
    $null = Invoke-SkillCommand git @('show-ref', '--verify', $BaseRef)
    $LocalBranches = (Invoke-SkillCommand git @('for-each-ref', '--format=%(refname)', 'refs/heads/')) -split "`n"
    if ("refs/heads/$Base" -cin $LocalBranches) {
        $null = Invoke-SkillCommand git @('merge-base', '--is-ancestor', "refs/heads/$Base", $BaseRef)
    }
    $Worktrees = Invoke-SkillCommand git @('worktree', 'list', '--porcelain')
    if (($Worktrees -split "`n") -ccontains "branch refs/heads/$Base") {
        throw 'Release branch is checked out in another worktree.'
    }
    if ($Pull.state -eq 'OPEN') {
        $Published = (Invoke-SkillCommand git @('rev-parse', "refs/remotes/origin/$($Context.Source)")).Trim()
        if ($Published -cne $Context.Head) { throw 'Local HEAD differs from the published source tip.' }
        if ($Pull.isDraft -or $Pull.mergeable -ne 'MERGEABLE' -or
            $Pull.mergeStateStatus -notin @('CLEAN', 'HAS_HOOKS') -or
            $Pull.reviewDecision -eq 'CHANGES_REQUESTED') {
            throw 'PR is draft, blocked, unreviewed under required protections, or not immediately mergeable.'
        }
        foreach ($Check in $Pull.statusCheckRollup) {
            if (($Check.__typename -eq 'CheckRun' -and
                ($Check.status -ne 'COMPLETED' -or $Check.conclusion -notin @('SUCCESS', 'NEUTRAL', 'SKIPPED'))) -or
                ($Check.__typename -eq 'StatusContext' -and $Check.state -ne 'SUCCESS')) {
                throw 'PR has pending or unsuccessful checks.'
            }
        }
    }
    elseif ($Pull.state -ne 'MERGED' -or -not $Pull.mergeCommit.oid) {
        throw 'PR is closed without a verified merge.'
    }
    $Result = [ordered]@{
        Status = 'Preview'; Repository = $Context.Repository; PullRequest = $PullRequest
        Url = $Pull.url; Source = $Context.Source; Release = $Base; Head = $Context.Head
    }
    if ($Action -eq 'Preview') { return [pscustomobject]$Result }
    if ($ExpectedHead -cne $Context.Head) { throw 'ExpectedHead must match the approved preview and current HEAD.' }
    if (-not $PSCmdlet.ShouldProcess($Pull.url, "Squash merge; delete remote $($Context.Source); switch to $Base; delete local $($Context.Source)")) {
        return [pscustomobject]$Result
    }
    if ($Pull.state -eq 'OPEN') {
        $null = Invoke-SkillCommand gh @(
            'pr', 'merge', "$PullRequest", '--repo', $Context.Repository,
            '--squash', '--match-head-commit', $ExpectedHead
        )
    }
    $Verified = Invoke-SkillJson @('pr', 'view', "$PullRequest", '--repo', $Context.Repository, '--json', $Fields)
    if ($Verified.state -ne 'MERGED' -or -not $Verified.mergeCommit.oid -or
        $Verified.headRefOid -cne $ExpectedHead -or $Verified.headRefName -cne $Context.Source -or
        $Verified.baseRefName -cne $Base -or $Verified.isCrossRepository) {
        throw 'GitHub has not confirmed the exact PR head merged. Stop and inspect before retrying.'
    }
    $RemoteSource = (Invoke-SkillCommand git @('ls-remote', '--heads', 'origin', "refs/heads/$($Context.Source)")).Trim()
    if ($RemoteSource) {
        if (($RemoteSource -split '\s+')[0] -cne $ExpectedHead) {
            throw 'Remote source changed after merge; refusing deletion.'
        }
        $null = Invoke-SkillCommand git @(
            'push', "--force-with-lease=refs/heads/$($Context.Source):$ExpectedHead",
            'origin', ":refs/heads/$($Context.Source)"
        )
    }
    $null = Invoke-SkillCommand git @('fetch', '--prune', 'origin')
    $null = Invoke-SkillCommand git @('merge-base', '--is-ancestor', $Verified.mergeCommit.oid, $BaseRef)
    if ("refs/heads/$Base" -cin $LocalBranches) {
        $null = Invoke-SkillCommand git @('switch', $Base)
    }
    else {
        $null = Invoke-SkillCommand git @('switch', '--create', $Base, '--track', "origin/$Base")
    }
    $null = Invoke-SkillCommand git @('merge', '--ff-only', $BaseRef)
    $LocalSource = (Invoke-SkillCommand git @('rev-parse', "refs/heads/$($Context.Source)")).Trim()
    if ($LocalSource -cne $ExpectedHead) { throw 'Local source changed; refusing deletion.' }
    $null = Invoke-SkillCommand git @('branch', '-D', '--', $Context.Source)
    $Result.Status = 'Completed'
    $Result['MergeCommit'] = $Verified.mergeCommit.oid
    return [pscustomobject]$Result
}
finally {
    Pop-Location
}