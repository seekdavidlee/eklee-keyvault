#!/usr/bin/env pwsh
#Requires -Version 7.4

<#
.SYNOPSIS
    Shared command, repository, routing, and review-snapshot helpers.
.DESCRIPTION
    Dot-source from skill scripts after entering the requested repository.
    External command failures terminate the calling operation.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

function Invoke-SkillCommand {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string]$Command,
        [Parameter(Mandatory)]
        [string[]]$Arguments
    )

    $null = Get-Command $Command -ErrorAction Stop
    $Output = @(& $Command @Arguments 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw "$Command failed ($LASTEXITCODE): $($Output -join [Environment]::NewLine)"
    }
    return ($Output -join "`n")
}

function Invoke-SkillJson {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string[]]$Arguments)

    $Output = Invoke-SkillCommand -Command gh -Arguments $Arguments
    return ConvertFrom-Json -InputObject $Output -AsHashtable -Depth 100
}

function Get-SkillContext {
    [CmdletBinding()]
    param([string]$Repository)

    $null = Invoke-SkillCommand git @('rev-parse', '--show-toplevel')
    $Source = (Invoke-SkillCommand git @('branch', '--show-current')).Trim()
    if ([string]::IsNullOrWhiteSpace($Source)) {
        throw 'Detached HEAD is not supported. Check out the intended source branch.'
    }
    $null = Invoke-SkillCommand gh @('auth', 'status')
    $CurrentRepository = Invoke-SkillJson @('repo', 'view', '--json', 'nameWithOwner,url')
    if ($Repository) {
        $RequestedRepository = Invoke-SkillJson @('repo', 'view', $Repository, '--json', 'nameWithOwner,url')
        if ($RequestedRepository.nameWithOwner -ine $CurrentRepository.nameWithOwner) {
            throw 'The requested repository does not match the current checkout.'
        }
    }
    if (-not $CurrentRepository.nameWithOwner -or -not $CurrentRepository.url) {
        throw 'GitHub did not resolve the repository identity.'
    }
    return [pscustomobject]@{
        Repository = $CurrentRepository.nameWithOwner
        RepositoryUrl = $CurrentRepository.url
        Source = $Source
        Head = (Invoke-SkillCommand git @('rev-parse', 'HEAD')).Trim()
        Worktree = Invoke-SkillCommand git @('status', '--short')
    }
}

function Get-SkillRouting {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Source,
        [string]$Base
    )

    $null = Invoke-SkillCommand git @('fetch', '--prune', 'origin')
    $Candidates = @((Invoke-SkillCommand git @(
        'for-each-ref', '--format=%(refname:strip=3)', 'refs/remotes/origin/release/'
    )) -split "`n" | Where-Object { $_ })
    $Reason = 'Explicit base'
    if (-not $Base) {
        if ($Source -clike 'release/*') {
            $Base = 'main'
            $Reason = 'Release branch targets main'
        }
        elseif ($Candidates.Count -eq 1) {
            $Base = $Candidates[0]
            $Reason = 'Sole active release branch'
        }
        else {
            return [pscustomobject]@{
                Status = 'BaseSelectionRequired'; Source = $Source
                Base = $null; Candidates = $Candidates; Reason = 'No unique active release'
            }
        }
    }
    $null = Invoke-SkillCommand git @('check-ref-format', '--branch', $Base)
    $null = Invoke-SkillCommand git @('show-ref', '--verify', "refs/remotes/origin/$Base")
    if ($Source -ceq $Base) {
        throw 'Source and base must be different branches.'
    }
    return [pscustomobject]@{
        Status = 'Resolved'; Source = $Source; Base = $Base
        Candidates = $Candidates; Reason = $Reason
    }
}

