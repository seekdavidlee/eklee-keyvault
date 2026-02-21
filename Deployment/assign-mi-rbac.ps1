#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Assigns RBAC roles to the managed identity for Eklee KeyVault infrastructure.

.DESCRIPTION
    This script assigns the necessary RBAC roles to the user-assigned managed identity
    by discovering resources directly from the specified resource group. It handles:
    - AcrPull role on Container Registry
    - Key Vault Secrets User role on Key Vault
    - Storage Blob Data Contributor role on Storage Account

.PARAMETER ResourceGroup
    The name of the Azure resource group containing the deployed infrastructure.

.PARAMETER ContainerRegistryResourceGroup
    The resource group containing the Azure Container Registry.

.EXAMPLE
    .\assign-rbac.ps1 -ResourceGroup eklee-keyvault-dev-rg -ContainerRegistryResourceGroup acr-rg

.EXAMPLE
    .\assign-rbac.ps1 -ResourceGroup eklee-keyvault-prod-rg
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ResourceGroup,

    [Parameter(Mandatory = $false)]
    [string]$ContainerRegistryResourceGroup
)

# ============================================================================
# Configuration
# ============================================================================

$ErrorActionPreference = 'Stop'
$InformationPreference = 'Continue'

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
    Write-Host "  ➜ $Message" -ForegroundColor Yellow
}

function Write-Success {
    param([string]$Message)
    Write-Host "  ✓ $Message" -ForegroundColor Green
}

function Write-Error {
    param([string]$Message)
    Write-Host "  ✗ $Message" -ForegroundColor Red
}

function Test-RoleAssignment {
    param(
        [string]$PrincipalId,
        [string]$RoleDefinitionName,
        [string]$Scope
    )
    
    try {
        $existing = az role assignment list `
            --assignee $PrincipalId `
            --role $RoleDefinitionName `
            --scope $Scope `
            --output json 2>$null | ConvertFrom-Json
        
        return $null -ne $existing -and $existing.Count -gt 0
    }
    catch {
        return $false
    }
}

function New-RoleAssignment {
    param(
        [string]$PrincipalId,
        [string]$RoleDefinitionName,
        [string]$Scope,
        [string]$Description
    )
    
    Write-Step "Assigning '$RoleDefinitionName' role..."
    
    if (Test-RoleAssignment -PrincipalId $PrincipalId -RoleDefinitionName $RoleDefinitionName -Scope $Scope) {
        Write-Success "Role already assigned: $RoleDefinitionName"
        return $true
    }
    
    try {
        az role assignment create `
            --assignee $PrincipalId `
            --role $RoleDefinitionName `
            --scope $Scope `
            --output none
        
        if ($LASTEXITCODE -eq 0) {
            Write-Success "Successfully assigned: $RoleDefinitionName"
            return $true
        }
        else {
            Write-Error "Failed to assign: $RoleDefinitionName"
            return $false
        }
    }
    catch {
        Write-Error "Exception assigning $RoleDefinitionName : $($_.Exception.Message)"
        return $false
    }
}

# ============================================================================
# Main Script
# ============================================================================

Write-Header "RBAC Role Assignment - Eklee KeyVault Infrastructure"

# Check if resource group exists
Write-Step "Checking resource group '$ResourceGroup'..."
$rgExists = az group exists --name $ResourceGroup
if ($rgExists -ne 'true') {
    Write-Error "Resource group '$ResourceGroup' does not exist"
    exit 1
}
Write-Success "Resource group exists"

# ============================================================================
# Discover Resources in Resource Group
# ============================================================================

Write-Header "Discovering Resources"

# Find the user-assigned managed identity
Write-Step "Looking up managed identity..."
$identities = az identity list `
    --resource-group $ResourceGroup `
    --output json | ConvertFrom-Json

if (-not $identities -or $identities.Count -eq 0) {
    Write-Error "No user-assigned managed identity found in resource group '$ResourceGroup'"
    exit 1
}
if ($identities.Count -gt 1) {
    Write-Error "Multiple managed identities found. Expected exactly one in resource group '$ResourceGroup'"
    exit 1
}

$managedIdentityName = $identities[0].name
$managedIdentityPrincipalId = $identities[0].principalId
$managedIdentityClientId = $identities[0].clientId
$managedIdentityId = $identities[0].id
Write-Success "Found managed identity: $managedIdentityName"

# Find the Key Vault
Write-Step "Looking up Key Vault..."
$keyVaults = az keyvault list `
    --resource-group $ResourceGroup `
    --output json | ConvertFrom-Json

if (-not $keyVaults -or $keyVaults.Count -eq 0) {
    Write-Error "No Key Vault found in resource group '$ResourceGroup'"
    exit 1
}
if ($keyVaults.Count -gt 1) {
    Write-Error "Multiple Key Vaults found. Expected exactly one in resource group '$ResourceGroup'"
    exit 1
}

$keyVaultName = $keyVaults[0].name
Write-Success "Found Key Vault: $keyVaultName"

# Find the Storage Account
Write-Step "Looking up Storage Account..."
$storageAccounts = az storage account list `
    --resource-group $ResourceGroup `
    --output json | ConvertFrom-Json

