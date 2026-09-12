#!/usr/bin/env pwsh
# Copyright (c) 2026 Microsoft Corporation. All rights reserved.
# SPDX-License-Identifier: MIT
#Requires -Version 7.4

<#
.SYNOPSIS
    Creates and pushes a version-specific release branch from main.

.DESCRIPTION
    Accepts either a stable semantic version or a semantic-version increment
    (major, minor, or patch). Increment requests are calculated from the highest
    existing release branch. The script completes its read-only Git and GitHub
    preflight checks before creating a milestone, a local release/<version>
    branch at main, and the remote branch on origin. Release publication is
    owned by the branch workflow.

    The preflight requires local main to be reachable from origin/main, a clean
    working tree unless -Force is supplied, no matching local or remote release
    branch, no matching GitHub milestone, and an authenticated GitHub CLI account
    with repository write access. A live run creates only the milestone and
    release branch. It does not check out a branch, create tags, or clean up
    state after a later mutation fails.

    Immediately before pushing, the script checks for local changes again. With
    -Force, it includes those changes in the release branch automatically.

.PARAMETER Version
    A stable semantic version in MAJOR.MINOR.PATCH form, or the major, minor, or
    patch segment to increment from the highest existing release branch.

.PARAMETER Force
    Allows release preparation to continue with uncommitted changes and include
    them in the release branch. All other preflight safeguards still apply.

.PARAMETER RepoRoot
    The repository root. Defaults to the repository root inferred from this
    script's location.

.OUTPUTS
    PSCustomObject containing the resolved version, previous version, release
    branch, milestone state, target commit, mutation states, local-change
    handling, and the WhatIf and Force flags.

.NOTES
    -WhatIf performs all read-only preflight checks and reports planned
    mutations without changing GitHub or Git refs. Use -Confirm when a second
    PowerShell confirmation is required for a live mutation.

.EXAMPLE
    ./.github/skills/create-release/scripts/New-Release.ps1 -Version 1.0.0 -WhatIf

.EXAMPLE
    ./.github/skills/create-release/scripts/New-Release.ps1 -Version minor

.EXAMPLE
    ./.github/skills/create-release/scripts/New-Release.ps1 -Version patch -Force
#>

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$Version,

    [Parameter()]
    [switch]$Force,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..\..')).Path
)

$ErrorActionPreference = 'Stop'

#region Functions

function Invoke-Git {
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments,

        [Parameter()]
        [int[]]$AllowedExitCodes = @(0)
    )

    $output = @(& git @Arguments 2>&1)
    $exitCode = $LASTEXITCODE

    if ($exitCode -notin $AllowedExitCodes) {
        throw "git $($Arguments -join ' ') failed with exit code ${exitCode}: $($output -join [Environment]::NewLine)"
    }

    return [pscustomobject]@{
        Output   = [string[]]$output
        ExitCode = $exitCode
    }
}

function Invoke-Gh {
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments
    )

    $output = @(& gh @Arguments 2>&1)
    $exitCode = $LASTEXITCODE

    if ($exitCode -ne 0) {
        throw "gh $($Arguments -join ' ') failed with exit code ${exitCode}: $($output -join [Environment]::NewLine)"
    }

    return [pscustomobject]@{
        Output   = [string[]]$output
        ExitCode = $exitCode
    }
}

function Get-StableVersionParts {
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Version
    )

    $versionMatch = [regex]::Match(
        $Version,
        '^(?<major>0|[1-9]\d*)\.(?<minor>0|[1-9]\d*)\.(?<patch>0|[1-9]\d*)$'
    )

    if (-not $versionMatch.Success) {
        throw "Version '$Version' must use three numeric semantic-version segments without a prefix."
    }

    try {
        return [pscustomobject]@{
            Major = [uint64]::Parse($versionMatch.Groups['major'].Value)
            Minor = [uint64]::Parse($versionMatch.Groups['minor'].Value)
            Patch = [uint64]::Parse($versionMatch.Groups['patch'].Value)
        }
    }
    catch {
        throw "Version '$Version' contains a segment that cannot be incremented."
    }
}

