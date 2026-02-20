<#
.SYNOPSIS
    Looks up or creates the "eklee-azkeyvault-viewer" Azure AD app registration
    and updates appsettings.json with the AzureAd configuration.

.DESCRIPTION
    1. Checks for an existing app registration named "eklee-azkeyvault-viewer".
    2. If it does not exist, creates one with an Application ID URI (api://<clientId>)
       to protect the API.
    3. Updates the local appsettings.json AzureAd section with Instance, TenantId,
       ClientId, and Audience.

.NOTES
    Requires: Azure CLI (az) logged in with sufficient permissions.
#>

param(
    [string]$AppName = "eklee-azkeyvault-viewer",
    [string]$AppSettingsPath = (Join-Path $PSScriptRoot "appsettings.json")
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# --- Verify Azure CLI is logged in ---
Write-Host "Checking Azure CLI login status..." -ForegroundColor Cyan
$account = az account show --output json
if ($LASTEXITCODE -ne 0) {
    Write-Error "Azure CLI is not logged in. Run 'az login' first."
    exit 1
}

$accountInfo = $account | Out-String | ConvertFrom-Json
$tenantId = $accountInfo.tenantId
Write-Host "Logged in to tenant: $tenantId" -ForegroundColor Green

# --- Look up existing app registration ---
Write-Host "Looking up app registration '$AppName'..." -ForegroundColor Cyan
$existingApps = az ad app list --display-name $AppName --output json | ConvertFrom-Json

$app = $null
if ($existingApps.Count -gt 0) {
    # Filter for exact name match (--display-name does a prefix/contains search)
    $app = $existingApps | Where-Object { $_.displayName -eq $AppName } | Select-Object -First 1
}

if ($app) {
    $clientId = $app.appId
    Write-Host "Found existing app registration '$AppName' (ClientId: $clientId)" -ForegroundColor Green
}
else {
    Write-Host "App registration '$AppName' not found. Creating..." -ForegroundColor Yellow

    # Create the app registration
    $app = az ad app create `
        --display-name $AppName `
        --sign-in-audience AzureADMyOrg `
        --output json | ConvertFrom-Json

    $clientId = $app.appId
    Write-Host "Created app registration (ClientId: $clientId)" -ForegroundColor Green

    # Set the Application ID URI (used as the audience for token validation)
    $identifierUri = "api://$clientId"
    Write-Host "Setting Application ID URI to '$identifierUri'..." -ForegroundColor Cyan
    az ad app update --id $clientId --identifier-uris $identifierUri --output none

    # Expose an API scope (access_as_user) so clients can request tokens
    $scopeId = [guid]::NewGuid().ToString()
    $objectId = $app.id
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

    # Write to a temp file to avoid PowerShell 5.1 argument escaping issues
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

    # Pre-authorize the Azure CLI so 'az account get-access-token' works against this API
    $azureCliAppId = "04b07795-8ddb-461a-bbee-02f9e1bf7b46"
    Write-Host "Pre-authorizing Azure CLI ($azureCliAppId) for scope 'access_as_user'..." -ForegroundColor Cyan

    $preAuthBody = @{
        api = @{
            preAuthorizedApplications = @(
                @{
                    appId                = $azureCliAppId
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
}

# --- Determine the audience ---
$audience = "api://$clientId"

# --- Update appsettings.json ---
Write-Host "Updating '$AppSettingsPath'..." -ForegroundColor Cyan

if (-not (Test-Path $AppSettingsPath)) {
    Write-Error "appsettings.json not found at '$AppSettingsPath'."
    exit 1
}

$appSettings = Get-Content $AppSettingsPath -Raw | ConvertFrom-Json

# Ensure AzureAd section exists
if (-not $appSettings.AzureAd) {
    $appSettings | Add-Member -NotePropertyName "AzureAd" -NotePropertyValue ([PSCustomObject]@{})
}

$appSettings.AzureAd = [PSCustomObject]@{
    Instance = "https://login.microsoftonline.com/"
    TenantId = $tenantId
    ClientId = $clientId
    Audience = $audience
}

$appSettings | ConvertTo-Json -Depth 10 | Set-Content $AppSettingsPath -Encoding UTF8
Write-Host "appsettings.json updated successfully." -ForegroundColor Green

# --- Summary ---
Write-Host ""
Write-Host "=== Configuration Summary ===" -ForegroundColor Cyan
Write-Host "  App Name   : $AppName"
Write-Host "  Tenant ID  : $tenantId"
Write-Host "  Client ID  : $clientId"
Write-Host "  Audience   : $audience"
Write-Host "  Updated    : $AppSettingsPath"
Write-Host ""
