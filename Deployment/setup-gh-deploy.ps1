#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Creates an Azure AD app registration with federated credentials for GitHub Actions deployment.

.DESCRIPTION
    This script creates (or reuses) an app registration named 'eklee-azkeyvault-viewer-gh-deploy'
    and configures federated credentials so GitHub Actions can authenticate to Azure using
    OpenID Connect (OIDC) without storing client secrets.

    The federated credential trusts the 'main' branch of the specified GitHub repository.

    Two resource groups are created: one for dev and one for prod, using the base
    ResourceGroupName with '-dev' and '-prod' suffixes. The Contributor role is assigned
    to the app registration's service principal on both resource groups.

    GitHub Actions environment-scoped variables are set per environment (dev/prod) for
    RESOURCE_GROUP, AZURE_TENANT_ID, AZURE_SUBSCRIPTION_ID, AZURE_CLIENT_ID, ACR_NAME,
    and ACR_RESOURCE_GROUP.

.PARAMETER GitHubOrganization
    The GitHub organization (or username) that owns the repository.

.PARAMETER GitHubRepoName
    The name of the GitHub repository.

.PARAMETER ResourceGroupName
    The base name of the Azure resource groups. Two resource groups will be created:
    '{ResourceGroupName}-dev' and '{ResourceGroupName}-prod'.

.PARAMETER Location
    The Azure region for the resource groups. Defaults to 'eastus2'.

.PARAMETER ContainerRegistryName
    The name of the Azure Container Registry (without .azurecr.io).

.PARAMETER ContainerRegistryResourceGroup
    The resource group where the Azure Container Registry is located.

.EXAMPLE
    .\setup-gh-deploy.ps1 -GitHubOrganization "seekdavidlee" -GitHubRepoName "eklee-keyvault" -ResourceGroupName "rg-eklee-keyvault" -ContainerRegistryName "myacr" -ContainerRegistryResourceGroup "rg-shared"

    Creates resource groups 'rg-eklee-keyvault-dev' and 'rg-eklee-keyvault-prod', assigns
    Contributor role on both, and sets GitHub environment variables accordingly.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$GitHubOrganization,

    [Parameter(Mandatory = $true)]
    [string]$GitHubRepoName,

    [Parameter(Mandatory = $true)]
    [string]$ResourceGroupName,

    [Parameter(Mandatory = $false)]
    [string]$Location = 'eastus2',

    [Parameter(Mandatory = $true)]
    [string]$ContainerRegistryName,

    [Parameter(Mandatory = $true)]
    [string]$ContainerRegistryResourceGroup
)

# ============================================================================
# Configuration
# ============================================================================

$ErrorActionPreference = 'Stop'
$InformationPreference = 'Continue'

$appRegistrationName = 'eklee-azkeyvault-viewer-gh-deploy'
$federatedCredentialName = 'github-actions-main-branch'

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

Write-Header "App Registration Setup for GitHub Actions Deployment"

# Verify Azure CLI is authenticated
Write-Step "Verifying Azure CLI authentication..."
$account = az account show --output json 2>$null | ConvertFrom-Json
if (-not $account) {
    Write-Error "Not logged in to Azure CLI. Run 'az login' first."
    exit 1
}
Write-Success "Authenticated as: $($account.user.name)"

$tenantId = $account.tenantId
$subscriptionId = $account.id

# ============================================================================
# Check if App Registration Already Exists
# ============================================================================

Write-Step "Checking if app registration '$appRegistrationName' already exists..."
$existingApp = az ad app list --display-name $appRegistrationName --output json | ConvertFrom-Json

if ($existingApp -and $existingApp.Count -gt 0) {
    $appId = $existingApp[0].appId
    $objectId = $existingApp[0].id
    Write-Success "App registration already exists (Client ID: $appId)"
}
else {
    # ============================================================================
    # Create App Registration
    # ============================================================================

    Write-Step "Creating app registration '$appRegistrationName'..."
    $newApp = az ad app create --display-name $appRegistrationName --output json | ConvertFrom-Json
    $appId = $newApp.appId
    $objectId = $newApp.id
    Write-Success "App registration created (Client ID: $appId)"

    # Create a service principal for the app registration
    Write-Step "Creating service principal..."
    az ad sp create --id $appId --output none
    Write-Success "Service principal created"
}

# ============================================================================
# Ensure Resource Groups Exist (dev and prod)
# ============================================================================

$environments = @(
    @{ Name = 'dev';  ResourceGroup = "${ResourceGroupName}-dev" }
    @{ Name = 'prod'; ResourceGroup = "${ResourceGroupName}-prod" }
)

