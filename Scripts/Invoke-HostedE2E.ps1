#!/usr/bin/env pwsh
# Copyright (c) 2026 Microsoft Corporation. All rights reserved.
# SPDX-License-Identifier: MIT
#Requires -Version 7.4

<#
.SYNOPSIS
    Runs Playwright E2E tests against a deployed Container App.

.DESCRIPTION
    Resolves the deployed Container App and API authentication settings from
    an azd environment, obtains an access token for the signed-in Azure CLI
    identity, waits for the app to become healthy, and runs the local
    Playwright tests against its HTTPS ingress URL.

.PARAMETER Current
    Targets the temporary Container App for the checked-out non-main branch.

.PARAMETER Release
    Targets the temporary Container App for the checked-out release branch.
    The branch must use the release/MAJOR.MINOR.PATCH convention.

.PARAMETER ProfilePath
    Path to the maintainer profile used by Setup-Dev.ps1. Its environmentName
    determines the azd environment that provides the dev resource settings.

.PARAMETER Filter
    Optional test file or grep filter. Defaults to login.spec.ts.

.PARAMETER Headed
    Runs the browser in headed mode.

.PARAMETER NoDeps
    Skips npm and Playwright dependency installation.

.EXAMPLE
    ./Scripts/Invoke-HostedE2E.ps1 -Current

.EXAMPLE
    ./Scripts/Invoke-HostedE2E.ps1 -Release -Filter secrets-crud -Headed

.NOTES
    Requires Azure CLI, Azure Developer CLI, Node.js, npm, and an authenticated
    Azure CLI identity with access to the deployed API.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, ParameterSetName = 'Current')]
    [switch]$Current,

    [Parameter(Mandatory = $true, ParameterSetName = 'Release')]
    [switch]$Release,

    [Parameter(Mandatory = $false)]
    [ValidateNotNullOrEmpty()]
    [string]$ProfilePath = (Join-Path $HOME '.eklee-keyvault\setup-dev.json'),

    [Parameter(Mandatory = $false)]
    [ValidateNotNullOrEmpty()]
    [string]$Filter = 'login.spec.ts',

    [Parameter(Mandatory = $false)]
    [switch]$Headed,

    [Parameter(Mandatory = $false)]
    [switch]$NoDeps
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

#region Functions
function Test-CommandAvailable {
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$CommandName
    )

    if (-not (Get-Command $CommandName -ErrorAction SilentlyContinue)) {
        throw "Required command '$CommandName' was not found on PATH."
    }
}

function Get-AzdEnvironmentValue {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$EnvironmentName,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Name
    )

    $value = & azd env get-value $Name --environment $EnvironmentName 2>$null
    if ($LASTEXITCODE -ne 0) {
        return $null
    }

    $result = ($value | Out-String).Trim().Trim('"')
    if ([string]::IsNullOrWhiteSpace($result)) {
        return $null
    }

    return $result
}

function Get-MaintainerDevTarget {
    [CmdletBinding()]
    [OutputType([psobject])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Maintainer profile '$Path' was not found. Run Setup-Dev.ps1 or provide its profile path."
    }

    try {
        $target = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    }
    catch {
        throw "Could not read maintainer profile '$Path': $($_.Exception.Message)"
    }

    if ($target.PSObject.Properties['targets']) {
        throw "Maintainer profile '$Path' must contain one target object, not a target catalog."
    }

    $environmentName = $target.PSObject.Properties['environmentName']
    if ($null -eq $environmentName -or [string]::IsNullOrWhiteSpace([string]$environmentName.Value)) {
        throw "Maintainer profile '$Path' requires a non-empty 'environmentName' property."
    }

    return $target
}