function Get-SkillSnapshot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)][string]$Base,
        [string[]]$TaskFiles
    )

    $BaseRef = "refs/remotes/origin/$Base"
    $BaseSha = (Invoke-SkillCommand git @('rev-parse', $BaseRef)).Trim()
    $Committed = @((Invoke-SkillCommand git @(
        '-c', 'core.quotepath=false', 'diff', '--name-only', '-z', '--no-renames', "$BaseRef...HEAD", '--'
    )) -split "`0" | Where-Object { $_ })
    $Working = @((Invoke-SkillCommand git @(
        '-c', 'core.quotepath=false', 'diff', '--name-only', '-z', '--no-renames', 'HEAD', '--'
    )) -split "`0" | Where-Object { $_ })
    $Untracked = @((Invoke-SkillCommand git @(
        '-c', 'core.quotepath=false', 'ls-files', '-z', '--others', '--exclude-standard'
    )) -split "`0" | Where-Object { $_ })
    $Working = @($Working + $Untracked | Sort-Object -Unique)
    $Excluded = @()
    if ($TaskFiles) {
        $TaskFiles = @($TaskFiles | ForEach-Object { $_.Replace('\', '/') })
        $Excluded = @($Working | Where-Object { $_ -cnotin $TaskFiles })
        $Working = @($Working | Where-Object { $_ -cin $TaskFiles })
    }
    $Modes = [Collections.Generic.Dictionary[string, string]]::new([StringComparer]::Ordinal)
    $Index = Invoke-SkillCommand git @('ls-files', '--stage', '-z')
    foreach ($Entry in $Index -split "`0" | Where-Object { $_ }) {
        if ($Entry -notmatch '(?s)^(?<mode>\d{6}) [0-9a-f]+ (?<stage>\d)\t(?<path>.+)$' -or $Matches.stage -ne '0') {
            throw 'Cannot fingerprint an invalid or unmerged Git index.'
        }
        $Modes[$Matches.path] = $Matches.mode
    }
    $RawDiff = (Invoke-SkillCommand git @('diff', '--raw', '-z', '--no-renames', 'HEAD', '--')) -split "`0"
    for ($EntryIndex = 0; $EntryIndex -lt $RawDiff.Count - 1; $EntryIndex += 2) {
        if ($RawDiff[$EntryIndex] -notmatch '^:\d{6} (?<mode>\d{6}) [0-9a-f]+ [0-9a-f]+ [A-Z]\d*$') {
            throw 'Cannot fingerprint Git working-tree mode changes.'
        }
        $Modes[$RawDiff[$EntryIndex + 1]] = $Matches.mode
    }
    $Root = (Get-Location).Path.TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
    $Files = @($Committed + $Working | Sort-Object -Unique | ForEach-Object {
        $FullPath = [IO.Path]::GetFullPath((Join-Path $Root $_))
        if (-not $FullPath.StartsWith($Root, [StringComparison]::OrdinalIgnoreCase)) {
            throw "File is outside the repository: $_"
        }
        if (Test-Path -LiteralPath $FullPath -PathType Leaf) {
            $Hash = (Get-FileHash -LiteralPath $FullPath -Algorithm SHA256).Hash
            $Mode = '100644'
            if ($Modes.ContainsKey($_)) { $Mode = $Modes[$_] }
            elseif ((Get-Item -LiteralPath $FullPath).LinkType) { $Mode = '120000' }
            elseif (-not $IsWindows -and
                ([IO.File]::GetUnixFileMode($FullPath) -band [IO.UnixFileMode]::UserExecute)) {
                $Mode = '100755'
            }
        }
        else {
            $Hash = $null
            $Mode = '000000'
        }
        [ordered]@{ Path = $_; Hash = $Hash; GitMode = $Mode }
    })
    $Identity = [ordered]@{
        Repository = $Context.Repository; Source = $Context.Source
        Base = $Base; BaseSha = $BaseSha; Files = $Files
    }
    $Bytes = [Text.Encoding]::UTF8.GetBytes(($Identity | ConvertTo-Json -Depth 10 -Compress))
    $Fingerprint = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($Bytes))
    return [pscustomobject]@{
        Repository = $Context.Repository; Source = $Context.Source; Base = $Base
        Head = $Context.Head; BaseSha = $BaseSha; Fingerprint = $Fingerprint
        Files = $Files; WorkingFiles = $Working
        ExcludedWorkingFiles = $Excluded; UntrackedFiles = $Untracked
        BranchDiff = Invoke-SkillCommand git @('diff', '--no-ext-diff', '--no-textconv', "$BaseRef...HEAD", '--')
        StagedDiff = Invoke-SkillCommand git @('diff', '--no-ext-diff', '--no-textconv', '--cached', '--')
        UnstagedDiff = Invoke-SkillCommand git @('diff', '--no-ext-diff', '--no-textconv', '--')
    }
}

function Get-SkillPullRequest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Repository,
        [Parameter(Mandatory)][int]$Number
    )

    return Invoke-SkillJson @('api', '--method', 'GET', "repos/$Repository/pulls/$Number")
}

function Assert-SkillPullRequest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$PullRequest,
        [Parameter(Mandatory)][string]$Repository,
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Base,
        [Parameter(Mandatory)][string]$Head
    )

    if ($PullRequest.state -ne 'open' -or
        $PullRequest.base.repo.full_name -ine $Repository -or
        $PullRequest.head.repo.full_name -ine $Repository -or
        $PullRequest.head.ref -cne $Source -or $PullRequest.base.ref -cne $Base -or
        $PullRequest.head.sha -cne $Head) {
        throw 'PR repository, state, source, base, or head differs from the reviewed handoff.'
    }
}