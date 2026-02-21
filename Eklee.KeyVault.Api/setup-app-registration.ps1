<#
.SYNOPSIS
    Looks up or creates the "eklee-azkeyvault-viewer" Azure AD app registration,
    updates appsettings.json, and optionally sets GitHub Actions environment variables.

.DESCRIPTION
    1. Checks for an existing app registration named "eklee-azkeyvault-viewer".
    2. If it does not exist, creates one with an Application ID URI (api://<clientId>)
       to protect the API.
    3. Updates the local appsettings.json AzureAd section with Instance, TenantId,
       ClientId, and Audience.
    4. When GitHubOrganization and GitHubRepoName are provided, sets per-environment
       (dev/prod) GitHub Actions variables for VITE_AZURE_AD_CLIENT_ID,
       VITE_AZURE_AD_AUTHORITY, and VITE_AZURE_AD_REDIRECT_URI.

.PARAMETER AppName
    The display name of the Azure AD app registration. Defaults to "eklee-azkeyvault-viewer".

.PARAMETER AppSettingsPath
    Path to the appsettings.json file to update. Defaults to the file in the script directory.

.PARAMETER GitHubOrganization
    The GitHub organization (or username) that owns the repository.
    Required to set GitHub Actions environment variables.

.PARAMETER GitHubRepoName
    The name of the GitHub repository.
    Required to set GitHub Actions environment variables.

.PARAMETER AzureAdRedirectUriDev
    The redirect URI for the dev environment (e.g. the dev Container App URL).
    Required when setting GitHub variables.

.PARAMETER AzureAdRedirectUriProd
    The redirect URI for the prod environment (e.g. the prod Container App URL).
    Optional. When omitted, only the dev environment variables are set.

.NOTES
    Requires: Azure CLI (az) logged in with sufficient permissions.
    Requires: GitHub CLI (gh) authenticated when setting GitHub variables.

.EXAMPLE
    .\setup-app-registration.ps1

    Creates/updates the app registration and updates local appsettings.json only.

.EXAMPLE
    .\setup-app-registration.ps1 -GitHubOrganization "seekdavidlee" -GitHubRepoName "eklee-keyvault" -AzureAdRedirectUriDev "https://eklee-keyvault.proudisland-cfc9d53d.eastus2.azurecontainerapps.io"

    Sets VITE_AZURE_AD_* GitHub environment variables for the dev environment.

.EXAMPLE
    .\setup-app-registration.ps1 -GitHubOrganization "seekdavidlee" -GitHubRepoName "eklee-keyvault" -AzureAdRedirectUriDev "https://eklee-keyvault-dev.nicemeadow.eastus2.azurecontainerapps.io" -AzureAdRedirectUriProd "https://eklee-keyvault.nicemeadow.eastus2.azurecontainerapps.io"

    Sets VITE_AZURE_AD_* GitHub environment variables for both dev and prod.
#>

param(
    [string]$AppName = "eklee-azkeyvault-viewer",
    [string]$AppSettingsPath = (Join-Path $PSScriptRoot "appsettings.json"),

    [Parameter(Mandatory = $false)]
    [string]$GitHubOrganization,

    [Parameter(Mandatory = $false)]
    [string]$GitHubRepoName,

    [Parameter(Mandatory = $false)]
    [string]$AzureAdRedirectUriDev,

    [Parameter(Mandatory = $false)]
    [string]$AzureAdRedirectUriProd
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

# --- Ensure SPA redirect URIs are configured (needed for the React UI) ---
# Always include localhost for local dev; add deployed environment URIs when provided.
$spaRedirectUris = @("http://localhost:5173")
if ($AzureAdRedirectUriDev) { $spaRedirectUris += $AzureAdRedirectUriDev }
if ($AzureAdRedirectUriProd) { $spaRedirectUris += $AzureAdRedirectUriProd }

Write-Host "Ensuring SPA redirect URIs are configured: $($spaRedirectUris -join ', ')..." -ForegroundColor Cyan

# Get the objectId (needed for Graph API call)
if (-not $app.id) {
    $app = az ad app list --display-name $AppName --output json | ConvertFrom-Json | Where-Object { $_.displayName -eq $AppName } | Select-Object -First 1
}
$objectId = $app.id

$spaBody = @{
    spa = @{
        redirectUris = $spaRedirectUris
    }
} | ConvertTo-Json -Depth 5

$tempFileSpa = Join-Path $env:TEMP "app-spa-$([guid]::NewGuid()).json"
try {
    $spaBody | Out-File -FilePath $tempFileSpa -Encoding utf8
    az rest --method PATCH `
        --url "https://graph.microsoft.com/v1.0/applications/$objectId" `
        --body "@$tempFileSpa" `
        --headers "Content-Type=application/json" `
        --output none
}
finally {
    Remove-Item $tempFileSpa -ErrorAction SilentlyContinue
}
Write-Host "SPA redirect URIs configured." -ForegroundColor Green

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

# --- Update .env for the UI client ---
$envFilePath = Join-Path (Join-Path (Join-Path $PSScriptRoot "..") "Eklee.KeyVault.UI") ".env"
if (Test-Path $envFilePath) {
    Write-Host "Updating '$envFilePath'..." -ForegroundColor Cyan
    $envContent = Get-Content $envFilePath -Raw
    $envContent = $envContent -replace '(?m)^VITE_AZURE_AD_CLIENT_ID=.*$', "VITE_AZURE_AD_CLIENT_ID=$clientId"
    $envContent = $envContent -replace '(?m)^VITE_AZURE_AD_AUTHORITY=.*$', "VITE_AZURE_AD_AUTHORITY=https://login.microsoftonline.com/$tenantId"
    $envContent | Set-Content $envFilePath -Encoding UTF8 -NoNewline
    Write-Host ".env updated successfully." -ForegroundColor Green
}
else {
    Write-Warning ".env not found at '$envFilePath'. Skipping UI client update."
}

# --- Summary ---
Write-Host ""
Write-Host "=== Configuration Summary ===" -ForegroundColor Cyan
Write-Host "  App Name   : $AppName"
Write-Host "  Tenant ID  : $tenantId"
Write-Host "  Client ID  : $clientId"
Write-Host "  Audience   : $audience"
Write-Host "  Updated    : $AppSettingsPath"
if (Test-Path $envFilePath) {
    Write-Host "  Updated    : $envFilePath"
}
Write-Host ""

# --- Set GitHub Actions environment variables (optional) ---
if ($GitHubOrganization -and $GitHubRepoName) {
    if (-not $AzureAdRedirectUriDev) {
        Write-Error "AzureAdRedirectUriDev is required when setting GitHub environment variables."
        exit 1
    }

    $ghRepo = "${GitHubOrganization}/${GitHubRepoName}"
    Write-Host "Setting GitHub Actions environment variables for $ghRepo..." -ForegroundColor Cyan

    $environments = @(
        @{ Name = 'dev';  RedirectUri = $AzureAdRedirectUriDev }
    )
    if ($AzureAdRedirectUriProd) {
        $environments += @{ Name = 'prod'; RedirectUri = $AzureAdRedirectUriProd }
    }

    foreach ($env in $environments) {
        $envName = $env.Name

        $ghVars = @{
            VITE_AZURE_AD_CLIENT_ID    = $clientId
            VITE_AZURE_AD_AUTHORITY    = "https://login.microsoftonline.com/$tenantId"
            VITE_AZURE_AD_REDIRECT_URI = $env.RedirectUri
        }

        foreach ($var in $ghVars.GetEnumerator()) {
            Write-Host "  -> Setting '$($var.Key)' = '$($var.Value)' for environment '$envName'..." -ForegroundColor Yellow
            $var.Value | gh variable set $var.Key --repo $ghRepo --env $envName
            if ($LASTEXITCODE -eq 0) {
                Write-Host "  [OK] Variable '$($var.Key)' set for environment '$envName'" -ForegroundColor Green
            }
            else {
                Write-Error "Failed to set variable '$($var.Key)' for environment '$envName'"
                exit 1
            }
        }
    }

    Write-Host ""
    Write-Host "  [OK] All GitHub environment variables configured for $ghRepo" -ForegroundColor Green
    Write-Host ""
}
