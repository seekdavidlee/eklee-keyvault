#!/usr/bin/env pwsh
#Requires -Version 7.4

<#
.SYNOPSIS
    Runs dependency-free regression checks for repository skills and scripts.
.DESCRIPTION
    Uses scope-contained fake CLIs and temporary fixture files. No GitHub writes,
    actual branch switches, package installs, or live test services are invoked.
    Checks linked skill and agent contracts without executing an agent workflow.
.PARAMETER RepoRoot
    Repository containing the skill scripts.
.EXAMPLE
    ./.github/skills/tests/Invoke-SkillScriptTests.ps1
#>
[CmdletBinding()]
param([string]$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path)

$ErrorActionPreference = 'Stop'

function Assert-Equal {
    param($Actual, $Expected, [string]$Label)
    if ($Actual -cne $Expected) { throw "${Label}: expected '$Expected', received '$Actual'." }
    $script:Assertions++
}

function Assert-Throws {
    param([scriptblock]$Action, [string]$Pattern)
    try { $null = & $Action }
    catch {
        if ($_.Exception.Message -like $Pattern) { $script:Assertions++; return }
        throw
    }
    throw "Expected an error matching '$Pattern'."
}

function ConvertTo-TestPages {
    param([object[]]$Items)
    return ConvertTo-Json -InputObject (, $Items) -Depth 30 -Compress
}

function New-TestPullRequest {
    return @{
        number = 61; state = 'open'; html_url = 'https://github.com/owner/repo/pull/61'
        title = $SkillTestState.PrTitle; body = $SkillTestState.PrBody
        head = @{ ref = 'feature/60'; sha = $SkillTestState.Head; repo = @{ full_name = 'owner/repo' } }
        base = @{ ref = 'release/1.2.0'; repo = @{ full_name = 'owner/repo' } }
    }
}

function git {
    $global:LASTEXITCODE = 0
    switch ($args[0]) {
        'rev-parse' {
            if ($args[1] -eq '--show-toplevel') { return $Fixture }
            if ($args[1] -in @('refs/remotes/origin/release/1.2.0', 'refs/remotes/origin/main')) { return $SkillTestState.BaseSha }
            if ($args[1] -eq "refs/remotes/origin/$($SkillTestState.Branch)") { return $SkillTestState.Published }
            return $SkillTestState.Head
        }
        'branch' { return $SkillTestState.Branch }
        'status' { return $SkillTestState.Worktree }
        'fetch' {
            if ($SkillTestState.FetchFailure) { $global:LASTEXITCODE = 1; return 'fetch failed' }
        }
        'for-each-ref' {
            if ($args -contains '--format=%(upstream)') { return '' }
            if ($args -contains '--format=%(refname)') { return ($SkillTestState.ExistingBranches -join "`n") }
            return ($SkillTestState.Releases -join "`n")
        }
        'check-ref-format' { }
        'merge-base' {
            if (-not $SkillTestState.IsAncestor) { $global:LASTEXITCODE = 1 }
        }
        'show-ref' {
            if ($args[-1] -notin @('refs/remotes/origin/main', 'refs/remotes/origin/release/1.2.0')) {
                $global:LASTEXITCODE = 1; return 'missing ref'
            }
            return 'valid ref'
        }
        '-c' {
            if ($args -contains 'ls-files') { return ($SkillTestState.Untracked -join "`0") }
            if (($args -join ' ') -like '*...HEAD*') { return ($SkillTestState.Committed -join "`0") }
            return ($SkillTestState.Working -join "`0")
        }
        'ls-files' {
            return (@($SkillTestState.Committed + $SkillTestState.Working | Sort-Object -Unique | ForEach-Object {
                $Mode = '100644'
                if ($SkillTestState.Modes.ContainsKey($_)) { $Mode = $SkillTestState.Modes[$_] }
                "$Mode $($SkillTestState.Head) 0`t$_"
            }) -join "`0")
        }
        'diff' {
            if ($args -contains '--raw') { return '' }
            return 'complete diff fixture'
        }
        'switch' {
            $SkillTestState.GitWrites++
            $SkillTestState.SwitchArguments = @($args)
            $SkillTestState.Branch = $args[2]
            if ($args.Count -eq 5) { $SkillTestState.Head = $args[-1] }
        }
        default { throw "Unexpected git invocation: $args" }
    }
}

function gh {
    $global:LASTEXITCODE = 0
    switch ($args[0]) {
        'auth' {
            if ($SkillTestState.AuthFailure) { $global:LASTEXITCODE = 1; return 'unauthorized' }
        }
        'repo' {
            if ($args -contains '--jq') { return 'owner/repo' }
            return '{"nameWithOwner":"owner/repo","url":"https://github.com/owner/repo"}'
        }
        'issue' {
            if ($args[1] -eq 'view') {
                return (@{ number = 60; title = $SkillTestState.IssueTitle; body = 'Criteria'; comments = @(); url = $SkillTestState.IssueUrl } | ConvertTo-Json)
            }
            $SkillTestState.GhWrites++
            $BodyIndex = [array]::IndexOf($args, '--body-file') + 1
            $SkillTestState.IssueBodyPath = $args[$BodyIndex]
            $SkillTestState.IssueBody = Get-Content -LiteralPath $SkillTestState.IssueBodyPath -Raw
            return 'https://github.com/owner/repo/issues/61'
        }
        'pr' {
            $SkillTestState.GhWrites++
            if ($args[1] -eq 'edit') {
                Assert-Equal $args[-1] '@copilot' 'reviewer selector'
                $SkillTestState.Pending = $SkillTestState.AcceptRequest
                return ''
            }
            return 'https://github.com/owner/repo/pull/61'
        }
        'api' {
            $Endpoint = $args[-1]
            if ($SkillTestState.ApiFailure) { $global:LASTEXITCODE = 1; return 'API denied' }
            if ($Endpoint -match '/(?:pulls|reviews|alerts)\?') {
                Assert-Equal ($args -contains '--paginate' -and $args -contains '--slurp') $true 'paginated collection'
            }
            if ($Endpoint -like '*requested_reviewers') {
                $Users = @()
                if ($SkillTestState.Pending) { $Users = @(@{ login = 'copilot-pull-request-reviewer[bot]' }) }
                return (@{ users = $Users } | ConvertTo-Json -Depth 10 -Compress)
            }
            if ($Endpoint -match '/reviews\?') { return ConvertTo-TestPages $SkillTestState.Reviews }
            if ($Endpoint -match '/pulls\?') { return ConvertTo-TestPages $SkillTestState.SourcePrs }
            if ($Endpoint -match '/pulls/\d+$') { return (New-TestPullRequest | ConvertTo-Json -Depth 10 -Compress) }
            if ($Endpoint -like '*dependabot/alerts*') { return ConvertTo-TestPages $SkillTestState.Alerts }
            if ($Endpoint -like '*labels*') { return '[[{"name":"bug"}]]' }
            if ($Endpoint -like '*milestones*') { return '[[{"title":"1.2.0"}]]' }
            throw "Unexpected endpoint: $Endpoint"
        }
        default { throw "Unexpected gh invocation: $args" }
    }
}

function dotnet {
    $global:LASTEXITCODE = 0
    if ($SkillTestState.NativeFailure) { $global:LASTEXITCODE = 1; return 'dotnet failed' }
    if ($args[0] -eq 'test') {
        $Directory = $args[[array]::IndexOf($args, '--results-directory') + 1]
        $null = [IO.Directory]::CreateDirectory($Directory)
        $Report = '<TestRun><ResultSummary><Counters total="{0}" passed="{0}" failed="0" notExecuted="{1}" /></ResultSummary></TestRun>' -f $SkillTestState.Passed, $SkillTestState.Skipped
        Set-Content -LiteralPath (Join-Path $Directory 'unit-tests.trx') -Value $Report
        return 'mocked dotnet test completed'
    }
    if ($args[0] -eq 'list') { return '{"projects":[]}' }
    if ($args[0] -eq 'build') { return 'mocked backend build' }
    throw "Unexpected dotnet invocation: $args"
}

function npm {
    $global:LASTEXITCODE = 0
    if ($SkillTestState.NativeFailure) { $global:LASTEXITCODE = 1; return 'npm failed' }
    if ($args[0] -eq 'ls') { return '{"dependencies":{}}' }
    if ($args[0] -eq 'config') { return ($SkillTestState.NpmConfig | ConvertTo-Json -Compress) }
    if ($args[0] -eq 'install') {
        $SkillTestState.NpmInstalls++
        $Manifest = Get-Content -LiteralPath 'package.json' -Raw | ConvertFrom-Json -AsHashtable
        $Packages = @('vitest', 'jsdom', '@testing-library/react', '@testing-library/dom', '@testing-library/jest-dom', '@testing-library/user-event')
        $LockPackages = @{ '' = @{} }
        foreach ($Name in $Packages) {
            if (-not $Manifest.devDependencies[$Name]) { $Manifest.devDependencies[$Name] = '4.1.6' }
            $LockPackages["node_modules/$Name"] = @{ resolved = "$($SkillTestState.LockRegistry)$Name/-/package.tgz"; integrity = 'sha512-fixture' }
        }
        $Manifest | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath 'package.json'
        @{ lockfileVersion = 3; packages = $LockPackages } | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath 'package-lock.json'
        return 'mocked package resolution'
    }
    if ($args[0] -eq 'ci') {
        $SkillTestState.NpmCi++
        foreach ($Name in @('vitest', 'jsdom', '@testing-library/react', '@testing-library/dom', '@testing-library/jest-dom', '@testing-library/user-event')) {
            $Directory = Join-Path (Get-Location).Path "node_modules/$Name"
            $null = [IO.Directory]::CreateDirectory($Directory)
            Set-Content -LiteralPath (Join-Path $Directory 'package.json') -Value '{}'
        }
        return 'mocked package installation'
    }
    $ReportArgument = $args | Where-Object { $_ -like '--outputFile=*' } | Select-Object -First 1
    if ($ReportArgument) {
        @{
            success = $true; numTotalTests = $SkillTestState.Passed
            numPassedTests = $SkillTestState.Passed; numFailedTests = 0
            numPendingTests = $SkillTestState.Skipped; numTodoTests = 0
        } | ConvertTo-Json | Set-Content -LiteralPath $ReportArgument.Substring('--outputFile='.Length)
    }
    if ($args[0] -ne 'run') { throw "Unexpected npm invocation: $args" }
    return 'mocked npm check completed'
}