function Get-BranchContainerAppName {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('Current', 'Release')]
        [string]$TargetMode
    )

    $branchName = (& git branch --show-current 2>$null | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($branchName)) {
        throw 'Unable to determine the current Git branch. Check out a branch before running hosted E2E.'
    }

    if ($branchName -eq 'main') {
        throw 'Hosted E2E cannot target main. Check out the branch or release deployment to test.'
    }

    if ($TargetMode -eq 'Release' -and $branchName -notmatch '^release/(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$') {
        throw "Release mode requires a release/MAJOR.MINOR.PATCH branch. Current branch is '$branchName'."
    }

    $kind = if ($branchName -like 'release/*') { 'release' } else { 'branch' }
    $normalizedName = ($branchName.ToLowerInvariant() -replace '[^a-z0-9]+', '-').Trim('-')
    if ([string]::IsNullOrWhiteSpace($normalizedName)) {
        throw "Current Git branch '$branchName' cannot be converted to a Container App name."
    }

    $hash = [System.Convert]::ToHexString(
        [System.Security.Cryptography.SHA256]::HashData([System.Text.Encoding]::UTF8.GetBytes($branchName))
    ).Substring(0, 7).ToLowerInvariant()
    $slug = $normalizedName.Substring(0, [Math]::Min(12, $normalizedName.Length)).TrimEnd('-')
    $containerAppName = "ekv-$kind-$slug-$hash"
    if ($containerAppName.Length -gt 32) {
        throw "Derived Container App name '$containerAppName' exceeds Azure's 32-character limit."
    }

    return $containerAppName
}

function Get-CurrentAzureValue {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string[]]$Arguments
    )

    $value = & az @Arguments --only-show-errors --output tsv 2>$null
    if ($LASTEXITCODE -ne 0) {
        return $null
    }

    $result = ($value | Out-String).Trim()
    if ([string]::IsNullOrWhiteSpace($result)) {
        return $null
    }

    return $result
}

function Get-HostedTarget {
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$ResourceGroupName,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$ContainerAppName,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$SubscriptionId
    )

    $fqdn = & az containerapp show `
        --name $ContainerAppName `
        --resource-group $ResourceGroupName `
        --subscription $SubscriptionId `
        --query properties.configuration.ingress.fqdn `
        --only-show-errors `
        --output tsv 2>$null
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($fqdn)) {
        throw "Unable to resolve Container App '$ContainerAppName' in resource group '$ResourceGroupName'."
    }

    $baseUrl = "https://$(($fqdn | Out-String).Trim())".TrimEnd('/')
    $parsedUri = $null
    if (-not [System.Uri]::TryCreate($baseUrl, [System.UriKind]::Absolute, [ref]$parsedUri) -or $parsedUri.Scheme -ne 'https') {
        throw "Container App '$ContainerAppName' returned an invalid HTTPS ingress URL."
    }

    return [pscustomobject]@{
        BaseUrl = $baseUrl
        Fqdn    = $parsedUri.Host
    }
}

function Wait-ForHostedApp {
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$BaseUrl,

        [Parameter(Mandatory = $false)]
        [ValidateRange(1, 60)]
        [int]$Attempts = 30
    )

    Write-Host "Waiting for $BaseUrl/healthz ..." -ForegroundColor Cyan
    foreach ($attempt in 1..$Attempts) {
        try {
            $response = Invoke-WebRequest -Uri "$BaseUrl/healthz" -TimeoutSec 10
            if ($response.StatusCode -eq 200) {
                Write-Host 'Container App is healthy.' -ForegroundColor Green
                return
            }
        }
        catch {
            $null = $_
        }

        if ($attempt -lt $Attempts) {
            Start-Sleep -Seconds 10
        }
    }

    throw "Container App did not become healthy: $BaseUrl"
}
#endregion Functions

