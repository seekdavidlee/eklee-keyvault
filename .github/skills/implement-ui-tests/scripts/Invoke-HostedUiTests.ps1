#!/usr/bin/env pwsh
#Requires -Version 7.4

<#
.SYNOPSIS
    Validates, publishes, and inspects hosted UI-test iterations using GitHub CLI.
.DESCRIPTION
    Local validation never launches a browser. Publication is restricted to
    explicit task files and one approved branch. CI observation uses gh only.
.PARAMETER Action
    Begin, Validate, Publish, Inspect, or Wait. Inspect is the read-only default.
.PARAMETER TaskScope
    Scope returned by Begin before editing; preserves initial dirty-file boundaries.
.PARAMETER TestFiles
    Existing spec paths relative to Eklee.KeyVault.UI, under e2e.
.PARAMETER TaskFiles
    Exact repository-relative files to commit. Required for Publish.
.PARAMETER ExpectedBranch
    Previously resolved source branch. Begin defaults to the current branch.
    Required for Publish; use TaskScope.Source.
.PARAMETER Repository
    Expected OWNER/REPO. Begin resolves the checkout when omitted.
    Required for Publish; use TaskScope.Repository.
.PARAMETER PublishAuthorized
    Caller has recorded task-scoped commit, ordinary push, and dev CI consent.
    Reuse that consent across in-scope iterations; this switch is not a prompt.
.PARAMETER Message
    Commit message for this iteration. Required for Publish.
.PARAMETER Commit
    Exact 40-character SHA to inspect; defaults to local HEAD.
.PARAMETER RunId
    Optional existing run ID, verified against repository, branch, workflow, SHA.
.PARAMETER RepoRoot
    Checkout containing the UI and CI/CD workflow.
.EXAMPLE
    ./Invoke-HostedUiTests.ps1 -Action Inspect -TestFiles e2e/categories-crud.spec.ts
.NOTES
    Requires PowerShell 7.4, Git, gh, and installed npm tooling for local checks.
    Returns structured statuses. Never installs packages, provisions Azure,
    dispatches workflows, force-pushes, or launches local browser tests.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [ValidateSet('Begin', 'Validate', 'Publish', 'Inspect', 'Wait')][string]$Action = 'Inspect',
    [psobject]$TaskScope,
    [string[]]$TestFiles,
    [string[]]$TaskFiles,
    [string]$ExpectedBranch,
    [string]$Repository,
    [switch]$PublishAuthorized,
    [string]$Message,
    [ValidatePattern('^[a-fA-F0-9]{40}$')][string]$Commit,
    [ValidateRange(1, [long]::MaxValue)][long]$RunId,
    [string]$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../../..')).Path
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '../../_shared/RepositoryTools.ps1')

#region Functions
function Assert-UiTestPaths {
    [CmdletBinding()]
    param([string]$Root, [string[]]$Paths, [switch]$Specs)

    if (-not $Paths) { throw 'Supply explicit file paths.' }
    foreach ($Path in $Paths) {
        if ([IO.Path]::IsPathRooted($Path) -or $Path -match '(^|[\\/])\.\.([\\/]|$)|[\x00-\x1f]' -or
            $Path -match '(^|/)(\.git|\.azure|node_modules|playwright-report|test-results)(/|$)' -or
            $Path -match '(^|/)(playwright-results\.json|\.env(?:\.[^/]*)?|setup-dev\.json)$') {
            throw "Unsupported task path: $Path"
        }
        if ($Specs -and ($Path -notmatch '^e2e/.+\.spec\.ts$' -or
            -not (Test-Path -LiteralPath (Join-Path $Root $Path) -PathType Leaf))) {
            throw "Expected an existing UI-relative e2e spec: $Path"
        }
        $FullPath = [IO.Path]::GetFullPath((Join-Path $Root $Path))
        if (Test-Path -LiteralPath $FullPath -PathType Container) { throw "Supply exact files, not directories: $Path" }
        if (-not $FullPath.StartsWith($Root.TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar,
                [StringComparison]::OrdinalIgnoreCase)) { throw "File is outside the checkout: $Path" }
    }
}

