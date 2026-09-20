#!/usr/bin/env pwsh
# Copyright (c) 2026 Microsoft Corporation. All rights reserved.
# SPDX-License-Identifier: MIT
#Requires -Version 7.4

<#
.SYNOPSIS
    Runs Playwright E2E tests against a deployed Container App.

.DESCRIPTION
    Updates the permanent maintainer branch Container App with the immutable
    image published for the checked-out feature or bugfix commit, waits for its
    configured HTTPS URL to become healthy, and runs local Playwright tests.

.PARAMETER Current
    Updates and tests the permanent branch Container App from the checked-out
    non-main, non-release branch.

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

.NOTES
    Requires Azure CLI, Azure Developer CLI, Node.js, npm, and an authenticated
    Azure CLI identity with access to the deployed API.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [switch]$Current,

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

    foreach ($propertyName in @(
            'environmentName', 'subscriptionId', 'customBranchDomainName', 'approvedGitHubRepository'
        )) {
        $property = $target.PSObject.Properties[$propertyName]
        if ($null -eq $property -or [string]::IsNullOrWhiteSpace([string]$property.Value)) {
            throw "Maintainer profile '$Path' requires a non-empty '$propertyName' property. Run Setup-Dev.ps1 before hosted E2E."
        }
    }

    return $target
}

function Get-BranchDeploymentIdentity {
    [CmdletBinding()]
    [OutputType([psobject])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidatePattern('^[^/\s]+/[^/\s]+$')]
        [string]$ApprovedGitHubRepository
    )

    $branchName = (& git branch --show-current 2>$null | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($branchName)) {
        throw 'Unable to determine the current Git branch. Check out a branch before running hosted E2E.'
    }

    if ($branchName -eq 'main' -or $branchName -like 'release/*') {
        throw "Hosted E2E only updates the permanent branch target. Check out a non-main, non-release branch instead of '$branchName'."
    }

    $commitSha = (& git rev-parse HEAD 2>$null | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or $commitSha -notmatch '^[a-fA-F0-9]{40}$') {
        throw 'Unable to resolve the current 40-character Git commit SHA.'
    }

    $originUrl = (& git remote get-url origin 2>$null | Out-String).Trim()
    if ($LASTEXITCODE -ne 0) {
        throw 'Unable to resolve the Git origin remote.'
    }

    $originMatch = [regex]::Match(
        $originUrl,
        '^(?:https://|ssh://git@|git@)github\.com(?::|/)(?<owner>[^/\s]+)/(?<repository>[^/\s]+?)(?:\.git)?/?$'
    )
    if (-not $originMatch.Success) {
        throw "Git remote '$originUrl' is not a supported GitHub origin URL."
    }

    $repository = "$($originMatch.Groups['owner'].Value)/$($originMatch.Groups['repository'].Value)"
    if (-not [string]::Equals($repository, $ApprovedGitHubRepository, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Git origin '$repository' does not match the maintainer-approved repository '$ApprovedGitHubRepository'."
    }

    return [pscustomobject]@{
        BranchName = $branchName
        CommitSha  = $commitSha.ToLowerInvariant()
        Repository = $repository
    }
}

