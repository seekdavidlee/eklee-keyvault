<#
.SYNOPSIS
    Creates or reuses an Azure AD app registration for azd deployments and
    stores the clientId and tenantId in the current azd environment.

.DESCRIPTION
    1. Reads the 'prefix' parameter from the current azd environment config.
    2. Looks up an existing app registration named '<prefix>-app'.
    3. If none exists, creates one with an Application ID URI, an
       'access_as_user' scope, pre-authorizes the Azure CLI, and configures
       the SPA redirect URI for localhost development.
    4. If the app registration already exists, skips all configuration.
    5. Stores clientId and tenantId in the azd environment so 'azd up' does
       not prompt for them.

.PARAMETER Prefix
    The resource naming prefix. When omitted, the script reads it from the
    current azd environment config (infra.parameters.prefix).

.NOTES
    Requires: Azure CLI (az) logged in with permissions to create app registrations.
    Requires: Azure Developer CLI (azd) with an active environment.

.EXAMPLE
    .\setup-azd-app-registration.ps1

    Uses the prefix from the current azd environment.

.EXAMPLE
    .\setup-azd-app-registration.ps1 -Prefix "dleemskv"

    Explicitly sets the prefix and app name to 'dleemskv-app'.
#>

param(
    [Parameter(Mandatory = $false)]
    [string]$Prefix
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ---------------------------------------------------------------------------
# Resolve prefix from azd environment if not provided
# ---------------------------------------------------------------------------
if (-not $Prefix) {
    Write-Host "Reading prefix from azd environment config..." -ForegroundColor Cyan
    $rawPrefix = azd env config get infra.parameters.prefix 2>$null
    $Prefix = ($rawPrefix | Out-String).Trim().Trim('"')
    if ($LASTEXITCODE -ne 0 -or -not $Prefix) {
        Write-Error "No 'prefix' found in azd environment config. Pass -Prefix explicitly or run 'azd env config set infra.parameters.prefix <value>' first."
        exit 1
    }
}

# ---------------------------------------------------------------------------
# Sync AZURE_LOCATION from the location infrastructure parameter
# azd prompts for location as an infra param; copy it to AZURE_LOCATION
# which is required for the ARM deployment metadata on subscription-scoped
# deployments.
# ---------------------------------------------------------------------------
$locationOutput = azd env get-value AZURE_LOCATION 2>&1
$currentLocation = $null
if ($LASTEXITCODE -eq 0 -and $locationOutput -notmatch 'ERROR') {
    $currentLocation = ($locationOutput | Out-String).Trim()
}
if (-not $currentLocation) {
    $rawLocation = (azd env config get infra.parameters.location 2>$null | Out-String).Trim().Trim('"')
    if ($rawLocation) {
        azd env set AZURE_LOCATION $rawLocation 2>$null
        azd env config set infra.parameters.location $rawLocation 2>$null
        Write-Host "AZURE_LOCATION set to '$rawLocation' from infra parameter." -ForegroundColor Green
    }
    else {
        $locationFromEnv = ($env:AZURE_LOCATION | Out-String).Trim().Trim('"')
        if ($locationFromEnv) {
            azd env set AZURE_LOCATION $locationFromEnv 2>$null
            azd env config set infra.parameters.location $locationFromEnv 2>$null
            Write-Host "AZURE_LOCATION set to '$locationFromEnv' from process environment." -ForegroundColor Green
        }
        else {
            Write-Host "No Azure location found in current azd environment." -ForegroundColor Yellow
            $promptLocation = (Read-Host "Enter Azure location (for example: centralus)")
            $promptLocation = ($promptLocation | Out-String).Trim().Trim('"')
            if (-not $promptLocation) {
                Write-Error "Could not determine Azure location. Set AZURE_LOCATION or infra.parameters.location and retry."
                exit 1
            }

            azd env set AZURE_LOCATION $promptLocation 2>$null
            azd env config set infra.parameters.location $promptLocation 2>$null
            Write-Host "AZURE_LOCATION set to '$promptLocation' from interactive input." -ForegroundColor Green
        }
    }
}
else {
    Write-Host "AZURE_LOCATION is '$currentLocation'." -ForegroundColor Green
}

$AppName = "$Prefix-app"
Write-Host "App registration name: $AppName" -ForegroundColor Cyan

# ---------------------------------------------------------------------------
# Verify Azure CLI login
# ---------------------------------------------------------------------------
Write-Host "Checking Azure CLI login status..." -ForegroundColor Cyan
$account = az account show --output json 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Error "Azure CLI is not logged in. Run 'az login' first."
    exit 1
}

$accountInfo = $account | Out-String | ConvertFrom-Json
$tenantId = $accountInfo.tenantId
Write-Host "Logged in to tenant: $tenantId" -ForegroundColor Green

# ---------------------------------------------------------------------------
# Look up existing app registration
# ---------------------------------------------------------------------------
Write-Host "Looking up app registration '$AppName'..." -ForegroundColor Cyan
$existingApps = @(az ad app list --display-name $AppName --output json | ConvertFrom-Json)

$app = $null
if ($existingApps.Count -gt 0) {
    $app = $existingApps | Where-Object { $_.displayName -eq $AppName } | Select-Object -First 1
}

