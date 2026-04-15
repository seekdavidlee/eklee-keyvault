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

    $lines = ($CommandOutput | Out-String) -split "`r?`n"
    $candidateLines = @(
        $lines |
            ForEach-Object { $_.Trim() } |
            Where-Object { $_ -and $_ -notmatch '^(WARNING:|To update to the latest version, run:|choco upgrade azd$)' }
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
# Read required values from the azd environment
# ---------------------------------------------------------------------------

$customDomain = Get-AzdEnvValue -Name "CUSTOM_DOMAIN_NAME"
if (-not $customDomain) {
    Write-Host "CUSTOM_DOMAIN_NAME is not set in the azd environment. Skipping custom domain setup." -ForegroundColor Yellow
    exit 0
}

$containerAppName = Get-AzdEnvValue -Name "containerAppName"
if (-not $containerAppName) {
    Write-Error "Missing containerAppName in azd environment."
    exit 1
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

Write-Host "Applying custom domain '$customDomain' to Container App '$containerAppName'..." -ForegroundColor Cyan
Write-Host "  Resource Group : $resourceGroupName" -ForegroundColor Cyan
Write-Host "  Subscription   : $subscriptionId" -ForegroundColor Cyan

# ---------------------------------------------------------------------------
# Step 1: Add the custom hostname (idempotent — ignores if already present)
# ---------------------------------------------------------------------------

Write-Host "Adding hostname '$customDomain' to the Container App..." -ForegroundColor Cyan
$output = az containerapp hostname add `
    --name $containerAppName `
    --resource-group $resourceGroupName `
    --subscription $subscriptionId `
    --hostname $customDomain `
    --output none 2>&1 | Out-String

if ($LASTEXITCODE -ne 0) {
    if ($output -match "already exists|HostnameAlreadyExists") {
        Write-Host "Hostname '$customDomain' is already added." -ForegroundColor Green
    }
    else {
        Write-Error "Failed to add hostname: $output"
        exit 1
    }
}

# ---------------------------------------------------------------------------
# Step 2: Bind managed certificate to the hostname
# ---------------------------------------------------------------------------

Write-Host "Binding managed certificate for '$customDomain'..." -ForegroundColor Cyan
$output = az containerapp hostname bind `
    --name $containerAppName `
    --resource-group $resourceGroupName `
    --subscription $subscriptionId `
    --hostname $customDomain `
    --environment $containerAppEnvName `
    --validation-method CNAME `
    --output none 2>&1 | Out-String

if ($LASTEXITCODE -ne 0) {
    if ($output -match "already bound|already has a binding") {
        Write-Host "Certificate is already bound for '$customDomain'." -ForegroundColor Green
    }
    else {
        Write-Error "Failed to bind certificate: $output"
        exit 1
    }
}

# ---------------------------------------------------------------------------
# Step 3: Update Container App env vars to use the custom domain
# ---------------------------------------------------------------------------

$customDomainUrl = "https://$customDomain"

Write-Host "Updating Container App environment variables to use '$customDomainUrl'..." -ForegroundColor Cyan
az containerapp update `
    --name $containerAppName `
    --resource-group $resourceGroupName `
    --subscription $subscriptionId `
    --set-env-vars `
        "VITE_AZURE_AD_REDIRECT_URI=$customDomainUrl" `
        "VITE_API_BASE_URL=$customDomainUrl" `
    --output none

if ($LASTEXITCODE -ne 0) {
    Write-Error "Failed to update Container App environment variables."
    exit 1
}

Write-Host "Custom domain '$customDomain' applied successfully." -ForegroundColor Green
Write-Host "App URL: $customDomainUrl" -ForegroundColor Green
