Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ============================================================================
# apply-custom-domain.ps1
# ============================================================================
# Postdeploy script that re-applies a custom domain (with managed certificate)
# to the Container App after each `azd up`. Skips if CUSTOM_DOMAIN_NAME is not
# set in the azd environment.
#
# Also updates the app registration redirect URIs and the Container App env
# vars (VITE_AZURE_AD_REDIRECT_URI, VITE_API_BASE_URL) to use the custom domain.
# ============================================================================

function Extract-AzdValue {
    param(
        [Parameter(Mandatory = $false)]
        [AllowNull()]
        [object]$CommandOutput
    )

    if (-not $CommandOutput) {
        return $null
    }

    $output = (($CommandOutput | Out-String) -split 'Update available:', 2)[0]
    $lines = $output -split "`r?`n"
    $candidateLines = @(
        $lines |
            ForEach-Object { $_.Trim() } |
            Where-Object { $_ -and $_ -notmatch '^WARNING:' }
    )

    if ($candidateLines.Count -eq 0) {
        return $null
    }

    return $candidateLines[-1].Trim('"')
}

function Get-AzdEnvValue {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    $value = azd env get-value $Name 2>&1
    $value = Extract-AzdValue -CommandOutput $value
    if ($LASTEXITCODE -ne 0 -or -not $value -or $value -match '^ERROR') {
        return $null
    }

    return $value
}

# ---------------------------------------------------------------------------
# Read target configuration from the azd environment
# ---------------------------------------------------------------------------

$permanentTargets = @(
    [pscustomobject]@{ DomainEnvironmentName = 'CUSTOM_DEV_DOMAIN_NAME'; ContainerAppEnvironmentName = 'devContainerAppName'; TargetName = 'main' }
    [pscustomobject]@{ DomainEnvironmentName = 'CUSTOM_RELEASE_DOMAIN_NAME'; ContainerAppEnvironmentName = 'releaseContainerAppName'; TargetName = 'release' }
    [pscustomobject]@{ DomainEnvironmentName = 'CUSTOM_BRANCH_DOMAIN_NAME'; ContainerAppEnvironmentName = 'branchContainerAppName'; TargetName = 'branch' }
)
$configuredTargets = @(
    foreach ($permanentTarget in $permanentTargets) {
        $customDomain = Get-AzdEnvValue -Name $permanentTarget.DomainEnvironmentName
        if ($customDomain) {
            [pscustomobject]@{
                CustomDomain = $customDomain
                ContainerAppName = Get-AzdEnvValue -Name $permanentTarget.ContainerAppEnvironmentName
                TargetName = $permanentTarget.TargetName
            }
        }
    }
)

if ($configuredTargets.Count -eq 0) {
    $legacyCustomDomain = Get-AzdEnvValue -Name 'CUSTOM_DOMAIN_NAME'
    if ($legacyCustomDomain) {
        $configuredTargets = @(
            [pscustomobject]@{
                CustomDomain = $legacyCustomDomain
                ContainerAppName = Get-AzdEnvValue -Name 'containerAppName'
                TargetName = 'legacy'
            }
        )
    }
}

if ($configuredTargets.Count -eq 0) {
    Write-Host "CUSTOM_DOMAIN_NAME is not set in the azd environment. Skipping custom domain setup." -ForegroundColor Yellow
    exit 0
}

$resourceGroupName = Get-AzdEnvValue -Name "resourceGroupName"
if (-not $resourceGroupName) {
    Write-Error "Missing resourceGroupName in azd environment."
    exit 1
}

$containerAppEnvName = Get-AzdEnvValue -Name "containerAppEnvironmentName"
if (-not $containerAppEnvName) {
    Write-Error "Missing containerAppEnvironmentName in azd environment."
    exit 1
}

$subscriptionId = Get-AzdEnvValue -Name "AZURE_SUBSCRIPTION_ID"
if (-not $subscriptionId) {
    Write-Error "Missing AZURE_SUBSCRIPTION_ID in azd environment."
    exit 1
}

Write-Host "  Resource Group : $resourceGroupName" -ForegroundColor Cyan
Write-Host "  Subscription   : $subscriptionId" -ForegroundColor Cyan

foreach ($configuredTarget in $configuredTargets) {
    $customDomain = $configuredTarget.CustomDomain
    $containerAppName = $configuredTarget.ContainerAppName
    if (-not $containerAppName) {
        Write-Error "Missing Container App name for target '$($configuredTarget.TargetName)' in the azd environment."
        exit 1
    }

    Write-Host "Applying custom domain '$customDomain' to Container App '$containerAppName'..." -ForegroundColor Cyan

    # Add hostname idempotently before binding its managed certificate.
    $output = az containerapp hostname add `
        --name $containerAppName `
        --resource-group $resourceGroupName `
        --subscription $subscriptionId `
        --hostname $customDomain `
        --output none 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0 -and $output -notmatch "already exists|HostnameAlreadyExists") {
        Write-Error "Failed to add hostname '$customDomain': $output"
        exit 1
    }

    $output = az containerapp hostname bind `
        --name $containerAppName `
        --resource-group $resourceGroupName `
        --subscription $subscriptionId `
        --hostname $customDomain `
        --environment $containerAppEnvName `
        --validation-method CNAME `
        --output none 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0 -and $output -notmatch "already bound|already has a binding") {
        Write-Error "Failed to bind managed certificate for '$customDomain': $output"
        exit 1
    }

    $customDomainUrl = "https://$customDomain"
    az containerapp update `
        --name $containerAppName `
        --resource-group $resourceGroupName `
        --subscription $subscriptionId `
        --container-name 'eklee-keyvault' `
        --set-env-vars `
            "VITE_AZURE_AD_REDIRECT_URI=$customDomainUrl" `
            "VITE_API_BASE_URL=$customDomainUrl" `
        --output none
    if ($LASTEXITCODE -ne 0) {
        Write-Error "Failed to update runtime URLs for target '$($configuredTarget.TargetName)'."
        exit 1
    }

    Write-Host "Custom domain '$customDomain' applied to '$($configuredTarget.TargetName)'." -ForegroundColor Green
}