foreach ($env in $environments) {
    $rgName = $env.ResourceGroup
    Write-Step "Checking if resource group '$rgName' exists..."
    $rgExists = az group exists --name $rgName --output tsv

    if ($rgExists -eq 'true') {
        Write-Success "Resource group '$rgName' already exists"
    }
    else {
        Write-Step "Creating resource group '$rgName' in '$Location'..."
        az group create --name $rgName --location $Location --output none
        if ($LASTEXITCODE -eq 0) {
            Write-Success "Resource group '$rgName' created in '$Location'"
        }
        else {
            Write-Error "Failed to create resource group '$rgName'"
            exit 1
        }
    }
}

# ============================================================================
# Assign Contributor Role to App Registration on Both Resource Groups
# ============================================================================

Write-Step "Retrieving service principal for app registration..."
$sp = az ad sp list --filter "appId eq '$appId'" --output json | ConvertFrom-Json

if (-not $sp -or $sp.Count -eq 0) {
    Write-Error "Service principal not found for Client ID '$appId'. Ensure the service principal was created."
    exit 1
}

$spObjectId = $sp[0].id

foreach ($env in $environments) {
    $rgName = $env.ResourceGroup
    $rgScope = "/subscriptions/$subscriptionId/resourceGroups/$rgName"

    Write-Step "Checking existing Contributor role assignment on '$rgName'..."
    $existingAssignment = az role assignment list `
        --assignee $spObjectId `
        --role "Contributor" `
        --scope $rgScope `
        --output json | ConvertFrom-Json

    if ($existingAssignment -and $existingAssignment.Count -gt 0) {
        Write-Success "Contributor role already assigned to service principal on '$rgName'"
    }
    else {
        Write-Step "Assigning Contributor role to service principal on '$rgName'..."
        az role assignment create `
            --assignee-object-id $spObjectId `
            --assignee-principal-type ServicePrincipal `
            --role "Contributor" `
            --scope $rgScope `
            --output none

        if ($LASTEXITCODE -eq 0) {
            Write-Success "Contributor role assigned to service principal on '$rgName'"
        }
        else {
            Write-Error "Failed to assign Contributor role on '$rgName'"
            exit 1
        }
    }
}

# ============================================================================
# Configure Federated Credential
# ============================================================================

Write-Step "Checking if federated credential '$federatedCredentialName' already exists..."
$existingCredentials = az ad app federated-credential list --id $objectId --output json | ConvertFrom-Json

$credentialExists = $false
if ($existingCredentials) {
    foreach ($cred in $existingCredentials) {
        if ($cred.name -eq $federatedCredentialName) {
            $credentialExists = $true
            break
        }
    }
}

if ($credentialExists) {
    Write-Success "Federated credential '$federatedCredentialName' already exists"
}
else {
    Write-Step "Creating federated credential for GitHub Actions..."

    $credentialBody = @{
        name        = $federatedCredentialName
        issuer      = "https://token.actions.githubusercontent.com"
        subject     = "repo:${GitHubOrganization}/${GitHubRepoName}:ref:refs/heads/main"
        description = "GitHub Actions deployment from main branch"
        audiences   = @("api://AzureADTokenExchange")
    } | ConvertTo-Json -Compress

    $credentialBody | az ad app federated-credential create --id $objectId --parameters "@-" --output none

    if ($LASTEXITCODE -eq 0) {
        Write-Success "Federated credential created for repo '${GitHubOrganization}/${GitHubRepoName}' (main branch)"
    }
    else {
        Write-Error "Failed to create federated credential"
        exit 1
    }
}

# ============================================================================
# Output Required Values
# ============================================================================

Write-Header "Setting GitHub Repository Variables"

$ghRepo = "${GitHubOrganization}/${GitHubRepoName}"

# Set per-environment GitHub Actions variables
foreach ($env in $environments) {
    $envName = $env.Name
    $rgName = $env.ResourceGroup

    $envVariables = @{
        RESOURCE_GROUP        = $rgName
        AZURE_TENANT_ID       = $tenantId
        AZURE_SUBSCRIPTION_ID = $subscriptionId
        AZURE_CLIENT_ID       = $appId
        ACR_NAME              = $ContainerRegistryName
        ACR_RESOURCE_GROUP    = $ContainerRegistryResourceGroup
    }

    foreach ($var in $envVariables.GetEnumerator()) {
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
Write-Success "All GitHub repository variables have been configured for $ghRepo"
Write-Host ""

# Output as structured object for programmatic use
$output = [PSCustomObject]@{
    TenantId       = $tenantId
    SubscriptionId = $subscriptionId
    ClientId       = $appId
}

Write-Output $output
