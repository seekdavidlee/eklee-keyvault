#!/usr/bin/env pwsh
#Requires -Version 7.4

<#
.SYNOPSIS
    Reads an issue and checks the checkout without creating branches.
.PARAMETER Issue
    Issue number or GitHub issue URL in the checkout's repository.
.PARAMETER Repository
    Optional owner/name, verified against the checkout.
.PARAMETER RepoRoot
    Checkout to inspect; defaults to this script's repository.
.OUTPUTS
    Status (Ready or FeatureBranchRequired), source, HEAD, worktree,
    and the issue including its body and current discussion.
.EXAMPLE
    ./Get-IssueContext.ps1 -Issue 60
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Issue,
    [string]$Repository,
    [string]$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../../..')).Path
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '../../_shared/RepositoryTools.ps1')

if ($MyInvocation.InvocationName -ne '.') {
    Push-Location $RepoRoot
    try {
        $Context = Get-SkillContext -Repository $Repository
        $Details = Invoke-SkillJson @(
            'issue', 'view', $Issue, '--repo', $Context.Repository,
            '--json', 'number,url,title,body,comments,state'
        )
        if ($Details.url -cne "$($Context.RepositoryUrl)/issues/$($Details.number)") {
            throw 'The issue does not belong to the checkout repository.'
        }
        $Status = 'Ready'
        if ($Context.Source -ceq 'main' -or $Context.Source -clike 'release/*') {
            $Status = 'FeatureBranchRequired'
        }
        [pscustomobject]@{ Status = $Status; Context = $Context; Issue = $Details }
    }
    finally {
        Pop-Location
    }
}