#region Main Execution
if ($MyInvocation.InvocationName -ne '.') {
    $token = $null
    $testExitCode = 1
    $environmentVariables = @(
        'E2E_BASE_URL',
        'E2E_CLIENT_ID',
        'E2E_TENANT_ID',
        'E2E_ACCESS_TOKEN'
    )

    try {
        Test-CommandAvailable -CommandName 'az'
        Test-CommandAvailable -CommandName 'azd'
        Test-CommandAvailable -CommandName 'node'
        Test-CommandAvailable -CommandName 'npm'

        & az account show --only-show-errors --output none
        if ($LASTEXITCODE -ne 0) {
            throw 'Azure CLI is not authenticated. Run az login first.'
        }

        $maintainerTarget = Get-MaintainerDevTarget -Path $ProfilePath
        $environmentName = [string]$maintainerTarget.environmentName
        if ($Current) {
            $targetMode = 'Current'
        }
        elseif ($Release) {
            $targetMode = 'Release'
        }
        else {
            throw 'Select either -Current or -Release.'
        }
        $containerAppName = Get-BranchContainerAppName -TargetMode $targetMode

        $resourceGroupName = Get-AzdEnvironmentValue -EnvironmentName $environmentName -Name 'resourceGroupName'
        if ([string]::IsNullOrWhiteSpace($resourceGroupName)) {
            throw "azd environment '$environmentName' does not define resourceGroupName."
        }

        $clientId = Get-AzdEnvironmentValue -EnvironmentName $environmentName -Name 'APP_CLIENT_ID'
        if ([string]::IsNullOrWhiteSpace($clientId)) {
            throw "azd environment '$environmentName' does not define APP_CLIENT_ID."
        }

        $tenantId = Get-AzdEnvironmentValue -EnvironmentName $environmentName -Name 'AZURE_TENANT_ID'
        if ([string]::IsNullOrWhiteSpace($tenantId)) {
            $tenantId = Get-CurrentAzureValue -Arguments @('account', 'show', '--query', 'tenantId')
        }
        if ([string]::IsNullOrWhiteSpace($tenantId)) {
            throw "Unable to resolve the Azure tenant for azd environment '$environmentName'."
        }

        $subscriptionId = Get-AzdEnvironmentValue -EnvironmentName $environmentName -Name 'AZURE_SUBSCRIPTION_ID'
        if ([string]::IsNullOrWhiteSpace($subscriptionId)) {
            $subscriptionId = Get-CurrentAzureValue -Arguments @('account', 'show', '--query', 'id')
        }
        if ([string]::IsNullOrWhiteSpace($subscriptionId)) {
            throw "Unable to resolve the Azure subscription for azd environment '$environmentName'."
        }

        Write-Host "Environment     : $environmentName" -ForegroundColor Cyan
        Write-Host "Branch          : $((& git branch --show-current 2>$null | Out-String).Trim())" -ForegroundColor Cyan
        Write-Host "Resource group  : $resourceGroupName" -ForegroundColor Cyan
        Write-Host "Container App   : $containerAppName" -ForegroundColor Cyan

        $target = Get-HostedTarget `
            -ResourceGroupName $resourceGroupName `
            -ContainerAppName $containerAppName `
            -SubscriptionId $subscriptionId
        Write-Host "Target URL      : $($target.BaseUrl)" -ForegroundColor Green

        Wait-ForHostedApp -BaseUrl $target.BaseUrl

        Write-Host 'Acquiring API access token...' -ForegroundColor Cyan
        $token = & az account get-access-token `
            --tenant $tenantId `
            --scope "api://$clientId/.default" `
            --query accessToken `
            --only-show-errors `
            --output tsv 2>$null
        if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($token)) {
            throw "Unable to acquire an access token for api://$clientId/.default."
        }

        $uiDirectory = Join-Path $PSScriptRoot '..' 'Eklee.KeyVault.UI'
        if (-not (Test-Path -Path $uiDirectory -PathType Container)) {
            throw "UI directory was not found: $uiDirectory"
        }

        if (-not $NoDeps) {
            Write-Host 'Installing UI dependencies...' -ForegroundColor Cyan
            Push-Location $uiDirectory
            try {
                npm ci --silent
                if ($LASTEXITCODE -ne 0) {
                    throw 'npm ci failed.'
                }

                npx playwright install chromium
                if ($LASTEXITCODE -ne 0) {
                    throw 'Playwright browser installation failed.'
                }
            }
            finally {
                Pop-Location
            }
        }

        $env:E2E_BASE_URL = $target.BaseUrl
        $env:E2E_CLIENT_ID = $clientId
        $env:E2E_TENANT_ID = $tenantId
        $env:E2E_ACCESS_TOKEN = ($token | Out-String).Trim()

        $playwrightArguments = @('playwright', 'test', $Filter)
        if ($Headed) {
            $playwrightArguments += '--headed'
        }

        Write-Host "Running Playwright test: $Filter" -ForegroundColor Yellow
        Push-Location $uiDirectory
        try {
            & npx @playwrightArguments
            $testExitCode = $LASTEXITCODE
        }
        finally {
            Pop-Location
        }
    }
    catch {
        Write-Error -ErrorAction Continue "Invoke-HostedE2E failed: $($_.Exception.Message)"
        $testExitCode = 1
    }
    finally {
        foreach ($environmentVariable in $environmentVariables) {
            Remove-Item "Env:\$environmentVariable" -ErrorAction SilentlyContinue
        }
    }

    exit $testExitCode
}
#endregion Main Execution