function Test-StableVersion {
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Version
    )

    return [regex]::IsMatch(
        $Version,
        '^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$'
    )
}

function Compare-StableVersions {
    [OutputType([int])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Left,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Right
    )

    $leftParts = Get-StableVersionParts -Version $Left
    $rightParts = Get-StableVersionParts -Version $Right

    foreach ($segment in @('Major', 'Minor', 'Patch')) {
        if ($leftParts.$segment -lt $rightParts.$segment) {
            return -1
        }
        if ($leftParts.$segment -gt $rightParts.$segment) {
            return 1
        }
    }

    return 0
}

function Get-KnownReleaseBranchNames {
    [OutputType([string[]])]
    param()

    $branchNames = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::Ordinal
    )

    $refs = Invoke-Git -Arguments @(
        'for-each-ref',
        '--format=%(refname)',
        'refs/heads/release',
        'refs/remotes/origin/release'
    )

    foreach ($ref in $refs.Output) {
        if ($ref -match '^refs/(?:heads|remotes/origin)/(?<branch>release/.+)$') {
            [void]$branchNames.Add($Matches['branch'])
        }
    }

    $remoteRefs = Invoke-Git -Arguments @(
        'ls-remote',
        '--heads',
        'origin',
        'refs/heads/release/*'
    )

    foreach ($remoteRef in $remoteRefs.Output) {
        if ($remoteRef -match '^[0-9a-fA-F]+\s+refs/heads/(?<branch>release/.+)$') {
            [void]$branchNames.Add($Matches['branch'])
        }
    }

    return @($branchNames | ForEach-Object { $_ })
}

function Get-PreviousReleaseVersion {
    [OutputType([string])]
    param()

    $previousVersion = $null
    foreach ($branchName in Get-KnownReleaseBranchNames) {
        $branchVersion = $branchName -replace '^release/', ''
        if (-not (Test-StableVersion -Version $branchVersion)) {
            continue
        }

        if ($null -eq $previousVersion -or (Compare-StableVersions -Left $branchVersion -Right $previousVersion) -gt 0) {
            $previousVersion = $branchVersion
        }
    }

    return $previousVersion
}

function Get-NextReleaseVersion {
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$PreviousVersion,

        [Parameter(Mandatory = $true)]
        [ValidateSet('major', 'minor', 'patch')]
        [string]$Bump
    )

    $versionParts = Get-StableVersionParts -Version $PreviousVersion

    switch ($Bump) {
        'major' {
            if ($versionParts.Major -eq [uint64]::MaxValue) {
                throw "Version '$PreviousVersion' contains a segment that cannot be incremented."
            }

            return "$($versionParts.Major + 1).0.0"
        }
        'minor' {
            if ($versionParts.Minor -eq [uint64]::MaxValue) {
                throw "Version '$PreviousVersion' contains a segment that cannot be incremented."
            }

            return "$($versionParts.Major).$($versionParts.Minor + 1).0"
        }
        'patch' {
            if ($versionParts.Patch -eq [uint64]::MaxValue) {
                throw "Version '$PreviousVersion' contains a segment that cannot be incremented."
            }

            return "$($versionParts.Major).$($versionParts.Minor).$($versionParts.Patch + 1)"
        }
    }
}

function Resolve-ReleaseVersion {
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$RequestedVersion,

        [Parameter()]
        [AllowNull()]
        [string]$PreviousVersion
    )

    $normalizedRequest = $RequestedVersion.ToLowerInvariant()
    if ($normalizedRequest -in @('major', 'minor', 'patch')) {
        if ([string]::IsNullOrWhiteSpace($PreviousVersion)) {
            throw "A '$normalizedRequest' increment requires an existing release branch. Specify a full version for the first release."
        }

        return [pscustomobject]@{
            PreviousVersion = $PreviousVersion
            Version = Get-NextReleaseVersion -PreviousVersion $PreviousVersion -Bump $normalizedRequest
            Request = $normalizedRequest
        }
    }

    $null = Get-StableVersionParts -Version $RequestedVersion
    if (-not [string]::IsNullOrWhiteSpace($PreviousVersion) -and (Compare-StableVersions -Left $RequestedVersion -Right $PreviousVersion) -le 0) {
        throw "Version '$RequestedVersion' must be greater than the highest existing release branch version '$PreviousVersion'."
    }

    return [pscustomobject]@{
        PreviousVersion = $PreviousVersion
        Version = $RequestedVersion
        Request = $RequestedVersion
    }
}