if (-not $storageAccounts -or $storageAccounts.Count -eq 0) {
    Write-Error "No Storage Account found in resource group '$ResourceGroup'"
    exit 1
}
if ($storageAccounts.Count -gt 1) {
    Write-Error "Multiple Storage Accounts found. Expected exactly one in resource group '$ResourceGroup'"
    exit 1
}

$storageAccountName = $storageAccounts[0].name
Write-Success "Found Storage Account: $storageAccountName"

Write-Information "`nManaged Identity Details:"
Write-Information "  Name:         $managedIdentityName"
Write-Information "  Principal ID: $managedIdentityPrincipalId"
Write-Information "  Client ID:    $managedIdentityClientId"
Write-Information "`nTarget Resources:"
Write-Information "  Key Vault:    $keyVaultName"
Write-Information "  Storage:      $storageAccountName"

# Get or prompt for Container Registry resource group
if (-not $ContainerRegistryResourceGroup) {
    Write-Information "`nContainer Registry resource group is required for ACR role assignment."
    $ContainerRegistryResourceGroup = Read-Host "Enter Container Registry resource group name"
}

# Find the Container Registry
Write-Step "Looking up Container Registry in resource group '$ContainerRegistryResourceGroup'..."
$registries = az acr list `
    --resource-group $ContainerRegistryResourceGroup `
    --output json | ConvertFrom-Json

if (-not $registries -or $registries.Count -eq 0) {
    Write-Error "No Container Registry found in resource group '$ContainerRegistryResourceGroup'"
    exit 1
}
if ($registries.Count -gt 1) {
    Write-Error "Multiple Container Registries found. Expected exactly one in resource group '$ContainerRegistryResourceGroup'"
    exit 1
}

$ContainerRegistryName = $registries[0].name
Write-Success "Found Container Registry: $ContainerRegistryName"

# Get current subscription
$subscription = az account show --output json | ConvertFrom-Json
$subscriptionId = $subscription.id

Write-Information "`nContainer Registry:"
Write-Information "  Name:         $ContainerRegistryName"
Write-Information "  Resource Group: $ContainerRegistryResourceGroup"

# Build resource scopes
$acrScope = "/subscriptions/$subscriptionId/resourceGroups/$ContainerRegistryResourceGroup/providers/Microsoft.ContainerRegistry/registries/$ContainerRegistryName"
$keyVaultScope = "/subscriptions/$subscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.KeyVault/vaults/$keyVaultName"
$storageScope = "/subscriptions/$subscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.Storage/storageAccounts/$storageAccountName"

# ============================================================================
# Assign RBAC Roles
# ============================================================================

Write-Header "Assigning RBAC Roles"

$successCount = 0
$totalRoles = 3

# 1. AcrPull on Container Registry
Write-Information "`n[1/3] Container Registry - AcrPull Role"
if (New-RoleAssignment `
    -PrincipalId $managedIdentityPrincipalId `
    -RoleDefinitionName "AcrPull" `
    -Scope $acrScope `
    -Description "Pull container images from Azure Container Registry") {
    $successCount++
}

# 2. Key Vault Secrets User on Key Vault
Write-Information "`n[2/3] Key Vault - Secrets User Role"
if (New-RoleAssignment `
    -PrincipalId $managedIdentityPrincipalId `
    -RoleDefinitionName "Key Vault Secrets User" `
    -Scope $keyVaultScope `
    -Description "Read secrets from Key Vault") {
    $successCount++
}

# 3. Storage Blob Data Contributor on Storage Account
Write-Information "`n[3/3] Storage Account - Blob Data Contributor Role"
if (New-RoleAssignment `
    -PrincipalId $managedIdentityPrincipalId `
    -RoleDefinitionName "Storage Blob Data Contributor" `
    -Scope $storageScope `
    -Description "Access blob storage data") {
    $successCount++
}

# ============================================================================
# Summary
# ============================================================================

Write-Header "Assignment Summary"

Write-Information "Total Roles:      $totalRoles"
Write-Information "Successful:       $successCount"
Write-Information "Failed:           $($totalRoles - $successCount)"

if ($successCount -eq $totalRoles) {
    Write-Success "`nAll role assignments completed successfully!"
    
    Write-Header "Verification"
    Write-Information "To verify the role assignments, run:"
    Write-Information "  az role assignment list --assignee $managedIdentityPrincipalId --output table"
    
    Write-Header "Next Steps"
    Write-Information "1. The managed identity is now ready to use"
    Write-Information "2. Deploy your Container App with this identity:"
    Write-Information "   --user-assigned $managedIdentityId"
    Write-Information "3. The Container App will have access to:"
    Write-Information "   - Pull images from Container Registry"
    Write-Information "   - Read secrets from Key Vault"
    Write-Information "   - Access blob storage data"
}
else {
    Write-Error "`nSome role assignments failed. Please review the errors above."
    Write-Information "`nYou may need to:"
    Write-Information "1. Ensure you have 'User Access Administrator' or 'Owner' role"
    Write-Information "2. Check if the resources exist and are accessible"
    Write-Information "3. Verify the managed identity exists: az identity show --name $managedIdentityName --resource-group $ResourceGroup"
    exit 1
}

Write-Host "`n"