if ($MyInvocation.InvocationName -ne '.') {
    $script:Assertions = 0
    $PreviousExitCode = $global:LASTEXITCODE
    $Fixture = Join-Path ([IO.Path]::GetTempPath()) "skill-script-tests-$([guid]::NewGuid().ToString('N'))"
    $Scripts = Join-Path $RepoRoot '.github/skills'
    $IssueScript = Join-Path $Scripts 'create-github-issue/scripts/New-GitHubIssue.ps1'
    $ContextScript = Join-Path $Scripts 'implement-issue/scripts/Get-IssueContext.ps1'
    $BranchScript = Join-Path $Scripts 'create-issue-branch/scripts/New-IssueBranch.ps1'
    $PrScript = Join-Path $Scripts 'create-pull-request/scripts/Invoke-PullRequest.ps1'
    $SnapshotScript = Join-Path $Scripts 'functional-implementation-code-review/scripts/Get-ReviewSnapshot.ps1'
    $ReviewScript = Join-Path $Scripts 'request-github-code-review/scripts/Request-CopilotReview.ps1'
    $SecurityScript = Join-Path $Scripts 'upgrade-security/scripts/Invoke-SecurityUpgrade.ps1'
    $BackendScript = Join-Path $Scripts 'unit-test-backend/scripts/Invoke-BackendUnitTests.ps1'
    $FrontendScript = Join-Path $Scripts 'unit-test-frontend/scripts/Invoke-FrontendUnitTests.ps1'
    $SetupScript = Join-Path $Scripts 'unit-test-frontend/scripts/Initialize-FrontendUnitTests.ps1'
    $SkillTestState = @{
        Branch = 'feature/60'; Head = ('a' * 40); Published = ('a' * 40); BaseSha = ('b' * 40)
        Releases = @('release/1.2.0'); Worktree = ''; Working = @(); Committed = @('LICENSE'); Untracked = @()
        GhWrites = 0; GitWrites = 0; Pending = $false; AcceptRequest = $true; Reviews = @(); SourcePrs = @()
        AuthFailure = $false; ApiFailure = $false; FetchFailure = $false; NativeFailure = $false
        IssueUrl = 'https://github.com/owner/repo/issues/60'; Passed = 2; Skipped = 0; Alerts = @()
        Modes = @{}; PrTitle = 'Example'; PrBody = 'fixture'; ExistingBranches = @(); SwitchArguments = @()
        IsAncestor = $true; IssueTitle = 'Example'
        NpmConfig = @{ registry = 'https://approved.example/npm/' }
        LockRegistry = 'https://approved.example/npm/'; NpmInstalls = 0; NpmCi = 0
    }
    try {
        $null = [IO.Directory]::CreateDirectory((Join-Path $Fixture 'Eklee.KeyVault.UI/src'))
        $null = [IO.Directory]::CreateDirectory((Join-Path $Fixture 'Eklee.KeyVault.Api.Tests'))
        Set-Content -LiteralPath (Join-Path $Fixture 'LICENSE') -Value 'fixture' -NoNewline
        Set-Content -LiteralPath (Join-Path $Fixture 'proposed.txt') -Value 'new file' -NoNewline
        Copy-Item -LiteralPath (Join-Path $RepoRoot 'Eklee.KeyVault.UI/package.json') -Destination (Join-Path $Fixture 'Eklee.KeyVault.UI/package.json')
        Copy-Item -LiteralPath (Join-Path $RepoRoot 'Eklee.KeyVault.Api.Tests/Eklee.KeyVault.Api.Tests.csproj') -Destination (Join-Path $Fixture 'Eklee.KeyVault.Api.Tests/Eklee.KeyVault.Api.Tests.csproj')

        $TypeParameter = (Get-Command $BranchScript).Parameters['Type']
        Assert-Equal (@($TypeParameter.Attributes | Where-Object { $_ -is [System.Management.Automation.ParameterAttribute] -and $_.Mandatory }).Count) 0 'branch type does not prompt during binding'
        Assert-Throws { & $BranchScript -Issue 60 -RepoRoot $Fixture } '*Type is required*'
        Assert-Equal $SkillTestState.GitWrites 0 'missing type does not switch branches'
        Assert-Equal $SkillTestState.GhWrites 0 'missing type does not publish'

        foreach ($Type in @('feature', 'fix', 'doc', 'refactor')) {
            $Resolved = & $BranchScript -Issue 60 -Type $Type -RepoRoot $Fixture
            Assert-Equal $Resolved.Status 'Resolved' "$Type branch resolution"
            Assert-Equal $Resolved.Source "$Type/60-example" "$Type branch naming"
            Assert-Equal $Resolved.Base 'release/1.2.0' "$Type release base"
        }
        Assert-Equal $SkillTestState.GitWrites 0 'branch lookup does not switch'
        foreach ($Type in @('feature', 'fix', 'doc', 'refactor')) {
            $Prefix = "$Type/60-"
            $BoundarySlug = 'a' * (49 - $Prefix.Length)
            $BoundaryBranch = & $BranchScript -Issue 60 -Type $Type -Slug $BoundarySlug -RepoRoot $Fixture
            Assert-Equal $BoundaryBranch.Source.Length 49 "$Type accepts 49-character branch"
            Assert-Throws { & $BranchScript -Issue 60 -Type $Type -Slug ($BoundarySlug + 'a') -RepoRoot $Fixture } '*fewer than 50 characters*'
            Assert-Throws {
                & $BranchScript -Issue 60 -Type $Type -Slug ($BoundarySlug + 'a') -Action Create `
                    -Base release/1.2.0 -ExpectedBaseSha $SkillTestState.BaseSha -RepoRoot $Fixture -Confirm:$false
            } '*fewer than 50 characters*'
        }
        $SkillTestState.IssueTitle = 'Add category management and category first secret navigation'
        Assert-Throws { & $BranchScript -Issue 60 -Type feature -RepoRoot $Fixture } '*shorter meaningful -Slug*'
        Assert-Equal (& $BranchScript -Issue 60 -Type feature -Slug category-management -RepoRoot $Fixture).Source 'feature/60-category-management' 'meaningful explicit slug overrides long title'
        $SkillTestState.IssueTitle = 'Example'
        Assert-Equal $SkillTestState.GitWrites 0 'overlength names never switch branches'
        $SkillTestState.Branch = 'main'
        $BranchArguments = @{
            Issue = 60; Type = 'fix'; Slug = 'release-routing'; Action = 'Create'; RepoRoot = $Fixture
            Base = 'release/1.2.0'; ExpectedBaseSha = $SkillTestState.BaseSha
        }
        Assert-Equal (& $BranchScript @BranchArguments -WhatIf).Status 'Preview' 'issue branch WhatIf'
        Assert-Equal $SkillTestState.GitWrites 0 'branch preview does not switch'
        $CreatedBranch = & $BranchScript @BranchArguments -Confirm:$false
        Assert-Equal $CreatedBranch.Status 'Created' 'approved issue branch'
        Assert-Equal $CreatedBranch.Context.Head $SkillTestState.BaseSha 'release tip not previous HEAD'
        Assert-Equal ($SkillTestState.SwitchArguments -join ' ') "switch --create fix/60-release-routing --no-track $($SkillTestState.BaseSha)" 'explicit untracked release start'
        $ResumeArguments = @{ Issue = 60; Type = 'fix'; Action = 'Resume'; CreationEvidence = $CreatedBranch; RepoRoot = $Fixture }
        Assert-Equal (& $BranchScript @ResumeArguments).Status 'Resumed' 'recorded branch resume'
        $OriginalSlug = $CreatedBranch.Slug
        $CreatedBranch.Slug = 'a' * 43
        Assert-Throws { & $BranchScript @ResumeArguments } '*fewer than 50 characters*'
        $CreatedBranch.Slug = $OriginalSlug
        $SkillTestState.Head = ('d' * 40)
        $SkillTestState.BaseSha = ('e' * 40)
        Assert-Equal (& $BranchScript @ResumeArguments).BaseSha $CreatedBranch.BaseSha 'resume preserves original starting SHA after release advances'
        $SkillTestState.BaseSha = ('b' * 40)
        $SkillTestState.Head = $CreatedBranch.BaseSha
        Assert-Throws { & $BranchScript -Issue 60 -Type fix -Action Resume -RepoRoot $Fixture } '*complete recorded*'
        foreach ($Property in @('Status', 'Base', 'BaseSha', 'Slug', 'Source')) {
            $Original = $CreatedBranch.$Property
            $CreatedBranch.$Property = 'invalid'
            Assert-Throws { & $BranchScript @ResumeArguments } '*evidence*'
            $CreatedBranch.$Property = $Original
        }
        $CreatedBranch.Context.Repository = 'other/repo'
        Assert-Throws { & $BranchScript @ResumeArguments } '*does not match*'
        $CreatedBranch.Context.Repository = 'owner/repo'
        $CreatedBranch.Issue.number = 99
        Assert-Throws { & $BranchScript @ResumeArguments } '*does not match*'
        $CreatedBranch.Issue.number = 60
        Assert-Throws { & $BranchScript @ResumeArguments -Base release/1.3.0 } '*does not match*'
        Assert-Throws { & $BranchScript @ResumeArguments -Type feature } '*does not match*'
        $SkillTestState.Branch = 'fix/60-other'
        Assert-Throws { & $BranchScript @ResumeArguments } '*does not match*'
        $SkillTestState.Branch = $CreatedBranch.Source
        $SkillTestState.IsAncestor = $false
        Assert-Throws { & $BranchScript @ResumeArguments } '*not a verified ancestor*'
        $SkillTestState.IsAncestor = $true
        Assert-Equal $SkillTestState.GitWrites 1 'resume never switches branches'
        Assert-Throws { & $BranchScript -Issue 60 -Type fix -Action Create -RepoRoot $Fixture -Confirm:$false } '*requires the verified*'
        $BranchArguments.ExpectedBaseSha = ('c' * 40)
        Assert-Throws { & $BranchScript @BranchArguments -Confirm:$false } '*release tip changed*'
        $BranchArguments.ExpectedBaseSha = $SkillTestState.BaseSha
        $SkillTestState.Worktree = '?? unrelated.txt'
        Assert-Throws { & $BranchScript @BranchArguments -Confirm:$false } '*clean worktree*'
        $SkillTestState.Worktree = ''
        foreach ($Ref in @('refs/heads/fix/60-release-routing', 'refs/remotes/origin/fix/60-release-routing')) {
            $SkillTestState.ExistingBranches = @($Ref)
            Assert-Throws { & $BranchScript @BranchArguments -Confirm:$false } '*already exists*'
        }
        $SkillTestState.ExistingBranches = @()
        Assert-Equal $SkillTestState.GitWrites 1 'failed branch guards do not switch'
        Assert-Throws { & $BranchScript -Issue 60 -Type fix -Base main -RepoRoot $Fixture } '*must start from a release/*'
        $SkillTestState.Releases = @()
        Assert-Equal (& $BranchScript -Issue 60 -Type fix -RepoRoot $Fixture).Status 'BaseSelectionRequired' 'branch lookup without a release'
        $SkillTestState.Releases = @('release/1.2.0', 'release/1.3.0')
        Assert-Equal (& $BranchScript -Issue 60 -Type fix -RepoRoot $Fixture).Status 'BaseSelectionRequired' 'ambiguous branch release'
        Assert-Equal (& $BranchScript -Issue 60 -Type doc -Base release/1.2.0 -RepoRoot $Fixture).Base 'release/1.2.0' 'explicit branch release selection'
        $SkillTestState.Releases = @('release/1.2.0')
        $SkillTestState.FetchFailure = $true
        Assert-Throws { & $BranchScript @BranchArguments -Confirm:$false } '*fetch failed*'
        $SkillTestState.FetchFailure = $false
        $SkillTestState.GitWrites = 0
        $SkillTestState.Branch = 'feature/60'
        $SkillTestState.Head = ('a' * 40)

        Assert-Equal (& $ContextScript -Issue 60 -RepoRoot $Fixture).Status 'Ready' 'feature preflight'
        $SkillTestState.Branch = 'main'
        Assert-Equal (& $ContextScript -Issue 60 -RepoRoot $Fixture).Status 'FeatureBranchRequired' 'protected branch'
        Assert-Throws { & $ContextScript -Issue 60 -FeatureBranch feature/60 -RepoRoot $Fixture } '*parameter name*FeatureBranch*'
        Assert-Equal $SkillTestState.GitWrites 0 'issue preflight cannot create a branch'
        $SkillTestState.Branch = ''
        Assert-Throws { & $ContextScript -Issue 60 -RepoRoot $Fixture } '*Detached HEAD*'
        $SkillTestState.Branch = 'feature/60'
        $SkillTestState.IssueUrl = 'https://github.com/other/repo/issues/60'
        Assert-Throws { & $ContextScript -Issue 60 -RepoRoot $Fixture } '*does not belong*'
        $SkillTestState.IssueUrl = 'https://github.com/owner/repo/issues/60'
        $SkillTestState.AuthFailure = $true
        Assert-Throws { & $PrScript -RepoRoot $Fixture } '*unauthorized*'
        $SkillTestState.AuthFailure = $false

        Assert-Equal (& $PrScript -RepoRoot $Fixture).Routing.Base 'release/1.2.0' 'sole active release'
        $SkillTestState.Releases = @()
        Assert-Equal (& $PrScript -RepoRoot $Fixture).Status 'BaseSelectionRequired' 'no releases'
        $SkillTestState.Releases = @('release/1.2.0', 'release/1.3.0')
        Assert-Equal (& $PrScript -RepoRoot $Fixture).Status 'BaseSelectionRequired' 'ambiguous releases'
        $SkillTestState.Branch = 'release/1.2.0'
        Assert-Equal (& $PrScript -RepoRoot $Fixture).Routing.Base 'main' 'release to main'
        Assert-Throws { & $PrScript -Base release/1.2.0 -RepoRoot $Fixture } '*must be different*'
        $SkillTestState.Branch = 'feature/60'
        $SkillTestState.Releases = @('release/1.2.0')
        Assert-Throws { & $PrScript -Base missing -RepoRoot $Fixture } '*missing ref*'
        $SkillTestState.FetchFailure = $true
        Assert-Throws { & $PrScript -RepoRoot $Fixture } '*fetch failed*'
        $SkillTestState.FetchFailure = $false

        $SnapshotOutput = Join-Path ([IO.Path]::GetTempPath()) "skill-snapshot-$([guid]::NewGuid().ToString('N')).json"
        try {
            $null = & $SnapshotScript -RepoRoot $Fixture -OutputFile $SnapshotOutput -WhatIf
            Assert-Equal (Test-Path -LiteralPath $SnapshotOutput) $false 'snapshot WhatIf write guard'
            Assert-Throws { & $SnapshotScript -RepoRoot $Fixture -OutputFile (Join-Path $Fixture 'LICENSE') } '*new JSON file outside*'
            $null = & $SnapshotScript -RepoRoot $Fixture -OutputFile $SnapshotOutput
            Assert-Equal (Test-Path -LiteralPath $SnapshotOutput) $true 'snapshot output created'
            Assert-Throws { & $SnapshotScript -RepoRoot $Fixture -OutputFile $SnapshotOutput } '*new JSON file outside*'
        }
        finally { Remove-Item -LiteralPath $SnapshotOutput -Force -ErrorAction SilentlyContinue }
        $SkillTestState.Untracked = @('proposed.txt')
        $Snapshot = (& $SnapshotScript -RepoRoot $Fixture).Snapshot
        Assert-Equal $Snapshot.Files.Count 2 'untracked review inventory'
        $Selected = (& $SnapshotScript -TaskFiles LICENSE -RepoRoot $Fixture).Snapshot
        Assert-Equal $Selected.ExcludedWorkingFiles[0] 'proposed.txt' 'explicit unrelated exclusion'
        $SnapshotArguments = @{ Base = 'release/1.2.0'; ExpectedFingerprint = $Selected.Fingerprint; TaskFiles = @('LICENSE'); RepoRoot = $Fixture }
        Assert-Equal (& $SnapshotScript @SnapshotArguments).Status 'Captured' 'assigned snapshot validates with identical scope'
        Assert-Throws { & $SnapshotScript -ExpectedFingerprint $Selected.Fingerprint -RepoRoot $Fixture } '*requires the assigned snapshot Base*'
        Assert-Throws { & $SnapshotScript -Base release/1.2.0 -ExpectedFingerprint $Selected.Fingerprint -RepoRoot $Fixture } '*stale or mismatched*'
        $SkillTestState.Modes.LICENSE = '100755'
        Assert-Throws { & $SnapshotScript @SnapshotArguments } '*stale or mismatched*'
        $SkillTestState.Modes.Clear()
        $SkillTestState.BaseSha = ('d' * 40)
        Assert-Throws { & $SnapshotScript @SnapshotArguments } '*stale or mismatched*'
        $SkillTestState.BaseSha = ('b' * 40)
        $SkillTestState.Branch = 'fix/60'
        Assert-Throws { & $SnapshotScript @SnapshotArguments } '*stale or mismatched*'
        $SkillTestState.Branch = 'feature/60'
        Set-Content -LiteralPath (Join-Path $Fixture 'LICENSE') -Value 'changed' -NoNewline
        Assert-Throws { & $SnapshotScript @SnapshotArguments } '*stale or mismatched*'
        Set-Content -LiteralPath (Join-Path $Fixture 'LICENSE') -Value 'fixture' -NoNewline
        $SkillTestState.Committed = @('LICENSE', 'proposed.txt')
        $SkillTestState.Untracked = @()
        $SkillTestState.Head = ('c' * 40)
        $AfterCommit = (& $SnapshotScript -RepoRoot $Fixture).Snapshot
        Assert-Equal $AfterCommit.Fingerprint $Snapshot.Fingerprint 'identical commit preserves review'
        $SkillTestState.Modes.LICENSE = '100755'
        Assert-Equal ((& $SnapshotScript -RepoRoot $Fixture).Snapshot.Fingerprint -ne $Snapshot.Fingerprint) $true 'mode-only change invalidates review'
        $SkillTestState.Modes.Clear()
        Set-Content -LiteralPath (Join-Path $Fixture 'LICENSE') -Value 'changed' -NoNewline
        Assert-Equal ((& $SnapshotScript -RepoRoot $Fixture).Snapshot.Fingerprint -ne $Snapshot.Fingerprint) $true 'changed content invalidates review'
        Set-Content -LiteralPath (Join-Path $Fixture 'LICENSE') -Value 'fixture' -NoNewline
        $SkillTestState.Head = ('a' * 40)
        $PrArguments = @{ Action = 'Create'; Base = 'release/1.2.0'; Title = 'Example'; BodyFile = (Join-Path $Fixture 'LICENSE'); ReviewedFingerprint = $Snapshot.Fingerprint; RepoRoot = $Fixture }
        Assert-Equal (& $PrScript @PrArguments -WhatIf).Status 'Preview' 'PR creation preview'
        Assert-Equal $SkillTestState.GhWrites 0 'PR preview has no write'
        $PrArguments.ReviewedFingerprint = 'stale'
        Assert-Throws { & $PrScript @PrArguments -WhatIf } '*changed after local review*'
        $PrArguments.ReviewedFingerprint = $Snapshot.Fingerprint
        $SkillTestState.Published = 'old'
        Assert-Throws { & $PrScript @PrArguments -WhatIf } '*not the published source tip*'
        $SkillTestState.Published = $SkillTestState.Head
        $Existing = New-TestPullRequest
        $SkillTestState.SourcePrs = @($Existing)
        Assert-Equal (& $PrScript @PrArguments -WhatIf).Status 'Reused' 'exact PR reuse'
        $SkillTestState.PrBody = 'stale description'
        Assert-Throws { & $PrScript @PrArguments -WhatIf } '*title/body differ*'
        $SkillTestState.PrBody = 'fixture'
        $SkillTestState.PrTitle = 'stale title'
        Assert-Throws { & $PrScript @PrArguments -WhatIf } '*title/body differ*'
        $SkillTestState.PrTitle = 'Example'
        $Existing.base.ref = 'main'
        Assert-Equal (& $PrScript @PrArguments -WhatIf).Status 'PullRequestSelectionRequired' 'different-base PR'
        $SkillTestState.SourcePrs = @((New-TestPullRequest), (New-TestPullRequest))
        Assert-Equal (& $PrScript @PrArguments -WhatIf).Status 'PullRequestSelectionRequired' 'multiple PRs'
        $SkillTestState.SourcePrs = @()
        Assert-Equal (& $PrScript @PrArguments -Confirm:$false).Status 'Created' 'mocked PR creation'

        $ReviewArguments = @{ Repository = 'owner/repo'; Number = 61; Source = 'feature/60'; Base = 'release/1.2.0'; Head = $SkillTestState.Head; RepoRoot = $Fixture }
        Assert-Equal (& $ReviewScript @ReviewArguments -WhatIf).Status 'Preview' 'review preview'
        $SkillTestState.Pending = $true
        Assert-Equal (& $ReviewScript @ReviewArguments -WhatIf).Status 'AlreadyPending' 'pending review idempotency'
        $SkillTestState.Pending = $false
        $SkillTestState.Reviews = @(@{ id = 1; user = @{ login = 'copilot-pull-request-reviewer[bot]' }; commit_id = $SkillTestState.Head; state = 'COMMENTED' })
        Assert-Equal (& $ReviewScript @ReviewArguments -WhatIf).Status 'ReReviewApprovalRequired' 'completed review gate'
        Assert-Equal (& $ReviewScript @ReviewArguments -ReReview -WhatIf).Status 'Preview' 'approved re-review preview'
        $SkillTestState.Reviews = @()
        Assert-Equal (& $ReviewScript @ReviewArguments -Confirm:$false).Status 'Requested' 'observed request'
        $SkillTestState.Pending = $false
        $SkillTestState.AcceptRequest = $false
        Assert-Equal (& $ReviewScript @ReviewArguments -Confirm:$false).Status 'Blocked' 'unobserved request is not success'
        $ReviewArguments.Head = 'stale'
        Assert-Throws { & $ReviewScript @ReviewArguments -WhatIf } '*differs from the reviewed handoff*'

        $Alert = @{
            number = 1; security_advisory = @{ severity = 'high'; ghsa_id = 'GHSA-example' }
            dependency = @{ package = @{ name = 'axios'; ecosystem = 'npm' }; manifest_path = 'Eklee.KeyVault.UI/package.json' }
            security_vulnerability = @{ vulnerable_version_range = '<1.20.0'; first_patched_version = @{ identifier = '1.20.0' } }
        }
        $SkillTestState.Alerts = @($Alert)
        Assert-Equal (& $SecurityScript -RepoRoot $Fixture).Alerts[0].Package 'axios' 'normalized alert'
        $SkillTestState.Alerts = @()
        Assert-Equal (& $SecurityScript -RepoRoot $Fixture).Alerts.Count 0 'successful empty alert list'
        $SkillTestState.ApiFailure = $true
        Assert-Throws { & $SecurityScript -RepoRoot $Fixture } '*API denied*'
        $SkillTestState.ApiFailure = $false
        $Update = @{ Action = 'Update'; Manifest = 'Eklee.KeyVault.UI/package.json'; Package = 'axios'; Version = '1.20.0'; RepoRoot = $Fixture }
        Assert-Equal ((& $SecurityScript @Update -WhatIf).Arguments -contains '--save-prod') $true 'production dependency type'
        $Update.Package = 'vite'
        Assert-Equal ((& $SecurityScript @Update -WhatIf).Arguments -contains '--save-dev') $true 'development dependency type'
        $Update.Package = 'undeclared'
        Assert-Throws { & $SecurityScript @Update -WhatIf } '*exactly one supported*'
        $Update.Manifest = '../outside/package.json'
        Assert-Throws { & $SecurityScript @Update -WhatIf } '*inside the repository*'
        Assert-Equal (& $SecurityScript -Action PrepareBranch -Branch security/example -RepoRoot $Fixture -WhatIf).Status 'Preview' 'security branch preview'
        Assert-Equal (& $SecurityScript -Action PrepareBranch -Branch security/example -RepoRoot $Fixture -Confirm:$false).Status 'BranchPrepared' 'security branch and upstream'
        Assert-Equal (& $SecurityScript -Action Verify -RepoRoot $Fixture -Confirm:$false).Status 'Verified' 'build and dependency inventory'
        $SkillTestState.Branch = 'feature/60'

        Assert-Equal (& $BackendScript -Filter 'FullyQualifiedName~Example' -RepoRoot $Fixture).Status 'Passed' 'backend report validation'
        $SkillTestState.Passed = 0
        Assert-Throws { & $BackendScript -Filter Example -RepoRoot $Fixture } '*missing successful execution*'
        $SkillTestState.Passed = 2
        $SkillTestState.Skipped = 1
        Assert-Throws { & $BackendScript -Filter Example -RepoRoot $Fixture } '*failed/skipped tests*'
        $SkillTestState.Skipped = 0
        $SkillTestState.NativeFailure = $true
        Assert-Throws { & $BackendScript -Filter Example -RepoRoot $Fixture } '*dotnet failed*'
        $SkillTestState.NativeFailure = $false

        Assert-Equal (& $FrontendScript -TestFiles src/example.test.ts -RepoRoot $Fixture).Status 'Blocked' 'missing frontend runner'
        $PackageFile = Join-Path $Fixture 'Eklee.KeyVault.UI/package.json'
        $OriginalPackage = Get-Content -LiteralPath $PackageFile -Raw
        Set-Content -LiteralPath (Join-Path $Fixture 'Eklee.KeyVault.UI/vite.config.ts') -Value 'export default {}'
        Assert-Equal (& $SetupScript -RepoRoot $Fixture).Status 'Blocked' 'setup requires configured approved source'
        Set-Content -LiteralPath (Join-Path $Fixture 'Eklee.KeyVault.UI/.npmrc') -Value 'registry=https://approved.example/npm/'
        Assert-Equal (& $SetupScript -RepoRoot $Fixture -WhatIf).Status 'Preview' 'setup preview'
        Assert-Equal $SkillTestState.NpmInstalls 0 'preview never resolves or installs packages'
        Assert-Equal (Get-Content -LiteralPath $PackageFile -Raw) $OriginalPackage 'preview preserves manifest'
        $SkillTestState.NpmConfig.registry = 'https://unapproved.example/npm/'
        Assert-Equal (& $SetupScript -RepoRoot $Fixture).Status 'Blocked' 'registry override blocks setup'
        $SkillTestState.NpmConfig.registry = 'https://approved.example/npm/'
        $SkillTestState.NpmConfig['@testing-library:registry'] = 'https://unapproved.example/npm/'
        Assert-Equal (& $SetupScript -RepoRoot $Fixture).Status 'Blocked' 'scoped registry override blocks setup'
        $SkillTestState.NpmConfig.Remove('@testing-library:registry')
        Assert-Equal $SkillTestState.NpmInstalls 0 'source mismatches never resolve packages'
        $SkillTestState.LockRegistry = 'https://unapproved.example/npm/'
        Assert-Equal (& $SetupScript -RepoRoot $Fixture).Status 'Blocked' 'foreign lock downloads block installation'
        Assert-Equal $SkillTestState.NpmCi 0 'foreign tarballs never downloaded'
        Assert-Equal (Get-Content -LiteralPath $PackageFile -Raw) $OriginalPackage 'blocked resolution restores manifest'
        Assert-Equal (Test-Path -LiteralPath (Join-Path $Fixture 'Eklee.KeyVault.UI/package-lock.json')) $false 'blocked resolution restores missing lock'
        $SkillTestState.LockRegistry = 'https://approved.example/npm/'
        $LockFile = Join-Path $Fixture 'Eklee.KeyVault.UI/package-lock.json'
        $ForeignLock = '{"lockfileVersion":3,"packages":{"node_modules/example":{"resolved":"https://unapproved.example/package.tgz","integrity":"sha512-fixture"}}}'
        Set-Content -LiteralPath $LockFile -Value $ForeignLock -NoNewline
        $InstallsBefore = $SkillTestState.NpmInstalls
        Assert-Equal (& $SetupScript -RepoRoot $Fixture).Status 'Blocked' 'existing foreign lock blocks before resolution'
        Assert-Equal $SkillTestState.NpmInstalls $InstallsBefore 'existing foreign lock is never reused'
        Assert-Equal (Get-Content -LiteralPath $LockFile -Raw) $ForeignLock 'preflight preserves existing lock'
        Remove-Item -LiteralPath $LockFile
        $RegistryLock = '{"lockfileVersion":3,"packages":{"node_modules/example":{"version":"1.2.3","integrity":"sha512-fixture"}}}'
        Set-Content -LiteralPath $LockFile -Value $RegistryLock -NoNewline
        Assert-Equal (& $SetupScript -RepoRoot $Fixture -WhatIf).Status 'Blocked' 'unexpected missing lock download metadata blocks setup'
        $SkillTestState.NpmConfig['omit-lockfile-registry-resolved'] = $true
        Assert-Equal (& $SetupScript -RepoRoot $Fixture -WhatIf).Status 'Preview' 'configured npm registry metadata omission supported'
        Assert-Equal $SkillTestState.NpmInstalls $InstallsBefore 'omitted registry metadata preview remains read-only'
        $SkillTestState.NpmConfig.Remove('omit-lockfile-registry-resolved')
        Remove-Item -LiteralPath $LockFile
        $UnsupportedPackage = $OriginalPackage | ConvertFrom-Json -AsHashtable
        $UnsupportedPackage.scripts['test:unit'] = 'custom-runner'
        $UnsupportedPackage | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $PackageFile
        Assert-Equal (& $SetupScript -RepoRoot $Fixture).Status 'Blocked' 'unsupported existing test command preserved'
        Assert-Equal (Get-Content -LiteralPath $PackageFile -Raw | ConvertFrom-Json -AsHashtable).scripts['test:unit'] 'custom-runner' 'unsupported command not overwritten'
        Set-Content -LiteralPath $PackageFile -Value $OriginalPackage -NoNewline
        $SkillTestState.NativeFailure = $true
        Assert-Equal (& $SetupScript -RepoRoot $Fixture).Status 'Blocked' 'npm failure blocks setup without fallback'
        $SkillTestState.NativeFailure = $false
        $Setup = & $SetupScript -RepoRoot $Fixture
        Assert-Equal $Setup.Status 'Configured' "frontend setup configured ($($Setup.Reason))"
        Assert-Equal ($Setup.Commands[0].Arguments -contains '--ignore-scripts') $true 'resolution disables lifecycle scripts'
        Assert-Equal ($Setup.Commands[0].Arguments -contains '--omit-lockfile-registry-resolved=false') $true 'new lock materializes download URLs for verification'
        Assert-Equal ($Setup.Commands[1].Arguments -contains '--engine-strict') $true 'installation checks runtime compatibility'
        Assert-Equal ($Setup.Commands[1].Arguments -contains '--include=dev') $true 'production environment cannot omit test dependencies'
        Assert-Equal $SkillTestState.NpmCi 1 'one verified installation'
        Assert-Equal (Get-Content -LiteralPath $PackageFile -Raw | ConvertFrom-Json -AsHashtable).devDependencies.vite ($OriginalPackage | ConvertFrom-Json -AsHashtable).devDependencies.vite 'existing dependency version preserved'
        $ConfigPath = Join-Path $Fixture 'Eklee.KeyVault.UI/vitest.config.mjs'
        $ConfigBefore = Get-Content -LiteralPath $ConfigPath -Raw
        Assert-Equal ($ConfigBefore -match "include: \['src/\*\*/\*\.test") $true 'configuration limits discovery to source unit tests'
        Assert-Equal (& $SetupScript -RepoRoot $Fixture).Status 'Ready' 'setup rerun is idempotent'
        Assert-Equal $SkillTestState.NpmCi 1 'ready setup does not reinstall'
        Assert-Equal (Get-Content -LiteralPath $ConfigPath -Raw) $ConfigBefore 'existing test configuration preserved'
        $UiPackage = Get-Content -LiteralPath $PackageFile -Raw | ConvertFrom-Json -AsHashtable
        $UiPackage.scripts.test = 'vitest'
        $UiPackage.devDependencies.vitest = '4.1.6'
        $UiPackage | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $PackageFile
        $null = [IO.Directory]::CreateDirectory((Join-Path $Fixture 'Eklee.KeyVault.UI/node_modules/vitest'))
        Set-Content -LiteralPath (Join-Path $Fixture 'Eklee.KeyVault.UI/node_modules/vitest/package.json') -Value '{}'
        Set-Content -LiteralPath (Join-Path $Fixture 'Eklee.KeyVault.UI/src/example.test.ts') -Value 'fixture'
        Assert-Equal (& $FrontendScript -TestFiles src/example.test.ts -Build -Lint -RepoRoot $Fixture).Status 'Passed' 'frontend run/build/lint reports'
        Assert-Throws { & $FrontendScript -TestFiles e2e/example.test.ts -RepoRoot $Fixture } '*in-project unit-test file*'
        $SkillTestState.Passed = 0
        Assert-Throws { & $FrontendScript -TestFiles src/example.test.ts -RepoRoot $Fixture } '*missing successful execution*'
        $SkillTestState.Passed = 2
        $SkillTestState.Skipped = 1
        Assert-Throws { & $FrontendScript -TestFiles src/example.test.ts -RepoRoot $Fixture } '*failed/skipped tests*'
        $SkillTestState.Skipped = 0

        $Created = & $IssueScript -Title Example -IssueType bug -Requirements 'Detailed fixture requirements' -Repository owner/repo -Confirm:$false
        Assert-Equal $Created.Status 'Created' 'inline issue creation'
        Assert-Equal $SkillTestState.IssueBody 'Detailed fixture requirements' 'inline body preserved'
        Assert-Equal (Test-Path -LiteralPath $SkillTestState.IssueBodyPath) $false 'temporary issue body removed'
        & {
            . (Join-Path $Scripts 'create-release/scripts/New-Release.ps1') -Version minor
            Assert-Equal (Resolve-ReleaseVersion -RequestedVersion minor -PreviousVersion 1.2.3).Version '1.3.0' 'release version contract'
        }
        $FunctionalBody = Get-Content -LiteralPath (Join-Path $Scripts 'functional-implementation-code-review/SKILL.md') -Raw
        $SecurityBody = Get-Content -LiteralPath (Join-Path $Scripts 'security-implementation-code-review/SKILL.md') -Raw
        $PerformanceBody = Get-Content -LiteralPath (Join-Path $Scripts 'performance-implementation-code-review/SKILL.md') -Raw
        $ImplementationBody = Get-Content -LiteralPath (Join-Path $Scripts 'implement-issue/SKILL.md') -Raw
        $AgentPath = Join-Path $RepoRoot '.github/agents/implement-issue.agent.md'
        $AgentBody = Get-Content -LiteralPath $AgentPath -Raw
        $PrBody = Get-Content -LiteralPath (Join-Path $Scripts 'create-pull-request/SKILL.md') -Raw
        Assert-Equal ($PerformanceBody -match '(?m)^name: performance-implementation-code-review\r?$') $true 'performance skill discovery name'
        Assert-Equal ($PerformanceBody -match 'Only verified documentation-only changes may skip this review') $true 'performance only documentation exception'
        Assert-Equal ($PerformanceBody -match '(?s)Mixed or uncertain changes require\s+performance review') $true 'mixed and uncertain changes require performance review'
        Assert-Equal ($PerformanceBody -match '(?s)Finding no performance-sensitive changes.*?not an additional skip reason') $true 'no performance findings cannot bypass review'
        Assert-Equal ($PerformanceBody -match '(?s)SkippedDocumentationOnly.*?fingerprint,\s+complete file inventory, and evidence') $true 'performance exception evidence'
        Assert-Equal ($AgentBody -match '(?s)5\. Dispatch.*?\[performance-implementation-code-review\].*?6\. Wait for all three review results') $true 'performance review participates in joined review gate'
        Assert-Equal ($AgentBody -match '(?s)7\. Resume `create-pull-request`.*?security and performance evidence.*?same snapshot\s+fingerprint') $true 'publication requires matching performance evidence'
        Assert-Equal ($AgentBody -match '(?s)require performance review; no other skip reason is permitted') $true 'agent performance exception boundary'
        Assert-Equal ($PrBody -match '\[performance review\]\(../performance-implementation-code-review/SKILL.md\)') $true 'PR skill loads performance review'
        Assert-Equal ($PrBody -match '(?s)verify all three\s+review dispositions before Preview/Create') $true 'PR caller checks all local review verdicts'
        Assert-Equal ($AgentBody -match '(?s)^---\r?\nname: Issue Implementation Coordinator\r?\ndescription: .+?\r?\nargument-hint: .+?\r?\ndisable-model-invocation: true\r?\n---') $true 'implementation agent frontmatter'
        Assert-Equal (([regex]::Matches($AgentBody, '(?m)^[1-8]\. ')).Count) 8 'coordinator includes a dedicated documentation stage'
        Assert-Equal ($AgentBody -match '(?s)1\. Use \[create-issue-branch\].*?verified branch-provenance evidence.*?2\. Use \[implement-issue\]') $true 'branch provenance precedes implementation'
        Assert-Equal ($AgentBody -match '(?s)4\. Load \[create-pull-request\].*?base-resolution phase.*?Get-ReviewSnapshot\.ps1.*?once with that resolved base.*?Require\s+`Captured`.*?5\. Dispatch') $true 'routing and shared snapshot precede parallel reviews'
        Assert-Equal ($AgentBody -match '(?s)5\. Dispatch three independent, read-only reviews in parallel.*?functional-implementation-code-review.*?security-implementation-code-review.*?performance-implementation-code-review') $true 'three review skills dispatch in parallel'
        Assert-Equal ($AgentBody -match '(?s)same complete snapshot and fingerprint from step 4;\s+none waits for another review') $true 'parallel reviewers share input without result dependencies'
        Assert-Equal ($AgentBody -match '(?s)Require functional\s+`Pass`.*?Require security and performance `Pass`.*?each skill\s+independently verifies.*?SkippedDocumentationOnly') $true 'parallel review retains independent disposition gates'
        Assert-Equal ($AgentBody -match '(?s)6\. Wait for all three review results before editing source or proceeding') $true 'coordinator joins all reviewers before fixes'
        Assert-Equal ($AgentBody -match 'Missing, blocked, stale, or incomplete evidence blocks publication') $true 'incomplete round cannot pass publication gate'
        Assert-Equal ($AgentBody -match '(?s)Recheck\s+the current snapshot with the same base and scope.*?discard the round.*?return to step 3') $true 'snapshot drift invalidates review round'
        Assert-Equal ($AgentBody -match '(?s)After any review fix, return to step 3 for affected\s+documentation reconciliation, then repeat steps 4 through 6 with a fresh\s+complete snapshot and all applicable local reviews in parallel.*?reclassification of documentation-only exceptions') $true 'fixes require documentation closure and fresh parallel review evidence'
        Assert-Equal ($AgentBody -match '(?s)serialize checks sharing build outputs, caches,\s+services, or report files') $true 'parallel reviews serialize shared mutable checks'
        Assert-Equal ($AgentBody -match '(?s)If parallel delegation is unavailable, perform all three skills\s+sequentially against the same snapshot and disclose the fallback') $true 'fallback retains complete review scope'
        Assert-Equal ($AgentBody -match 'Complete each gate before proceeding; delegation does not change stage order') $false 'obsolete sequential review constraint removed'
        foreach ($ReviewBody in @($FunctionalBody, $SecurityBody, $PerformanceBody)) {
            Assert-Equal ($ReviewBody -match 'snapshot from the coordinating caller|snapshot from the coordinating caller or') $true 'review skill accepts coordinator-owned snapshot'
            Assert-Equal ($ReviewBody -match '(?s)do not substitute a different fingerprint') $true 'review skill rejects assigned snapshot drift'
            Assert-Equal ($ReviewBody -match '(?s)For standalone review without a supplied snapshot.*?Get-ReviewSnapshot\.ps1') $true 'review skill retains standalone snapshot capture'
        }
        Assert-Equal ($AgentBody -match '(?s)8\. Use \[request-github-code-review\].*?successful creation or verified reuse') $true 'remote review follows verified PR'
        Assert-Equal ($AgentBody -match '(?s)without a separate\s+branch-creation approval when all prerequisite checks pass') $true 'coordinator proceeds after branch prerequisites pass'
        Assert-Equal ($AgentBody -match '(?s)issue implementation request authorizes verified local branch creation and\s+implementation') $true 'implementation request authorizes local work'
        Assert-Equal ($AgentBody -match '(?s)alone does not authorize commits, pushes,\s+PR creation, or remote review requests') $true 'coordinator preserves publication approvals'
        $BranchBody = Get-Content -LiteralPath (Join-Path (Split-Path $BranchScript -Parent) '../SKILL.md') -Raw
        Assert-Equal ($BranchBody -match '(?s)without a separate branch-creation approval.*?resolve-only request\s+remains read-only.*?Honor explicit user limits') $true 'branch skill respects request authority and explicit limits'
        Assert-Equal ($BranchBody -match '-ExpectedBaseSha \$Branch.BaseSha -Confirm:\$false') $true 'branch skill creates from verified proposal without prompting'
        Assert-Equal ($AgentBody -match 'Implement units sequentially on the verified issue branch') $true 'units retain verified branch ownership'
        Assert-Equal ($AgentBody -match '(?s)Unit-level checks and reviews\s+do not replace the complete proposed PR reviews') $true 'unit results cannot bypass final reviews'
        Assert-Equal ($AgentBody -match 'This workflow does not create worker branches or worktrees') $true 'conversion does not authorize worktree fan-out'
        Assert-Equal ($AgentBody -match '(?s)Reviewers do not edit\s+source, publish, or delegate further') $true 'review delegation remains read-only and bounded'
        Assert-Equal ($ImplementationBody -match '(?s)## Documentation Reconciliation\s+After implementation is consolidated and before handing off to local review') $true 'implementation reconciles documentation before review'
        Assert-Equal ($ImplementationBody -match '(?s)Update existing documentation first; create a new page only when.*?Verify links and examples.*?run applicable documentation checks') $true 'documentation updates reuse existing pages and require validation'
        Assert-Equal ($ImplementationBody -match '(?s)unresolved required documentation gaps block the handoff.*?When no updates are needed, return a justified no-update result') $true 'documentation handoff requires closure or justified no-update evidence'
        Assert-Equal ($ImplementationBody -match 'Include documentation changes in the complete proposed review snapshot') $true 'documentation participates in complete review scope'
        Assert-Equal ($AgentBody -match '(?s)2\. Use \[implement-issue\].*?documentation closure in step 3 before handing off to local review\.\s+3\. Complete.*?\[documentation reconciliation\].*?consolidation and before review.*?4\. Load') $true 'dedicated documentation reconciliation precedes snapshot capture'
        Assert-Equal ($AgentBody -match '(?s)3\. Complete.*?Require documentation evidence: updated\s+files, addressed and unresolved gaps, and check results, or a justified\s+no-update result tied to the issue criteria, changed behavior, and existing\s+documentation inspected') $true 'documentation stage requires updates or justified no-update evidence'
        Assert-Equal ($AgentBody -match '(?s)3\. Complete.*?Missing required documentation checks or unresolved\s+required gaps block step 4.*?Carry the evidence and changed files forward') $true 'documentation gaps block snapshot handoff'
        Assert-Equal ($AgentBody -match '(?m)^## Documentation Closure\s*$|documentation closure rules above') $false 'documentation closure is consolidated into workflow steps'
        Assert-Equal ($AgentBody -match '(?s)7\. Resume `create-pull-request`.*?only after a final read-only documentation gap check confirms\s+documentation matches the final implementation, including review fixes\..*?8\. Use') $true 'publication requires final read-only documentation check'
        Assert-Equal ($AgentBody -match '(?s)7\. Resume `create-pull-request`.*?If required gaps remain or documentation edits are needed, return to step 3,\s+rerun affected validation and steps 4 through 6 against a fresh complete\s+snapshot fingerprint, then repeat the final documentation check\. Unresolved\s+required documentation gaps block publication\..*?8\. Use') $true 'late documentation edits require fresh validation and reviews before publication'
        Assert-Equal ($AgentBody -match '(?s)complete proposed PR reviews in steps 4 through 6.*?separate reviewer context for each of the three parallel reviews in step 5') $true 'review coordination references shifted stages'
        Assert-Equal ($AgentBody -match '(?s)## Completion Report.*?Report documentation updates or a justified no-update result, documentation\s+check results, and unresolved gaps') $true 'completion reports documentation evidence and gaps'
        foreach ($Link in [regex]::Matches($AgentBody, '\]\(([^)#]+)(?:#[^)]*)?\)')) {
            Assert-Equal (Test-Path -LiteralPath (Join-Path (Split-Path $AgentPath -Parent) $Link.Groups[1].Value)) $true 'implementation agent reference'
        }

        & {
            $HostedScript = Join-Path $Scripts 'implement-ui-tests/scripts/Invoke-HostedUiTests.ps1'
            . $HostedScript
            $HostedState = @{
                Sha = ('a' * 40); Branch = 'feature/60'; Workflow = '.github/workflows/cicd.yml'
                Conclusion = 'success'; Step = 'success'; Running = $false; NoRun = $false
                Artifact = $true; Report = $true; Skipped = 0; Flaky = 0; Expected = 1
                TestStatus = 'expected'; ResultStatus = 'passed'; Target = 'https://branch.example/'; ForbidOnly = $true
                ConfiguredTarget = 'https://branch.example/'
                Urls = @('https://github.com/owner/repo.git'); Config = ''; Staged = @()
                Unmerged = ''; Ahead = '0'; Behind = '0'; WatchCalls = 0; Writes = 0
                Head = ('a' * 40); Published = ('a' * 40); Parent = ('a' * 40)
                Dirty = @(); Untracked = @(); Committed = @('LICENSE'); PushFailure = $false
                NoChanges = $false; PushArguments = @(); LocalChecks = 0
            }
            $EvidenceDirectories = [Collections.Generic.List[string]]::new()
            function gh {
                $global:LASTEXITCODE = 0
                if ($args[0] -eq 'auth') { return 'authenticated fixture' }
                if ($args[0] -eq 'repo') { return '{"nameWithOwner":"owner/repo","url":"https://github.com/owner/repo"}' }
                if ($args[0] -eq 'variable') { return $HostedState.ConfiguredTarget }
                if ($args[0] -eq 'api') {
                    if ($args[-1] -like '*artifacts*') {
                        $Artifacts = @()
                        if ($HostedState.Artifact) { $Artifacts = @(@{ name = 'hosted-playwright-results-branch-123'; expired = $false }) }
                        return ConvertTo-Json -InputObject @(@{ artifacts = $Artifacts }) -Depth 10
                    }
                    return @{
                        head_sha = $HostedState.Sha; head_branch = $HostedState.Branch; path = $HostedState.Workflow
                        event = 'push'; status = $(if ($HostedState.Running) { 'in_progress' } else { 'completed' })
                        conclusion = $HostedState.Conclusion; html_url = 'https://github.com/owner/repo/actions/runs/123'
                    } | ConvertTo-Json
                }
                if ($args[0] -ne 'run') { throw "Unexpected hosted gh call: $args" }
                switch ($args[1]) {
                    'list' {
                        if ($HostedState.NoRun) { return '[]' }
                        return '[{"databaseId":123}]'
                    }
                    'watch' { $HostedState.WatchCalls++; $HostedState.Running = $false; return 'completed' }
                    'view' {
                        if ($args -contains '--log') { return 'masked CI log fixture' }
                        return @{ jobs = @(@{ steps = @(@{ name = 'Run hosted Playwright tests'; conclusion = $HostedState.Step }) }) } | ConvertTo-Json -Depth 10
                    }
                    'download' {
                        $Directory = $args[-1]
                        $EvidenceDirectories.Add($Directory)
                        if ($HostedState.Report) {
                            @{
                                config = @{ forbidOnly = $HostedState.ForbidOnly }
                                errors = @(); stats = @{ expected = $HostedState.Expected; unexpected = 0; skipped = $HostedState.Skipped; flaky = $HostedState.Flaky }
                                suites = @(@{ specs = @(@{ file = 'categories-crud.spec.ts'; tests = @(@{
                                    expectedStatus = 'passed'; status = $HostedState.TestStatus
                                    results = @(@{ status = $HostedState.ResultStatus })
                                    annotations = @(@{ type = 'Test URL'; description = $HostedState.Target })
                                }) }) })
                            } | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath (Join-Path $Directory 'playwright-results.json')
                        }
                        return ''
                    }
                    default { throw "Unexpected hosted gh run call: $args" }
                }
            }
            function git {
                $global:LASTEXITCODE = 0
                switch ($args[0]) {
                    'check-ref-format' { return '' }
                    'remote' { return ($HostedState.Urls -join "`n") }
                    'config' { return $HostedState.Config }
                    'diff' {
                        if ($args -contains '--cached') { return ($HostedState.Staged -join "`0") }
                        return ($HostedState.Dirty -join "`0")
                    }
                    'ls-files' {
                        if ($args -contains '--others') { return ($HostedState.Untracked -join "`0") }
                        return $HostedState.Unmerged
                    }
                    'ls-remote' { return "$($HostedState.Published)`trefs/heads/feature/60" }
                    'fetch' { return '' }
                    'rev-list' { if ($args[-1] -like 'HEAD..*') { return $HostedState.Behind }; return $HostedState.Ahead }
                    'rev-parse' {
                        if ($args[1] -eq '--show-toplevel') { return $Fixture }
                        if ($args[1] -eq 'HEAD^') { return $HostedState.Parent }
                        return $HostedState.Head
                    }
                    'branch' { return $HostedState.Branch }
                    'status' { return '' }
                    '--literal-pathspecs' {
                        $HostedState.Writes++
                        if (-not $HostedState.NoChanges) { $HostedState.Staged = @($args[3..($args.Count - 1)]) }
                        return ''
                    }
                    'commit' {
                        $HostedState.Writes++
                        $HostedState.Parent = $HostedState.Head
                        $HostedState.Head = ('c' * 40)
                        return 'committed fixture'
                    }
                    'diff-tree' { return ($HostedState.Committed -join "`0") }
                    '-c' {
                        $HostedState.Writes++
                        $HostedState.PushArguments = @($args)
                        if ($HostedState.PushFailure) { $global:LASTEXITCODE = 1; return 'push rejected fixture' }
                        $HostedState.Published = $HostedState.Head
                        return 'pushed fixture'
                    }
                    default { $HostedState.Writes++; throw "Unexpected hosted Git mutation: $args" }
                }
            }
            function npm {
                $global:LASTEXITCODE = 0
                $HostedState.LocalChecks++
                if ($args[0] -eq 'exec') { return '{"errors":[],"suites":[{"specs":[{"file":"categories-crud.spec.ts"}]}]}' }
                return 'local build/lint fixture'
            }
            try {
                $Context = [pscustomobject]@{ Repository = 'owner/repo'; Source = 'feature/60'; Head = ('a' * 40) }
                $SpecFiles = @('e2e/categories-crud.spec.ts')
                Assert-Equal (Get-UiHostedResult $Context $Context.Head 123 $SpecFiles).Status 'Passed' 'hosted report confirms all pass'
                $HostedState.Sha = ('b' * 40)
                Assert-Throws { Get-UiHostedResult $Context $Context.Head 123 $SpecFiles } '*exact SHA*'
                $HostedState.Sha = $Context.Head
                $HostedState.Workflow = '.github/workflows/other.yml'
                Assert-Throws { Get-UiHostedResult $Context $Context.Head 123 $SpecFiles } '*workflow*'
                $HostedState.Workflow = '.github/workflows/cicd.yml'
                $HostedState.Branch = 'feature/other'
                Assert-Throws { Get-UiHostedResult $Context $Context.Head 123 $SpecFiles } '*branch*'
                $HostedState.Branch = $Context.Source
                $HostedState.NoRun = $true
                Assert-Equal (Get-UiHostedResult $Context $Context.Head 0 $SpecFiles).Status 'RunNotFound' 'missing exact run is not passed'
                $HostedState.NoRun = $false
                $HostedState.Running = $true
                Assert-Equal (Get-UiHostedResult $Context $Context.Head 123 $SpecFiles).Status 'Running' 'inspect does not wait'
                Assert-Equal (Get-UiHostedResult $Context $Context.Head 123 $SpecFiles -Wait).Status 'Passed' 'captured watcher waits for exact run'
                Assert-Equal $HostedState.WatchCalls 1 'one watcher invocation'
                foreach ($Property in @('Skipped', 'Flaky')) {
                    $HostedState[$Property] = 1
                    Assert-Equal (Get-UiHostedResult $Context $Context.Head 123 $SpecFiles).Status 'Failed' "$Property prevents pass"
                    $HostedState[$Property] = 0
                }
                $HostedState.Expected = 0
                Assert-Equal (Get-UiHostedResult $Context $Context.Head 123 $SpecFiles).Status 'Failed' 'zero executions cannot pass'
                $HostedState.Expected = 1
                $HostedState.ForbidOnly = $false
                Assert-Equal (Get-UiHostedResult $Context $Context.Head 123 $SpecFiles).Status 'Failed' 'focused-test filtering cannot prove full suite'
                $HostedState.ForbidOnly = $true
                $HostedState.ResultStatus = 'failed'
                Assert-Equal (Get-UiHostedResult $Context $Context.Head 123 $SpecFiles).Status 'Failed' 'individual failed result cannot pass'
                $HostedState.ResultStatus = 'passed'
                Assert-Equal (Get-UiHostedResult $Context $Context.Head 123 @('e2e/missing.spec.ts')).Status 'Failed' 'absent requested spec cannot pass'
                $HostedState.Report = $false
                Assert-Equal (Get-UiHostedResult $Context $Context.Head 123 $SpecFiles).Status 'EvidenceMissing' 'old report cannot prove pass'
                $HostedState.Report = $true
                $HostedState.Conclusion = 'failure'
                Assert-Equal (Get-UiHostedResult $Context $Context.Head 123 $SpecFiles).Status 'Failed' 'workflow failure stays failed'
                $HostedState.Conclusion = 'success'
                $HostedState.Step = 'skipped'
                Assert-Equal (Get-UiHostedResult $Context $Context.Head 123 $SpecFiles).Status 'Failed' 'skipped browser step cannot pass'
                $HostedState.Step = 'success'
                $HostedState.Target = 'http://localhost:8080/'
                Assert-Throws { Get-UiHostedResult $Context $Context.Head 123 $SpecFiles } '*cloud dev branch HTTPS URL*'
                $HostedState.Target = 'https://branch.example/'
                Assert-Equal (Assert-UiPublication $Context $Fixture @('LICENSE') 'feature/60' 'owner/repo') 'https://github.com/owner/repo.git' 'one verified push endpoint'
                Assert-Throws { Assert-UiPublication $Context $Fixture @('../outside') 'feature/60' 'owner/repo' } '*Unsupported task path*'
                foreach ($Path in @('Eklee.KeyVault.UI/playwright-results.json', 'Eklee.KeyVault.UI/.env.local', 'setup-dev.json')) {
                    Assert-Throws { Assert-UiPublication $Context $Fixture @($Path) 'feature/60' 'owner/repo' } '*Unsupported task path*'
                }
                $HostedState.Staged = @('unrelated.txt')
                Assert-Throws { Assert-UiPublication $Context $Fixture @('LICENSE') 'feature/60' 'owner/repo' } '*Unrelated staged*'
                $HostedState.Staged = @()
                $HostedState.Urls = @('https://github.com/other/repo.git')
                Assert-Throws { Assert-UiPublication $Context $Fixture @('LICENSE') 'feature/60' 'owner/repo' } '*approved GitHub push endpoint*'
                $HostedState.Urls = @('https://github.com/owner/repo.git', 'https://github.com/other/repo.git')
                Assert-Throws { Assert-UiPublication $Context $Fixture @('LICENSE') 'feature/60' 'owner/repo' } '*exactly one*'
                $HostedState.Urls = @('https://github.com/owner/repo.git')
                $HostedState.Config = "remote.origin.push`nrefs/heads/*:refs/heads/*`0"
                Assert-Throws { Assert-UiPublication $Context $Fixture @('LICENSE') 'feature/60' 'owner/repo' } '*Extra push refspecs*'
                $HostedState.Config = "remote.origin.mirror`ntrue`0"
                Assert-Throws { Assert-UiPublication $Context $Fixture @('LICENSE') 'feature/60' 'owner/repo' } '*mirror*'
                $HostedState.Config = ''
                $HostedState.Ahead = '1'
                Assert-Throws { Assert-UiPublication $Context $Fixture @('LICENSE') 'feature/60' 'owner/repo' } '*HEAD must match*'
                $HostedState.Ahead = '0'
                $HostedState.Unmerged = 'unmerged'
                Assert-Throws { Assert-UiPublication $Context $Fixture @('LICENSE') 'feature/60' 'owner/repo' } '*Unmerged*'
                $HostedState.Unmerged = ''
                Assert-Throws { Assert-UiTaskScope $null $Context $HostedState.Urls[0] @('LICENSE') } '*original Begin task scope*'
                $Scope = [pscustomobject]@{
                    Status = 'ScopeCaptured'; Repository = 'owner/repo'; Source = 'feature/60'
                    PushUrl = $HostedState.Urls[0]; InitialDirtyFiles = @('LICENSE'); TestUrl = 'https://branch.example'
                }
                Assert-Throws { Assert-UiTaskScope $Scope $Context $HostedState.Urls[0] @('LICENSE') } '*pre-existing edits*'
                if ($IsWindows) {
                    Assert-Throws { Assert-UiTaskScope $Scope $Context $HostedState.Urls[0] @('license') } '*pre-existing edits*'
                }
                else {
                    Assert-UiTaskScope $Scope $Context $HostedState.Urls[0] @('license')
                }
                $Scope.InitialDirtyFiles = @('unrelated.txt')
                Assert-UiTaskScope $Scope $Context $HostedState.Urls[0] @('LICENSE')
                $HostedState.ConfiguredTarget = 'https://other.example/'
                Assert-Throws { Assert-UiTaskScope $Scope $Context $HostedState.Urls[0] @('LICENSE') } '*cloud dev target changed*'
                foreach ($Url in @('http://branch.example/', 'https://localhost/', 'https://user:password@branch.example/', '/relative')) {
                    $HostedState.ConfiguredTarget = $Url
                    Assert-Throws { Get-UiCloudTarget 'owner/repo' } '*absolute, non-loopback, and credential-free*'
                }
                $HostedState.ConfiguredTarget = 'https://branch.example/'
                $Scope.PushUrl = 'https://github.com/other/repo.git'
                Assert-Throws { Assert-UiTaskScope $Scope $Context $HostedState.Urls[0] @('LICENSE') } '*endpoint must remain unchanged*'
                $Context.Source = 'main'
                Assert-Throws { Assert-UiPublication $Context $Fixture @('LICENSE') 'main' 'owner/repo' } '*main or release*'
                Assert-Equal $HostedState.Writes 0 'hosted guard tests never commit or push'
                $Context.Source = 'feature/60'
                foreach ($Package in @('typescript', 'eslint', '@playwright/test')) {
                    $PackageDirectory = Join-Path $Fixture "Eklee.KeyVault.UI/node_modules/$Package"
                    $null = [IO.Directory]::CreateDirectory($PackageDirectory)
                    Set-Content -LiteralPath (Join-Path $PackageDirectory 'package.json') -Value '{}'
                }
                $SpecDirectory = Join-Path $Fixture 'Eklee.KeyVault.UI/e2e'
                $null = [IO.Directory]::CreateDirectory($SpecDirectory)
                Set-Content -LiteralPath (Join-Path $SpecDirectory 'categories-crud.spec.ts') -Value 'fixture'
                $HostedState.Dirty = @('unrelated.txt')
                $Begin = & $HostedScript -Action Begin -TaskFiles LICENSE -RepoRoot $Fixture
                Assert-Equal $Begin.Status 'ScopeCaptured' 'Begin captures pre-edit scope'
                Assert-Equal $Begin.Repository 'owner/repo' 'Begin resolves repository input'
                Assert-Equal $Begin.Source 'feature/60' 'Begin resolves source branch input'
                Assert-Equal $Begin.TestUrl 'https://branch.example' 'Begin captures configured cloud target'
                Assert-Equal ($Begin.InitialDirtyFiles -join ',') 'unrelated.txt' 'Begin preserves initial dirty file evidence'
                $PublishArgs = @{
                    Action = 'Publish'; Repository = 'owner/repo'; ExpectedBranch = 'feature/60'
                    TaskFiles = @('LICENSE'); TestFiles = $SpecFiles; TaskScope = $Begin
                    PublishAuthorized = $true; Message = 'test: hosted iteration'; RepoRoot = $Fixture
                }
                Assert-Equal (& $HostedScript @PublishArgs -WhatIf).Status 'Preview' 'publish preview does not commit or push'
                Assert-Equal $HostedState.Writes 0 'publication preview has no Git mutations'
                Assert-Equal $HostedState.LocalChecks 0 'publication preview has no local check side effects'
                $Begin.InitialDirtyFiles = @('LICENSE')
                Assert-Throws { & $HostedScript @PublishArgs -Confirm:$false } '*pre-existing edits*'
                Assert-Equal $HostedState.Writes 0 'pre-existing task edits never staged'
                $Begin.InitialDirtyFiles = @('unrelated.txt')
                $Published = & $HostedScript @PublishArgs -Confirm:$false
                Assert-Equal $Published.Status 'Published' 'scoped ordinary publication'
                Assert-Equal $HostedState.LocalChecks 3 'publication builds lints and discovers before Git writes'
                Assert-Equal ($Published.TaskFiles -join ',') 'LICENSE' 'only explicit task files committed'
                Assert-Equal ($HostedState.PushArguments -join ' ') "-c push.followTags=false -c push.recurseSubmodules=no push --porcelain https://github.com/owner/repo.git $('c' * 40):refs/heads/feature/60" 'explicit endpoint SHA branch push with no tags or submodules'
                $HostedState.Staged = @()
                $HostedState.NoChanges = $true
                Assert-Equal (& $HostedScript @PublishArgs -Confirm:$false).Status 'NoChanges' 'clean iteration does not create an empty commit'
                $HostedState.NoChanges = $false
                $HostedState.Head = ('a' * 40); $HostedState.Published = ('a' * 40)
                $HostedState.Committed = @('unrelated.txt')
                Assert-Throws { & $HostedScript @PublishArgs -Confirm:$false } '*post-hook scope check*'
                Assert-Equal $HostedState.Published ('a' * 40) 'hook-added unrelated changes never pushed'
                $HostedState.Head = ('a' * 40); $HostedState.Staged = @()
                $HostedState.Committed = @('LICENSE'); $HostedState.PushFailure = $true
                Assert-Throws { & $HostedScript @PublishArgs -Confirm:$false } '*remains local*Ordinary push failed*stop without force-push*'
                Assert-Equal $HostedState.Published ('a' * 40) 'rejected push preserves remote tip'
            }
            finally {
                foreach ($Directory in $EvidenceDirectories) { Remove-Item -LiteralPath $Directory -Recurse -Force }
            }
        }

        foreach ($Skill in Get-ChildItem $Scripts -Recurse -Filter SKILL.md) {
            $Body = Get-Content -LiteralPath $Skill.FullName -Raw
            Assert-Equal ($Body -match '(?s)^---\r?\nname: .+?\r?\ndescription: .+?\r?\n.*?---') $true "frontmatter $($Skill.Directory.Name)"
            foreach ($Link in [regex]::Matches($Body, '\]\(([^)#]+)(?:#[^)]*)?\)')) {
                $Target = $Link.Groups[1].Value
                if ($Target -notmatch '^https?://') {
                    Assert-Equal (Test-Path -LiteralPath (Join-Path $Skill.DirectoryName $Target)) $true "reference $Target"
                }
            }
        }
        foreach ($Script in Get-ChildItem $Scripts -Recurse -Filter *.ps1) {
            $Tokens = $null; $ParseErrors = $null
            $null = [Management.Automation.Language.Parser]::ParseFile($Script.FullName, [ref]$Tokens, [ref]$ParseErrors)
            Assert-Equal $ParseErrors.Count 0 "syntax $($Script.Name)"
        }
        Write-Host "PASS: $script:Assertions assertions; mocked CLI execution only."
    }
    finally {
        Remove-Item -LiteralPath $Fixture -Recurse -Force -ErrorAction SilentlyContinue
        $global:LASTEXITCODE = $PreviousExitCode
    }
}