function Invoke-UiLocalValidation {
    [CmdletBinding()]
    param([string]$Root, [string[]]$Specs)

    $UiRoot = Join-Path $Root 'Eklee.KeyVault.UI'
    Assert-UiTestPaths $UiRoot $Specs -Specs
    foreach ($Package in @('typescript', 'eslint', '@playwright/test')) {
        if (-not (Test-Path -LiteralPath (Join-Path $UiRoot "node_modules/$Package/package.json"))) {
            throw "Installed tooling is missing: $Package. Use approved package sources; no automatic installation."
        }
    }
    Push-Location $UiRoot
    try {
        $null = Invoke-SkillCommand npm @('run', 'build')
        $null = Invoke-SkillCommand npm @('run', 'lint')
        $Discovery = Invoke-SkillCommand npm (@('exec', '--no', '--', 'playwright', 'test') + $Specs + @('--list', '--reporter=json'))
        $Report = ConvertFrom-Json $Discovery -AsHashtable -Depth 100
        $Found = @(Get-UiReportSpecs $Report.suites)
        if ($Report.errors.Count -gt 0 -or $Found.Count -eq 0) { throw 'No valid Playwright tests were discovered.' }
        return [pscustomobject]@{ Status = 'Validated'; Specs = $Specs; Discovered = $Found.Count }
    }
    finally { Pop-Location }
}

function Get-UiReportSpecs {
    [CmdletBinding()]
    param([object[]]$Suites)

    foreach ($Suite in $Suites) {
        foreach ($Spec in $Suite.specs) { $Spec }
        if ($Suite.suites) { Get-UiReportSpecs $Suite.suites }
    }
}

function Assert-UiPublication {
    [CmdletBinding()]
    param($Context, [string]$Root, [string[]]$Files, [string]$Branch, [string]$Repo)

    if (-not $Branch -or -not $Repo -or $Context.Source -cne $Branch -or $Context.Repository -ine $Repo) {
        throw 'Publication requires the previously verified repository and source branch.'
    }
    if ($Branch -ieq 'main' -or $Branch -ilike 'release/*') { throw 'Publication cannot target main or release branches.' }
    $null = Invoke-SkillCommand git @('check-ref-format', '--branch', $Branch)
    Assert-UiTestPaths $Root $Files
    $Urls = @((Invoke-SkillCommand git @('remote', 'get-url', '--push', '--all', 'origin')) -split "`n" | Where-Object { $_ })
    if ($Urls.Count -ne 1 -or $Urls[0] -notmatch '^(?:https://|ssh://git@|git@)github\.com(?::|/)(?<repo>[^/\s]+/[^/\s]+?)(?:\.git)?/?$' -or
        $Matches.repo -ine $Repo) { throw 'Origin must have exactly one approved GitHub push endpoint.' }
    $Config = Invoke-SkillCommand git @('config', '--null', '--list')
    foreach ($Entry in $Config -split "`0") {
        if ($Entry -match '^remote\.origin\.push\n' -or $Entry -match '^remote\.origin\.mirror\n(?i:true|yes|on|1)$') {
            throw 'Extra push refspecs or mirror configuration are not supported.'
        }
    }
    $Staged = @((Invoke-SkillCommand git @('diff', '--cached', '--name-only', '-z', '--no-renames')) -split "`0" | Where-Object { $_ })
    if (@($Staged | Where-Object { $_ -cnotin $Files }).Count) { throw 'Unrelated staged files block publication; preserve them.' }
    $Unmerged = Invoke-SkillCommand git @('ls-files', '--unmerged')
    if ($Unmerged) { throw 'Unmerged files block publication.' }
    $RemoteRef = Invoke-SkillCommand git @('ls-remote', '--heads', 'origin', "refs/heads/$Branch")
    if ($RemoteRef -notmatch '^(?<sha>[a-f0-9]{40})\s') { throw 'The approved remote branch must already exist.' }
    $null = Invoke-SkillCommand git @('fetch', 'origin', "refs/heads/${Branch}:refs/remotes/origin/$Branch")
    $Ahead = (Invoke-SkillCommand git @('rev-list', '--count', "refs/remotes/origin/$Branch..HEAD")).Trim()
    $Behind = (Invoke-SkillCommand git @('rev-list', '--count', "HEAD..refs/remotes/origin/$Branch")).Trim()
    if ($Ahead -ne '0' -or $Behind -ne '0') { throw 'HEAD must match the published branch tip before an iteration; do not publish unrelated commits or integrate automatically.' }
    return $Urls[0]
}