function Assert-MutationApproved {
    param(
        [Parameter(Mandatory = $true)]
        [bool]$Approved,

        [Parameter(Mandatory = $true)]
        [bool]$IsWhatIf,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Action
    )

    if (-not $Approved -and -not $IsWhatIf) {
        throw "Release preparation was cancelled before '$Action'. No later mutation was attempted."
    }
}

function Add-WorkingTreeChangesToReleaseBranch {
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$ReleaseBranch
    )

    $temporaryIndex = Join-Path ([IO.Path]::GetTempPath()) "release-index-$([guid]::NewGuid().ToString('N'))"
    $previousIndex = $env:GIT_INDEX_FILE

    try {
        $env:GIT_INDEX_FILE = $temporaryIndex
        $null = Invoke-Git -Arguments @('read-tree', $ReleaseBranch)
        $parentCommit = ((Invoke-Git -Arguments @('rev-parse', "$ReleaseBranch^{commit}")).Output -join '').Trim()
        if ([string]::IsNullOrWhiteSpace($parentCommit)) {
            throw "Git did not resolve the release branch commit."
        }

        $null = Invoke-Git -Arguments @('add', '--all', '--', '.')
        $tree = ((Invoke-Git -Arguments @('write-tree')).Output -join '').Trim()
        if ([string]::IsNullOrWhiteSpace($tree)) {
            throw 'Git did not produce a tree for the local changes.'
        }

        $commit = ((Invoke-Git -Arguments @(
            'commit-tree',
            $tree,
            '-p',
            $parentCommit,
            '-m',
            "Include local changes in $ReleaseBranch"
        )).Output -join '').Trim()
        if ([string]::IsNullOrWhiteSpace($commit)) {
            throw 'Git did not produce a commit for the local changes.'
        }

        $null = Invoke-Git -Arguments @('update-ref', "refs/heads/$ReleaseBranch", $commit, $parentCommit)
        return $commit
    }
    finally {
        if ([string]::IsNullOrWhiteSpace($previousIndex)) {
            Remove-Item Env:GIT_INDEX_FILE -ErrorAction SilentlyContinue
        }
        else {
            $env:GIT_INDEX_FILE = $previousIndex
        }

        Remove-Item -LiteralPath $temporaryIndex -Force -ErrorAction SilentlyContinue
    }
}

function Get-GitHubMilestones {
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Repository
    )

    $result = Invoke-Gh -Arguments @(
        'api',
        '--paginate',
        '--slurp',
        "/repos/$Repository/milestones?state=all&per_page=100"
    )
    $json = $result.Output -join [Environment]::NewLine

    try {
        $pages = @($json | ConvertFrom-Json -Depth 10)
    }
    catch {
        throw "GitHub returned invalid milestone data: $($_.Exception.Message)"
    }

    return @($pages | ForEach-Object { $_ | ForEach-Object { $_ } })
}

function Assert-GitHubRepositoryWriteAccess {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Repository
    )

    $result = Invoke-Gh -Arguments @(
        'api',
        "/repos/$Repository",
        '--jq',
        '.permissions.push'
    )
    $hasWriteAccess = ($result.Output -join '').Trim()

    if ($hasWriteAccess -cne 'true') {
        throw "The authenticated GitHub account does not have write access to '$Repository'. Authenticate gh with an account that can create milestones before preparing a release."
    }
}

