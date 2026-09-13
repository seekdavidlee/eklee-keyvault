#!/usr/bin/env pwsh
#Requires -Version 7.4

<#
.SYNOPSIS
    Creates a labeled GitHub issue associated with an open milestone.

.DESCRIPTION
    Validates a detailed requirements file, a requested issue-type label, and
    open milestones before using the GitHub CLI to create one issue. A sole
    open milestone is selected automatically. If several are open without an
    explicit selection, the script returns their titles without creating an
    issue. Use -WhatIf to run every read-only preflight without mutation.

.PARAMETER Title
    Descriptive title for the new issue.

    .PARAMETER IssueType
        The repository label to apply: feature, enhancement, bug, or documentation.

.PARAMETER RequirementsFile
    Path to a non-empty Markdown file containing the detailed issue body.

.PARAMETER Milestone
    Exact title of an open milestone. Required only when multiple milestones
    are open.

.PARAMETER Repository
    Optional GitHub repository in owner/name format. Defaults to the current
    repository resolved by gh.

.EXAMPLE
    ./.github/skills/create-github-issue/scripts/New-GitHubIssue.ps1 `
        -Title 'Document local deployment' `
        -IssueType documentation `
        -RequirementsFile ./issue.md `
        -WhatIf

.NOTES
    Requires an authenticated GitHub CLI account with issue-write access for a
    live run. The script does not create labels or milestones.
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$Title,

    [Parameter(Mandatory = $true)]
    [ValidateSet('feature', 'enhancement', 'bug', 'documentation', IgnoreCase = $false)]
    [string]$IssueType,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$RequirementsFile,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$Milestone,

    [Parameter()]
    [ValidatePattern('^[^/\s]+/[^/\s]+$')]
    [string]$Repository,

    [Parameter(DontShow = $true)]
    [switch]$NoMain
)

$ErrorActionPreference = 'Stop'

#region Functions

function Invoke-Gh {
    <#
    .SYNOPSIS
        Invokes the GitHub CLI and stops when it returns an unexpected code.
    #>
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments,

        [Parameter()]
        [int[]]$AllowedExitCodes = @(0)
    )

    $Output = @(& gh @Arguments 2>&1)
    $ExitCode = $LASTEXITCODE

    if ($ExitCode -notin $AllowedExitCodes) {
        throw "gh $($Arguments -join ' ') failed with exit code ${ExitCode}: $($Output -join [Environment]::NewLine)"
    }

    return [pscustomobject]@{
        Output   = [string[]]$Output
        ExitCode = $ExitCode
    }
}

function Get-CanonicalRepository {
    <#
    .SYNOPSIS
        Resolves a repository to its canonical owner/name form.
    #>
    [OutputType([string])]
    param(
        [Parameter()]
        [string]$Repository
    )

    $Arguments = @('repo', 'view')
    if (-not [string]::IsNullOrWhiteSpace($Repository)) {
        $Arguments += @('--repo', $Repository)
    }

    $Arguments += @('--json', 'nameWithOwner', '--jq', '.nameWithOwner')
    $Result = Invoke-Gh -Arguments $Arguments
    $CanonicalRepository = ($Result.Output | Select-Object -Last 1).ToString().Trim()

    if ([string]::IsNullOrWhiteSpace($CanonicalRepository)) {
        throw 'GitHub CLI did not resolve a repository.'
    }

    return $CanonicalRepository
}

function Get-RepositoryCollection {
    <#
    .SYNOPSIS
        Reads a paginated GitHub REST collection for one repository.
    #>
    [OutputType([hashtable[]])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Repository,

        [Parameter(Mandatory = $true)]
        [ValidateSet('labels', 'milestones')]
        [string]$Collection
    )

    $Endpoint = "repos/$Repository/${Collection}?per_page=100"
    if ($Collection -eq 'milestones') {
        $Endpoint += '&state=open'
    }

    $Result = Invoke-Gh -Arguments @('api', '--method', 'GET', '--paginate', '--slurp', $Endpoint)
    $Pages = ($Result.Output -join [Environment]::NewLine) | ConvertFrom-Json -AsHashtable

    return @($Pages | ForEach-Object { $_ })
}

function Get-IssueResult {
    <#
    .SYNOPSIS
        Creates the structured result returned by this script.
    #>
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('MilestoneSelectionRequired', 'Preview', 'Created')]
        [string]$Status,

        [Parameter(Mandatory = $true)]
        [string]$Repository,

        [Parameter(Mandatory = $true)]
        [ValidateSet('feature', 'enhancement', 'bug', 'documentation', IgnoreCase = $false)]
        [string]$IssueType,

        [Parameter(Mandatory = $true)]
        [string[]]$OpenMilestones,

        [Parameter()]
        [AllowNull()]
        [string]$Milestone,

        [Parameter(Mandatory = $true)]
        [string]$RequirementsFile,

        [Parameter()]
        [AllowNull()]
        [string]$IssueUrl
    )

    return [pscustomobject]@{
        Status           = $Status
        Repository       = $Repository
        IssueType        = $IssueType
        OpenMilestones   = $OpenMilestones
        Milestone        = $Milestone
        RequirementsFile = $RequirementsFile
        IssueUrl         = $IssueUrl
    }
}