function Assert-UiTaskScope {
    [CmdletBinding()]
    param($Scope, $Context, [string]$PushUrl, [string[]]$Files)

    if (-not $Scope -or $Scope.Status -ne 'ScopeCaptured' -or
        -not ($Scope.PSObject.Properties.Name -contains 'InitialDirtyFiles') -or
        $Scope.Repository -ine $Context.Repository -or $Scope.Source -cne $Context.Source -or
        $Scope.PushUrl -cne $PushUrl) { throw 'Supply the original Begin task scope; repository, branch, and push endpoint must remain unchanged.' }
    if (-not $Scope.TestUrl -or $Scope.TestUrl -cne (Get-UiCloudTarget $Context.Repository)) {
        throw 'The cloud dev target changed or is missing from Begin scope; stop and resolve target consent.'
    }
    $Comparer = [StringComparer]::Ordinal
    if ($IsWindows) { $Comparer = [StringComparer]::OrdinalIgnoreCase }
    $DirtyPaths = [Collections.Generic.HashSet[string]]::new($Comparer)
    foreach ($Path in $Scope.InitialDirtyFiles) { $null = $DirtyPaths.Add($Path.Replace('\', '/')) }
    if (@($Files | Where-Object { $DirtyPaths.Contains($_.Replace('\', '/')) }).Count) {
        throw 'A task file had pre-existing edits before Begin. Stop publication and ask how to isolate them; do not commit whole-file user changes.'
    }
}

function Get-UiCloudTarget {
    [CmdletBinding()]
    [OutputType([string])]
    param([string]$Repository)

    $Url = (Invoke-SkillCommand gh @('variable', 'get', 'BRANCH_E2E_BASE_URL', '--env', 'dev', '--repo', $Repository)).Trim().TrimEnd('/')
    $Uri = [uri]$Url
    if (-not $Uri.IsAbsoluteUri -or $Uri.Scheme -ne 'https' -or $Uri.IsLoopback -or $Uri.UserInfo) {
        throw 'The configured cloud dev branch HTTPS URL must be absolute, non-loopback, and credential-free.'
    }
    return $Url
}

function Get-UiHostedResult {
    [CmdletBinding()]
    param($Context, [string]$Sha, [long]$Id, [string[]]$Specs, [switch]$Wait)

    if (-not $Specs) { throw 'Supply TestFiles so hosted coverage can be verified.' }
    if (-not $Id) {
        $Runs = @(Invoke-SkillJson @('run', 'list', '--repo', $Context.Repository, '--branch', $Context.Source,
            '--commit', $Sha, '--workflow', 'cicd.yml', '--event', 'push', '--limit', '20', '--json', 'databaseId,headSha,headBranch'))
        if (-not $Runs.Count) { return [pscustomobject]@{ Status = 'RunNotFound'; Commit = $Sha; Reason = 'No push CI/CD run exists for this exact SHA yet. Resume later; do not rerun an older SHA.' } }
        $Id = $Runs[0].databaseId
    }
    $Run = Invoke-SkillJson @('api', '--method', 'GET', "repos/$($Context.Repository)/actions/runs/$Id")
    if ($Run.head_sha -ine $Sha -or $Run.head_branch -cne $Context.Source -or
        $Run.path -ne '.github/workflows/cicd.yml' -or $Run.event -ne 'push') {
        throw 'Run repository, branch, workflow, event, or exact SHA does not match the task.'
    }
    if ($Run.status -ne 'completed' -and $Wait) {
        Write-Host "Waiting for $($Run.html_url)"
        $null = Invoke-SkillCommand gh @('run', 'watch', "$Id", '--repo', $Context.Repository, '--compact')
        $Run = Invoke-SkillJson @('api', '--method', 'GET', "repos/$($Context.Repository)/actions/runs/$Id")
    }
    $Result = [ordered]@{ Status = 'Running'; RunId = $Id; Commit = $Sha; RunUrl = $Run.html_url; Conclusion = $Run.conclusion }
    if ($Run.status -ne 'completed') { return [pscustomobject]$Result }
    $Jobs = Invoke-SkillJson @('run', 'view', "$Id", '--repo', $Context.Repository, '--json', 'jobs')
    $Hosted = @($Jobs.jobs | ForEach-Object { $_.steps } | Where-Object { $_.name -eq 'Run hosted Playwright tests' })
    $Result.Status = 'EvidenceMissing'
    $Result.HostedStep = $Hosted
    if ($Run.conclusion -ne 'success' -or $Hosted.Count -ne 1 -or $Hosted[0].conclusion -ne 'success') {
        $Result.Status = 'Failed'
        $Result.FailedSteps = @($Jobs.jobs | ForEach-Object { $_.steps } | Where-Object { $_.conclusion -eq 'failure' } | ForEach-Object { $_.name })
    }
    $Directory = Join-Path ([IO.Path]::GetTempPath()) "hosted-ui-$Id-$([guid]::NewGuid().ToString('N'))"
    $null = [IO.Directory]::CreateDirectory($Directory)
    $Result.EvidenceDirectory = $Directory
    $Logs = Invoke-SkillCommand gh @('run', 'view', "$Id", '--repo', $Context.Repository, '--log')
    Set-Content -LiteralPath (Join-Path $Directory 'run.log') -Value $Logs -Encoding utf8
    $Result.LogPath = Join-Path $Directory 'run.log'
    $Pages = Invoke-SkillJson @('api', '--method', 'GET', '--paginate', '--slurp', "repos/$($Context.Repository)/actions/runs/$Id/artifacts?per_page=100")
    $Artifacts = @($Pages | ForEach-Object { $_.artifacts } | Where-Object { $_.name -eq "hosted-playwright-results-branch-$Id" -and -not $_.expired })
    if ($Artifacts.Count -ne 1) { $Result.Reason = 'The branch Playwright artifact is missing or expired.'; return [pscustomobject]$Result }
    $null = Invoke-SkillCommand gh @('run', 'download', "$Id", '--repo', $Context.Repository, '--name', $Artifacts[0].name, '--dir', $Directory)
    $Reports = @(Get-ChildItem -LiteralPath $Directory -Filter playwright-results.json -Recurse -File)
    if ($Reports.Count -ne 1) { $Result.Reason = 'No unique Playwright JSON report exists; inspect logs/screenshots but do not claim full coverage.'; return [pscustomobject]$Result }
    $Report = Get-Content -LiteralPath $Reports[0].FullName -Raw | ConvertFrom-Json -AsHashtable -Depth 100
    $Result.ReportPath = $Reports[0].FullName
    $Result.Counts = $Report.stats
    $Result.Specs = @(Get-UiReportSpecs $Report.suites)
    $Tests = @($Result.Specs | ForEach-Object { $_.tests })
    $InvalidTests = @($Tests | Where-Object {
        $_.expectedStatus -ne 'passed' -or $_.status -ne 'expected' -or
        -not $_.results.Count -or $_.results[-1].status -ne 'passed' -or
        -not @($_.annotations | Where-Object { $_.type -eq 'Test URL' }).Count
    })
    $Missing = @($Specs | Where-Object {
        $Expected = $_.Replace('\', '/') -replace '^e2e/', ''
        -not @($Result.Specs | Where-Object {
            $File = $_.file.Replace('\', '/')
            $File -ceq $Expected -or $File.EndsWith("/$Expected", [StringComparison]::Ordinal)
        }).Count
    })
    $CloudUrl = Get-UiCloudTarget $Context.Repository
    $Targets = @($Result.Specs | ForEach-Object { $_.tests } | ForEach-Object { $_.annotations } |
        Where-Object { $_.type -eq 'Test URL' } | ForEach-Object { $_.description })
    if (-not $Targets.Count -or
        @($Targets | Where-Object { $_.TrimEnd('/') -cne $CloudUrl }).Count) {
        throw 'Report target does not match the configured cloud dev branch HTTPS URL.'
    }
    $Result.TestUrl = $CloudUrl
    if ($Result.Status -ne 'Failed' -and $Report.config.forbidOnly -eq $true -and $Report.stats -and $Report.stats.expected -gt 0 -and
        $Report.stats.unexpected -eq 0 -and $Report.stats.skipped -eq 0 -and $Report.stats.flaky -eq 0 -and
        $Report.errors.Count -eq 0 -and $Missing.Count -eq 0 -and $Tests.Count -gt 0 -and
        $InvalidTests.Count -eq 0) { $Result.Status = 'Passed' }
    else {
        $Result.Status = 'Failed'
        $Result.Reason = 'CI/hosted step failed, expected specs are absent, or report contains failed, flaky, skipped, or unexecuted tests.'
    }
    return [pscustomobject]$Result
}
#endregion Functions

#region Main Execution
if ($MyInvocation.InvocationName -ne '.') {
    Push-Location $RepoRoot
    try {
        $Root = (Get-Location).Path
        $TestFiles = @($TestFiles | Where-Object { $_ } | ForEach-Object { $_.Replace('\', '/') })
        $TaskFiles = @($TaskFiles | Where-Object { $_ } | ForEach-Object { $_.Replace('\', '/') } | Sort-Object -Unique)
        if ($Action -eq 'Validate') {
            if (-not $PSCmdlet.ShouldProcess($Root, 'Build, lint, and discover tests without running a browser')) { return [pscustomobject]@{ Status = 'Preview' } }
            return Invoke-UiLocalValidation $Root $TestFiles
        }
        $Context = Get-SkillContext $Repository
        if ($ExpectedBranch -and $Context.Source -cne $ExpectedBranch) { throw 'Source branch changed; stop and resolve the task boundary.' }
        if ($Action -eq 'Begin') {
            if (-not $ExpectedBranch) { $ExpectedBranch = $Context.Source }
            if (-not $Repository) { $Repository = $Context.Repository }
            $PushUrl = Assert-UiPublication $Context $Root $TaskFiles $ExpectedBranch $Repository
            $TestUrl = Get-UiCloudTarget $Repository
            $Dirty = @((Invoke-SkillCommand git @('diff', '--name-only', '-z', '--no-renames', 'HEAD', '--')) -split "`0" | Where-Object { $_ })
            $Untracked = @((Invoke-SkillCommand git @('ls-files', '-z', '--others', '--exclude-standard')) -split "`0" | Where-Object { $_ })
            return [pscustomobject]@{
                Status = 'ScopeCaptured'; Repository = $Context.Repository; Source = $Context.Source
                InitialHead = $Context.Head; PushUrl = $PushUrl
                TestUrl = $TestUrl
                InitialDirtyFiles = @($Dirty + $Untracked | Sort-Object -Unique)
            }
        }
        if ($Action -eq 'Publish') {
            if (-not $PublishAuthorized -or -not $Message) { throw 'Publish requires recorded task-scoped authorization and a commit message.' }
            $PushUrl = Assert-UiPublication $Context $Root $TaskFiles $ExpectedBranch $Repository
            Assert-UiTaskScope $TaskScope $Context $PushUrl $TaskFiles
            if (-not $PSCmdlet.ShouldProcess("$Repository/$ExpectedBranch", 'Validate, commit only task files, and ordinary-push this iteration')) {
                return [pscustomobject]@{ Status = 'Preview'; Context = $Context; TaskFiles = $TaskFiles }
            }
            $Validation = Invoke-UiLocalValidation $Root $TestFiles
            $PushUrl = Assert-UiPublication (Get-SkillContext $Repository) $Root $TaskFiles $ExpectedBranch $Repository
            Assert-UiTaskScope $TaskScope $Context $PushUrl $TaskFiles
            $null = Invoke-SkillCommand git (@('--literal-pathspecs', 'add', '--') + $TaskFiles)
            $Staged = @((Invoke-SkillCommand git @('diff', '--cached', '--name-only', '-z', '--no-renames')) -split "`0" | Where-Object { $_ })
            if (-not $Staged.Count) { return [pscustomobject]@{ Status = 'NoChanges'; Context = $Context; Validation = $Validation } }
            if (@($Staged | Where-Object { $_ -cnotin $TaskFiles }).Count) { throw 'Staged scope changed; do not commit.' }
            $null = Invoke-SkillCommand git @('commit', '-m', $Message)
            $Sha = (Invoke-SkillCommand git @('rev-parse', 'HEAD')).Trim()
            $Committed = @((Invoke-SkillCommand git @('diff-tree', '--no-commit-id', '--name-only', '-r', '-z', 'HEAD')) -split "`0" | Where-Object { $_ })
            $Parent = (Invoke-SkillCommand git @('rev-parse', 'HEAD^')).Trim()
            if ((Invoke-SkillCommand git @('branch', '--show-current')).Trim() -cne $ExpectedBranch -or
                $Parent -cne $Context.Head -or @($Committed | Where-Object { $_ -cnotin $TaskFiles }).Count) {
                throw "Commit $Sha failed the post-hook scope check; keep it local and stop."
            }
            try {
                $null = Invoke-SkillCommand git @('-c', 'push.followTags=false', '-c', 'push.recurseSubmodules=no',
                    'push', '--porcelain', $PushUrl, "${Sha}:refs/heads/$ExpectedBranch")
            }
            catch { throw "Commit $Sha remains local. Ordinary push failed; stop without force-push or integration. $($_.Exception.Message)" }
            $Remote = Invoke-SkillCommand git @('ls-remote', '--heads', $PushUrl, "refs/heads/$ExpectedBranch")
            if ($Remote -notmatch "^$Sha\s") { throw "Could not verify publication of commit $Sha." }
            return [pscustomobject]@{ Status = 'Published'; Context = $Context; Commit = $Sha; TaskFiles = $Staged; Validation = $Validation }
        }
        if (-not $Commit) { $Commit = $Context.Head }
        return Get-UiHostedResult $Context $Commit $RunId $TestFiles -Wait:($Action -eq 'Wait')
    }
    finally { Pop-Location }
}
#endregion Main Execution