if ($app) {
    $clientId = $app.appId
    Write-Host "Found existing app registration '$AppName' (ClientId: $clientId). Skipping configuration." -ForegroundColor Green
}
else {
    Write-Host "App registration '$AppName' not found. Creating..." -ForegroundColor Yellow

    # Create the app registration
    $app = az ad app create `
        --display-name $AppName `
        --sign-in-audience AzureADMyOrg `
        --output json | ConvertFrom-Json

    $clientId = $app.appId
    $objectId = $app.id
    Write-Host "Created app registration (ClientId: $clientId)" -ForegroundColor Green

    # Set Application ID URI
    $identifierUri = "api://$clientId"
    Write-Host "Setting Application ID URI to '$identifierUri'..." -ForegroundColor Cyan
    az ad app update --id $clientId --identifier-uris $identifierUri --output none

    # Expose an API scope (access_as_user)
    $scopeId = [guid]::NewGuid().ToString()
    $body = @{
        api = @{
            oauth2PermissionScopes = @(
                @{
                    adminConsentDescription = "Allow the application to access $AppName on behalf of the signed-in user."
                    adminConsentDisplayName = "Access $AppName"
                    id                      = $scopeId
                    isEnabled               = $true
                    type                    = "User"
                    userConsentDescription  = "Allow the application to access $AppName on your behalf."
                    userConsentDisplayName  = "Access $AppName"
                    value                   = "access_as_user"
                }
            )
        }
    } | ConvertTo-Json -Depth 5

    $tempFile = Join-Path $env:TEMP "app-update-$([guid]::NewGuid()).json"
    try {
        $body | Out-File -FilePath $tempFile -Encoding utf8
        az rest --method PATCH `
            --url "https://graph.microsoft.com/v1.0/applications/$objectId" `
            --body "@$tempFile" `
            --headers "Content-Type=application/json" `
            --output none
    }
    finally {
        Remove-Item $tempFile -ErrorAction SilentlyContinue
    }
    Write-Host "Exposed API scope 'access_as_user'" -ForegroundColor Green

    # Pre-authorize the Azure CLI for the scope
    $azureCliAppId = "04b07795-8ddb-461a-bbee-02f9e1bf7b46"
    Write-Host "Pre-authorizing Azure CLI ($azureCliAppId) for scope 'access_as_user'..." -ForegroundColor Cyan

    $preAuthBody = @{
        api = @{
            preAuthorizedApplications = @(
                @{
                    appId                  = $azureCliAppId
                    delegatedPermissionIds = @($scopeId)
                }
            )
        }
    } | ConvertTo-Json -Depth 5

    $tempFile2 = Join-Path $env:TEMP "app-preauth-$([guid]::NewGuid()).json"
    try {
        $preAuthBody | Out-File -FilePath $tempFile2 -Encoding utf8
        az rest --method PATCH `
            --url "https://graph.microsoft.com/v1.0/applications/$objectId" `
            --body "@$tempFile2" `
            --headers "Content-Type=application/json" `
            --output none
    }
    finally {
        Remove-Item $tempFile2 -ErrorAction SilentlyContinue
    }
    Write-Host "Azure CLI pre-authorized successfully." -ForegroundColor Green

    # Configure SPA redirect URI for local development
    Write-Host "Configuring SPA redirect URI for localhost..." -ForegroundColor Cyan
    $spaBody = @{
        spa = @{
            redirectUris = @("http://localhost:5173")
        }
    } | ConvertTo-Json -Depth 5

    $tempFile3 = Join-Path $env:TEMP "app-spa-$([guid]::NewGuid()).json"
    try {
        $spaBody | Out-File -FilePath $tempFile3 -Encoding utf8
        az rest --method PATCH `
            --url "https://graph.microsoft.com/v1.0/applications/$objectId" `
            --body "@$tempFile3" `
            --headers "Content-Type=application/json" `
            --output none
    }
    finally {
        Remove-Item $tempFile3 -ErrorAction SilentlyContinue
    }
    Write-Host "SPA redirect URI configured." -ForegroundColor Green
}

# ---------------------------------------------------------------------------
# Store clientId and tenantId in azd environment
# ---------------------------------------------------------------------------
Write-Host "Storing clientId and tenantId in azd environment..." -ForegroundColor Cyan

# Set as azd environment values (referenced by azd.parameters.json)
azd env set APP_CLIENT_ID $clientId
if ($LASTEXITCODE -ne 0) {
    Write-Error "Failed to set APP_CLIENT_ID in azd environment."
    exit 1
}

# Also store as infra parameters for backwards compatibility
azd env config set infra.parameters.clientId $clientId
if ($LASTEXITCODE -ne 0) {
    Write-Error "Failed to set clientId in azd environment."
    exit 1
}

azd env config set infra.parameters.tenantId $tenantId
if ($LASTEXITCODE -ne 0) {
    Write-Error "Failed to set tenantId in azd environment."
    exit 1
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "=== azd Environment Updated ===" -ForegroundColor Cyan
Write-Host "  App Name   : $AppName"
Write-Host "  Tenant ID  : $tenantId"
Write-Host "  Client ID  : $clientId"
Write-Host "  Audience   : api://$clientId"
Write-Host ""
Write-Host "Run 'azd up' to provision and deploy." -ForegroundColor Green
Write-Host "Post-deploy hook will update SPA redirect URIs using the deployed Container App URL." -ForegroundColor Green
Write-Host ""
