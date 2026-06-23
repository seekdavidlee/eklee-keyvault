#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Assigns AcrPush role to the GitHub deploy service principal and sets ACR GitHub variables.

.DESCRIPTION
    This script should be run AFTER the Bicep infrastructure deployment has created the
    Azure Container Registry. It discovers the ACR in each environment resource group,
    assigns the AcrPush role to the GitHub deploy app registration's service principal,
    and sets the ACR_NAME and ACR_LOGIN_SERVER GitHub Actions environment variables.

    Prerequisites:
    1. Run setup-gh-deploy.ps1 first (creates app registration and resource groups)
    2. Run Bicep deployment (creates ACR in each environment resource group)
    3. Run this script

.PARAMETER GitHubOrganization
    The GitHub organization (or username) that owns the repository.

.PARAMETER GitHubRepoName
    The name of the GitHub repository.

.PARAMETER ResourceGroupName
    The base name of the Azure resource groups. Expects resource groups with '-dev'
    and '-prod' suffixes to exist.

.EXAMPLE
    .\assign-gh-deploy-acr-rbac.ps1 -GitHubOrganization "seekdavidlee" -GitHubRepoName "eklee-keyvault" -ResourceGroupName "rg-eklee-keyvault"

    Discovers ACR in 'rg-eklee-keyvault-dev' and 'rg-eklee-keyvault-prod', assigns
    AcrPush to the deploy service principal, and sets GitHub environment variables.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$GitHubOrganization,

    [Parameter(Mandatory = $true)]
    [string]$GitHubRepoName,

    [Parameter(Mandatory = $true)]
    [string]$ResourceGroupName
)

# ============================================================================
# Configuration
# ============================================================================

$ErrorActionPreference = 'Stop'
$InformationPreference = 'Continue'

$appRegistrationName = 'eklee-azkeyvault-viewer-gh-deploy'

# ============================================================================
# Functions
# ============================================================================

function Write-Header {
    param([string]$Message)
    Write-Host "`n$('=' * 80)" -ForegroundColor Cyan
    Write-Host "  $Message" -ForegroundColor Cyan
    Write-Host "$('=' * 80)`n" -ForegroundColor Cyan
}

function Write-Step {
    param([string]$Message)
    Write-Host "  -> $Message" -ForegroundColor Yellow
}

function Write-Success {
    param([string]$Message)
    Write-Host "  [OK] $Message" -ForegroundColor Green
}

# ============================================================================
# Main Script
# ============================================================================

Write-Header "ACR RBAC & GitHub Variable Setup for Deploy Service Principal"

# Verify Azure CLI is authenticated
Write-Step "Verifying Azure CLI authentication..."
$account = az account show --output json 2>$null | ConvertFrom-Json
if (-not $account) {
    Write-Error "Not logged in to Azure CLI. Run 'az login' first."
    exit 1
}
Write-Success "Authenticated as: $($account.user.name)"

$subscriptionId = $account.id

# ============================================================================
# Lookup App Registration and Service Principal
# ============================================================================

Write-Step "Looking up app registration '$appRegistrationName'..."
$existingApp = az ad app list --display-name $appRegistrationName --output json | ConvertFrom-Json

if (-not $existingApp -or $existingApp.Count -eq 0) {
    Write-Error "App registration '$appRegistrationName' not found. Run setup-gh-deploy.ps1 first."
    exit 1
}

$appId = $existingApp[0].appId
Write-Success "Found app registration (Client ID: $appId)"

Write-Step "Retrieving service principal..."
$sp = az ad sp list --filter "appId eq '$appId'" --output json | ConvertFrom-Json

if (-not $sp -or $sp.Count -eq 0) {
    Write-Error "Service principal not found for Client ID '$appId'. Run setup-gh-deploy.ps1 first."
    exit 1
}

$spObjectId = $sp[0].id
Write-Success "Found service principal (Object ID: $spObjectId)"

# ============================================================================
# Assign AcrPush and Set GitHub Variables per Environment
# ============================================================================

$environments = @(
    @{ Name = 'dev';  ResourceGroup = "${ResourceGroupName}-dev" }
    @{ Name = 'prod'; ResourceGroup = "${ResourceGroupName}-prod" }
)

$ghRepo = "${GitHubOrganization}/${GitHubRepoName}"

foreach ($env in $environments) {
    $envName = $env.Name
    $rgName = $env.ResourceGroup

    Write-Header "Environment: $envName ($rgName)"

    # Discover ACR
    Write-Step "Discovering container registry in '$rgName'..."
    $registries = az acr list --resource-group $rgName --output json 2>$null | ConvertFrom-Json

    if (-not $registries -or $registries.Count -eq 0) {
        Write-Error "No container registry found in '$rgName'. Ensure Bicep deployment has completed."
        exit 1
    }

    $acrName = $registries[0].name
    $acrLoginServer = $registries[0].loginServer
    Write-Success "Found container registry: $acrName ($acrLoginServer)"

    # Assign AcrPush
    $acrScope = "/subscriptions/$subscriptionId/resourceGroups/$rgName/providers/Microsoft.ContainerRegistry/registries/$acrName"

    Write-Step "Checking existing AcrPush role assignment on '$acrName'..."
    $existingAcrAssignment = az role assignment list `
        --assignee $spObjectId `
        --role "AcrPush" `
        --scope $acrScope `
        --output json | ConvertFrom-Json

    if ($existingAcrAssignment -and $existingAcrAssignment.Count -gt 0) {
        Write-Success "AcrPush role already assigned to service principal on '$acrName'"
    }
    else {
        Write-Step "Assigning AcrPush role to service principal on '$acrName'..."
        az role assignment create `
            --assignee-object-id $spObjectId `
            --assignee-principal-type ServicePrincipal `
            --role "AcrPush" `
            --scope $acrScope `
            --output none

        if ($LASTEXITCODE -eq 0) {
            Write-Success "AcrPush role assigned to service principal on '$acrName'"
        }
        else {
            Write-Error "Failed to assign AcrPush role on '$acrName'"
            exit 1
        }
    }

    # Set GitHub environment variables for ACR
    $acrVariables = @{
        ACR_NAME         = $acrName
        ACR_LOGIN_SERVER = $acrLoginServer
    }

    foreach ($var in $acrVariables.GetEnumerator()) {
        Write-Step "Setting variable '$($var.Key)' = '$($var.Value)' for environment '$envName'..."
        $var.Value | gh variable set $var.Key --repo $ghRepo --env $envName
        if ($LASTEXITCODE -eq 0) {
            Write-Success "Variable '$($var.Key)' set for environment '$envName'"
        }
        else {
            Write-Error "Failed to set variable '$($var.Key)' for environment '$envName'"
            exit 1
        }
    }
}

Write-Host ""
Write-Success "ACR RBAC and GitHub variables configured for $ghRepo"
Write-Host ""