function Invoke-GitHubIssueCreation {
    <#
    .SYNOPSIS
        Validates issue metadata and optionally creates the issue.
    #>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Title,

        [Parameter(Mandatory = $true)]
        [ValidateSet('feature', 'enhancement', 'bug', 'documentation', IgnoreCase = $false)]
        [string]$IssueType,

        [Parameter(Mandatory = $true)]
        [string]$RequirementsFile,

        [Parameter()]
        [string]$Milestone,

        [Parameter()]
        [string]$Repository
    )

    if ($null -eq (Get-Command gh -ErrorAction SilentlyContinue)) {
        throw 'GitHub CLI (gh) is required. Install it and authenticate before retrying.'
    }

    $null = Invoke-Gh -Arguments @('auth', 'status')

    $ResolvedRequirementsFile = (Resolve-Path -LiteralPath $RequirementsFile -ErrorAction Stop).Path
    $RequirementsItem = Get-Item -LiteralPath $ResolvedRequirementsFile -ErrorAction Stop
    if ($RequirementsItem.PSIsContainer) {
        throw "Requirements file '$RequirementsFile' must be a file, not a directory."
    }

    $Requirements = Get-Content -LiteralPath $ResolvedRequirementsFile -Raw -ErrorAction Stop
    if ([string]::IsNullOrWhiteSpace($Requirements)) {
        throw "Requirements file '$RequirementsFile' must contain detailed issue requirements."
    }

    $CanonicalRepository = Get-CanonicalRepository -Repository $Repository
    $Labels = Get-RepositoryCollection -Repository $CanonicalRepository -Collection 'labels'
    if ($IssueType -cnotin $Labels.name) {
        $AvailableLabels = @($Labels.name | Sort-Object) -join ', '
        throw "The '$IssueType' label does not exist in '$CanonicalRepository'. Available labels: $AvailableLabels"
    }

    $OpenMilestones = Get-RepositoryCollection -Repository $CanonicalRepository -Collection 'milestones'
    $OpenMilestoneTitles = @($OpenMilestones.title | Sort-Object -Unique)
    if ($OpenMilestoneTitles.Count -eq 0) {
        throw "No open milestones exist in '$CanonicalRepository'. Create or reopen a milestone before creating the issue."
    }

    if ([string]::IsNullOrWhiteSpace($Milestone)) {
        if ($OpenMilestoneTitles.Count -gt 1) {
            return Get-IssueResult -Status 'MilestoneSelectionRequired' -Repository $CanonicalRepository `
                -IssueType $IssueType -OpenMilestones $OpenMilestoneTitles -Milestone $null `
                -RequirementsFile $ResolvedRequirementsFile -IssueUrl $null
        }

        $ResolvedMilestone = $OpenMilestoneTitles[0]
    }
    else {
        $ResolvedMilestone = $OpenMilestoneTitles | Where-Object { $_ -ceq $Milestone } | Select-Object -First 1
        if ([string]::IsNullOrWhiteSpace($ResolvedMilestone)) {
            $AvailableMilestones = $OpenMilestoneTitles -join ', '
            throw "Milestone '$Milestone' is not open in '$CanonicalRepository'. Open milestones: $AvailableMilestones"
        }
    }

    if (-not $PSCmdlet.ShouldProcess("$CanonicalRepository issue", "Create '$Title' in milestone '$ResolvedMilestone'")) {
        return Get-IssueResult -Status 'Preview' -Repository $CanonicalRepository -IssueType $IssueType `
            -OpenMilestones $OpenMilestoneTitles -Milestone $ResolvedMilestone `
            -RequirementsFile $ResolvedRequirementsFile -IssueUrl $null
    }

    $CreateResult = Invoke-Gh -Arguments @(
        'issue', 'create', '--repo', $CanonicalRepository, '--title', $Title,
        '--body-file', $ResolvedRequirementsFile, '--label', $IssueType,
        '--milestone', $ResolvedMilestone
    )
    $IssueUrl = ($CreateResult.Output | Select-Object -Last 1).ToString().Trim()

    return Get-IssueResult -Status 'Created' -Repository $CanonicalRepository -IssueType $IssueType `
        -OpenMilestones $OpenMilestoneTitles -Milestone $ResolvedMilestone `
        -RequirementsFile $ResolvedRequirementsFile -IssueUrl $IssueUrl
}

#endregion Functions

#region Main Execution

if (-not $NoMain -and $MyInvocation.InvocationName -notin @('.', '')) {
    try {
        Invoke-GitHubIssueCreation -Title $Title -IssueType $IssueType `
            -RequirementsFile $RequirementsFile -Milestone $Milestone `
            -Repository $Repository -WhatIf:$WhatIfPreference
    }
    catch {
        Write-Error -ErrorAction Continue "GitHub issue creation failed: $($_.Exception.Message)"
        exit 1
    }
}
#endregion Main Execution