function Get-ImmutableGitHubContainerImage {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidatePattern('^[^/\s]+/[^/\s]+$')]
        [string]$GitHubRepository,

        [Parameter(Mandatory = $true)]
        [ValidatePattern('^[a-f0-9]{40}$')]
        [string]$CommitSha
    )

    $resolvedRepository = (& gh api "repos/$GitHubRepository" --jq '.full_name' 2>$null | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or -not [string]::Equals($resolvedRepository, $GitHubRepository, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Unable to verify the approved GitHub repository '$GitHubRepository'."
    }

    $resolvedCommit = (& gh api "repos/$GitHubRepository/commits/$CommitSha" --jq '.sha' 2>$null | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or -not [string]::Equals($resolvedCommit, $CommitSha, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Commit '$CommitSha' is not available in approved GitHub repository '$GitHubRepository'."
    }

    $imageTag = "ghcr.io/$($GitHubRepository.ToLowerInvariant()):sha-$CommitSha"
    $digest = (& docker buildx imagetools inspect $imageTag --format '{{.Digest}}' 2>$null | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or $digest -notmatch '^sha256:[a-f0-9]{64}$') {
        throw "No immutable GHCR image digest was found for '$imageTag'. Wait for CI to publish this commit."
    }

    return "ghcr.io/$($GitHubRepository.ToLowerInvariant())@$digest"
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
        [string]$SubscriptionId,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$ExpectedBaseUrl
    )

    $containerApp = & az containerapp show `
        --name $ContainerAppName `
        --resource-group $ResourceGroupName `
        --subscription $SubscriptionId `
        --only-show-errors `
        --output json 2>$null | ConvertFrom-Json
    if ($LASTEXITCODE -ne 0 -or $null -eq $containerApp) {
        throw "Unable to resolve Container App '$ContainerAppName' in resource group '$ResourceGroupName'."
    }

    $parsedUri = $null
    if (-not [System.Uri]::TryCreate($ExpectedBaseUrl, [System.UriKind]::Absolute, [ref]$parsedUri) -or $parsedUri.Scheme -ne 'https') {
        throw "Configured branch target URL '$ExpectedBaseUrl' is not an HTTPS URL."
    }

    $customDomainNames = @($containerApp.properties.configuration.ingress.customDomains | ForEach-Object { [string]$_.name })
    if ($customDomainNames -notcontains $parsedUri.Host) {
        throw "Container App '$ContainerAppName' does not include configured custom domain '$($parsedUri.Host)'. Run Setup-Dev.ps1 to reconcile permanent target domains."
    }

    return [pscustomobject]@{
        BaseUrl = $parsedUri.AbsoluteUri.TrimEnd('/')
        Fqdn    = $parsedUri.Host
    }
}

function Get-BranchRuntimeConfiguration {
    [CmdletBinding()]
    [OutputType([psobject])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$ResourceGroupName,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$SubscriptionId
    )

    $identityClientId = Get-CurrentAzureValue -Arguments @('identity', 'list', '--resource-group', $ResourceGroupName, '--subscription', $SubscriptionId, '--query', '[0].clientId')
    $keyVaultUri = Get-CurrentAzureValue -Arguments @('keyvault', 'list', '--resource-group', $ResourceGroupName, '--subscription', $SubscriptionId, '--query', '[0].properties.vaultUri')
    $storageBlobUri = Get-CurrentAzureValue -Arguments @('storage', 'account', 'list', '--resource-group', $ResourceGroupName, '--subscription', $SubscriptionId, '--query', '[0].primaryEndpoints.blob')
    if ([string]::IsNullOrWhiteSpace($identityClientId) -or
        [string]::IsNullOrWhiteSpace($keyVaultUri) -or
        [string]::IsNullOrWhiteSpace($storageBlobUri)) {
        throw "Unable to resolve complete branch runtime configuration in resource group '$ResourceGroupName'."
    }

    return [pscustomobject]@{
        IdentityClientId = $identityClientId
        KeyVaultUri      = $keyVaultUri
        StorageBlobUri   = $storageBlobUri
    }
}

function Update-BranchContainerApp {
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ResourceGroupName,

        [Parameter(Mandatory = $true)]
        [string]$SubscriptionId,

        [Parameter(Mandatory = $true)]
        [string]$ContainerAppName,

        [Parameter(Mandatory = $true)]
        [string]$Image,

        [Parameter(Mandatory = $true)]
        [string]$BaseUrl,

        [Parameter(Mandatory = $true)]
        [string]$TenantId,

        [Parameter(Mandatory = $true)]
        [string]$ClientId,

        [Parameter(Mandatory = $true)]
        [psobject]$RuntimeConfiguration
    )

    & az containerapp update `
        --name $ContainerAppName `
        --resource-group $ResourceGroupName `
        --subscription $SubscriptionId `
        --image $Image `
        --min-replicas 1 `
        --max-replicas 1 `
        --set-env-vars `
        "AZURE_CLIENT_ID=$($RuntimeConfiguration.IdentityClientId)" `
        "StorageUri=$($RuntimeConfiguration.StorageBlobUri)" `
        'StorageContainerName=configs' `
        "KeyVaultUri=$($RuntimeConfiguration.KeyVaultUri)" `
        'AuthenticationMode=mi' `
        'AzureAd__Instance=https://login.microsoftonline.com/' `
        "AzureAd__TenantId=$TenantId" `
        "AzureAd__ClientId=$ClientId" `
        "AzureAd__Audience=api://$ClientId" `
        "VITE_AZURE_AD_CLIENT_ID=$ClientId" `
        "VITE_AZURE_AD_AUTHORITY=https://login.microsoftonline.com/$TenantId" `
        "VITE_AZURE_AD_REDIRECT_URI=$BaseUrl" `
        "VITE_API_BASE_URL=$BaseUrl" `
        --only-show-errors
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to update permanent branch Container App '$ContainerAppName'."
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
        if (-not $Current) {
            throw 'Supply -Current to update and test the permanent branch target.'
        }

        Test-CommandAvailable -CommandName 'az'
        Test-CommandAvailable -CommandName 'azd'
        Test-CommandAvailable -CommandName 'docker'
        Test-CommandAvailable -CommandName 'gh'
        Test-CommandAvailable -CommandName 'git'
        Test-CommandAvailable -CommandName 'node'
        Test-CommandAvailable -CommandName 'npm'

        & az account show --only-show-errors --output none
        if ($LASTEXITCODE -ne 0) {
            throw 'Azure CLI is not authenticated. Run az login first.'
        }

        $maintainerTarget = Get-MaintainerDevTarget -Path $ProfilePath
        $environmentName = [string]$maintainerTarget.environmentName
        $branchIdentity = Get-BranchDeploymentIdentity -ApprovedGitHubRepository ([string]$maintainerTarget.approvedGitHubRepository)

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
            throw "Unable to resolve the Azure tenant for azd environment '$environmentName'."
        }

        $subscriptionId = Get-AzdEnvironmentValue -EnvironmentName $environmentName -Name 'AZURE_SUBSCRIPTION_ID'
        if ([string]::IsNullOrWhiteSpace($subscriptionId)) {
            throw "Unable to resolve the Azure subscription for azd environment '$environmentName'."
        }
        if (-not [string]::Equals($subscriptionId, [string]$maintainerTarget.subscriptionId, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "azd environment '$environmentName' subscription '$subscriptionId' does not match the maintainer profile subscription."
        }

        $activeSubscriptionId = Get-CurrentAzureValue -Arguments @('account', 'show', '--query', 'id')
        if (-not [string]::Equals($activeSubscriptionId, $subscriptionId, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "Azure CLI is using subscription '$activeSubscriptionId', not maintainer subscription '$subscriptionId'."
        }

        $containerAppName = Get-AzdEnvironmentValue -EnvironmentName $environmentName -Name 'branchContainerAppName'
        $branchBaseUrl = Get-AzdEnvironmentValue -EnvironmentName $environmentName -Name 'branchContainerAppUrl'
        if ([string]::IsNullOrWhiteSpace($containerAppName) -or [string]::IsNullOrWhiteSpace($branchBaseUrl)) {
            throw "azd environment '$environmentName' does not define the permanent branch target. Run Setup-Dev.ps1 first."
        }

        $branchUri = $null
        if (-not [System.Uri]::TryCreate($branchBaseUrl, [System.UriKind]::Absolute, [ref]$branchUri) -or
            $branchUri.Scheme -ne 'https' -or
            -not [string]::Equals($branchUri.Host, [string]$maintainerTarget.customBranchDomainName, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "azd branch target URL '$branchBaseUrl' does not match configured HTTPS branch domain '$($maintainerTarget.customBranchDomainName)'."
        }

        $image = Get-ImmutableGitHubContainerImage `
            -GitHubRepository $branchIdentity.Repository `
            -CommitSha $branchIdentity.CommitSha

        Write-Host "Environment     : $environmentName" -ForegroundColor Cyan
        Write-Host "Branch          : $($branchIdentity.BranchName)" -ForegroundColor Cyan
        Write-Host "Commit          : $($branchIdentity.CommitSha)" -ForegroundColor Cyan
        Write-Host "Resource group  : $resourceGroupName" -ForegroundColor Cyan
        Write-Host "Container App   : $containerAppName" -ForegroundColor Cyan

        $target = Get-HostedTarget `
            -ResourceGroupName $resourceGroupName `
            -ContainerAppName $containerAppName `
            -SubscriptionId $subscriptionId `
            -ExpectedBaseUrl $branchBaseUrl
        Write-Host "Target URL      : $($target.BaseUrl)" -ForegroundColor Green

        $runtimeConfiguration = Get-BranchRuntimeConfiguration `
            -ResourceGroupName $resourceGroupName `
            -SubscriptionId $subscriptionId
        Update-BranchContainerApp `
            -ResourceGroupName $resourceGroupName `
            -SubscriptionId $subscriptionId `
            -ContainerAppName $containerAppName `
            -Image $image `
            -BaseUrl $target.BaseUrl `
            -TenantId $tenantId `
            -ClientId $clientId `
            -RuntimeConfiguration $runtimeConfiguration

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