function Invoke-ReleasePreparation {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Version,

        [Parameter()]
        [switch]$Force,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$RepoRoot
    )

    $resolvedRepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path

    if ($null -eq (Get-Command -Name git -ErrorAction SilentlyContinue)) {
        throw 'Git is required to create and push a release branch.'
    }
    if ($null -eq (Get-Command -Name gh -ErrorAction SilentlyContinue)) {
        throw 'GitHub CLI (gh) is required to query and create release milestones.'
    }

    Push-Location $resolvedRepoRoot
    try {
        $repositoryCheck = Invoke-Git -Arguments @('rev-parse', '--is-inside-work-tree')
        if (($repositoryCheck.Output -join '').Trim() -ne 'true') {
            throw "'$resolvedRepoRoot' is not a Git repository."
        }

        $workingTree = (Invoke-Git -Arguments @('status', '--porcelain')).Output
        if ($workingTree.Count -gt 0) {
            if (-not $Force) {
                throw 'The working tree must be clean before preparing a release. Use -Force to continue with uncommitted changes.'
            }

            Write-Warning 'Continuing release preparation with uncommitted changes because -Force was specified.'
        }

        $null = Invoke-Git -Arguments @('show-ref', '--verify', '--quiet', 'refs/heads/main')
        $null = Invoke-Git -Arguments @('show-ref', '--verify', '--quiet', 'refs/remotes/origin/main')
        $mainIsPublished = Invoke-Git -Arguments @('merge-base', '--is-ancestor', 'main', 'origin/main') -AllowedExitCodes @(0, 1)
        if ($mainIsPublished.ExitCode -ne 0) {
            throw 'Local main is not reachable from origin/main. Update or reconcile main before preparing a release.'
        }

        $null = Invoke-Git -Arguments @('remote', 'get-url', 'origin')
        $previousVersion = Get-PreviousReleaseVersion
        $release = Resolve-ReleaseVersion -RequestedVersion $Version -PreviousVersion $previousVersion
        $releaseVersion = $release.Version
        $releaseBranch = "release/$releaseVersion"

        $existingLocalBranch = Invoke-Git -Arguments @('show-ref', '--verify', '--quiet', "refs/heads/$releaseBranch") -AllowedExitCodes @(0, 1)
        if ($existingLocalBranch.ExitCode -eq 0) {
            throw "Local release branch '$releaseBranch' already exists."
        }

        $existingRemoteBranch = Invoke-Git -Arguments @(
            'ls-remote',
            '--exit-code',
            '--heads',
            'origin',
            "refs/heads/$releaseBranch"
        ) -AllowedExitCodes @(0, 2)
        if ($existingRemoteBranch.ExitCode -eq 0) {
            throw "Remote release branch 'origin/$releaseBranch' already exists."
        }

        $null = Invoke-Gh -Arguments @('auth', 'status')
        $repository = ((Invoke-Gh -Arguments @('repo', 'view', '--json', 'nameWithOwner', '--jq', '.nameWithOwner')).Output -join '').Trim()
        if ([string]::IsNullOrWhiteSpace($repository)) {
            throw 'GitHub CLI did not return the current repository name.'
        }
        Assert-GitHubRepositoryWriteAccess -Repository $repository

        $matchingMilestones = @(Get-GitHubMilestones -Repository $repository | Where-Object { $_.title -ceq $releaseVersion })
        if ($matchingMilestones.Count -gt 0) {
            $milestoneStates = ($matchingMilestones | ForEach-Object { $_.state }) -join ', '
            throw "GitHub milestone '$releaseVersion' already exists ($milestoneStates). Resolve the existing milestone before preparing this release. No release branch was created or pushed."
        }

        $milestoneCreated = $false
        if ($matchingMilestones.Count -eq 0) {
            $createMilestoneApproved = $PSCmdlet.ShouldProcess(
                "$repository milestone $releaseVersion",
                'Create GitHub milestone'
            )
            Assert-MutationApproved -Approved $createMilestoneApproved -IsWhatIf $WhatIfPreference -Action 'creating the GitHub milestone'
            if ($createMilestoneApproved) {
                $null = Invoke-Gh -Arguments @(
                    'api',
                    '--method',
                    'POST',
                    "/repos/$repository/milestones",
                    '-f',
                    "title=$releaseVersion"
                )
                $milestoneCreated = $true
            }
        }

        $targetCommit = ((Invoke-Git -Arguments @('rev-parse', 'main^{commit}')).Output -join '').Trim()
        $branchCreated = $false
        $localChangesDetected = $false
        $localChangesIncluded = $false
        $localChangesCommit = $null
        $branchPushed = $false

        $createBranchApproved = $PSCmdlet.ShouldProcess(
            "refs/heads/$releaseBranch at $targetCommit",
            'Create release branch'
        )
        Assert-MutationApproved -Approved $createBranchApproved -IsWhatIf $WhatIfPreference -Action 'creating the release branch'
        if ($createBranchApproved) {
            $null = Invoke-Git -Arguments @('branch', $releaseBranch, 'main')
            $branchCreated = $true
        }

        $changesBeforePush = @(Invoke-Git -Arguments @('status', '--porcelain')).Output
        if ($changesBeforePush.Count -gt 0) {
            $localChangesDetected = $true
            if ($WhatIfPreference) {
                Write-Warning "Local changes would be included in '$releaseBranch' before pushing during a live run because -Force was specified."
            }
            elseif ($Force) {
                Write-Warning "Including local changes in '$releaseBranch' because -Force was specified."
                try {
                    $localChangesCommit = Add-WorkingTreeChangesToReleaseBranch -ReleaseBranch $releaseBranch
                    $localChangesIncluded = $true
                }
                catch {
                    throw "Including local changes in '$releaseBranch' failed. Resolve the failure manually; no push was attempted. $($_.Exception.Message)"
                }
            }
            else {
                throw "Local changes were detected before pushing '$releaseBranch'. Use -Force to include them in the release branch."
            }
        }

        $pushBranchApproved = $PSCmdlet.ShouldProcess(
            "origin refs/heads/$releaseBranch",
            'Push release branch'
        )
        Assert-MutationApproved -Approved $pushBranchApproved -IsWhatIf $WhatIfPreference -Action 'pushing the release branch'
        if ($pushBranchApproved) {
            try {
                $null = Invoke-Git -Arguments @('push', 'origin', "refs/heads/$releaseBranch")
                $branchPushed = $true
            }
            catch {
                throw "Pushing '$releaseBranch' failed after creating the local branch. Resolve the failure manually; no automatic cleanup was attempted. $($_.Exception.Message)"
            }
        }

        $milestoneState = if ($matchingMilestones.Count -gt 0) {
            ($matchingMilestones | ForEach-Object { $_.state }) -join ', '
        }
        elseif ($milestoneCreated) {
            'created'
        }
        else {
            'not-created'
        }

        return [pscustomobject]@{
            PreviousVersion = $release.PreviousVersion
            Version = $release.Version
            Request = $release.Request
            ReleaseBranch = $releaseBranch
            Milestone = $releaseVersion
            MilestoneState = $milestoneState
            MilestoneExists = ($matchingMilestones.Count -gt 0) -or $milestoneCreated
            MilestoneCreated = $milestoneCreated
            TargetCommit = $targetCommit
            BranchCreated = $branchCreated
            LocalChangesDetected = $localChangesDetected
            LocalChangesIncluded = $localChangesIncluded
            LocalChangesCommit = $localChangesCommit
            BranchPushed = $branchPushed
            WhatIf = [bool]$WhatIfPreference
            Force = [bool]$Force
        }
    }
    finally {
        Pop-Location
    }
}

#endregion Functions

#region Main Execution

if ($MyInvocation.InvocationName -ne '.') {
    try {
        Invoke-ReleasePreparation -Version $Version -Force:$Force -RepoRoot $RepoRoot -WhatIf:$WhatIfPreference
    }
    catch {
        Write-Error -ErrorAction Continue "Release preparation failed: $($_.Exception.Message)"
        exit 1
    }
}

#endregion Main Execution
