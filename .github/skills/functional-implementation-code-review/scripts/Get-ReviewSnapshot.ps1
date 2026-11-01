#!/usr/bin/env pwsh
#Requires -Version 7.4

<#
.SYNOPSIS
    Captures the resolved review scope and content identity without publication.
.PARAMETER Base
    Optional explicit remote base. Ambiguity returns BaseSelectionRequired.
.PARAMETER TaskFiles
    Optional repository-relative working files in scope. All committed branch
    changes remain included; other working files are listed as exclusions.
.PARAMETER ExpectedFingerprint
    Optional assigned snapshot fingerprint. Requires an explicit Base and the
    same TaskFiles selection; throws if current content or identity has changed.
.PARAMETER OutputFile
    Optional new JSON destination outside the repository. Existing files are
    never overwritten; WhatIf captures the snapshot without writing the file.
.PARAMETER RepoRoot
    Repository checkout; defaults to this script's repository.
.OUTPUTS
    Status, routing, and snapshot with SHAs, file hashes, full diffs, and fingerprint.
.EXAMPLE
    ./Get-ReviewSnapshot.ps1 -Base release/1.2.0 -TaskFiles README.md
.EXAMPLE
    ./Get-ReviewSnapshot.ps1 -Base $Snapshot.Base -ExpectedFingerprint $Snapshot.Fingerprint
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$Base,
    [string[]]$TaskFiles,
    [ValidatePattern('^[A-Fa-f0-9]{64}$')][string]$ExpectedFingerprint,
    [string]$OutputFile,
    [string]$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../../..')).Path
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '../../_shared/RepositoryTools.ps1')

if ($MyInvocation.InvocationName -ne '.') {
    Push-Location $RepoRoot
    try {
        if ($ExpectedFingerprint -and -not $Base) {
            throw 'ExpectedFingerprint requires the assigned snapshot Base and the same TaskFiles selection.'
        }
        $Context = Get-SkillContext
        $Routing = Get-SkillRouting -Source $Context.Source -Base $Base
        if ($Routing.Status -eq 'BaseSelectionRequired') {
            return $Routing
        }
        $Snapshot = Get-SkillSnapshot -Context $Context -Base $Routing.Base -TaskFiles $TaskFiles
        if ($ExpectedFingerprint -and $Snapshot.Fingerprint -ine $ExpectedFingerprint) {
            throw 'The assigned review snapshot is stale or mismatched. Do not substitute a different fingerprint.'
        }
        $Result = [pscustomobject]@{ Status = 'Captured'; Routing = $Routing; Snapshot = $Snapshot }
        if ($OutputFile) {
            $Destination = [IO.Path]::GetFullPath($OutputFile)
            $Root = [IO.Path]::GetFullPath($RepoRoot).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
            if ($Destination.StartsWith($Root, [StringComparison]::OrdinalIgnoreCase) -or
                [IO.Path]::GetExtension($Destination) -ine '.json' -or
                (Test-Path -LiteralPath $Destination)) {
                throw 'OutputFile must be a new JSON file outside the repository.'
            }
            if ($PSCmdlet.ShouldProcess($Destination, 'Write review snapshot')) {
                $Result | ConvertTo-Json -Depth 20 | Out-File -LiteralPath $Destination -Encoding utf8 -NoClobber
            }
        }
        return $Result
    }
    finally {
        Pop-Location
    }
}