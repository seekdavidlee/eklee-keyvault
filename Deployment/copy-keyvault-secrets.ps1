#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Copies secrets from a source Azure Key Vault into the Eklee KeyVault API,
    skipping any secrets that already exist.

.DESCRIPTION
    This script reads all enabled secrets from a source Azure Key Vault (using Azure CLI)
    and then calls the Eklee KeyVault API's PUT /api/secrets/{name} endpoint to create
    each secret that does not already exist. Existing secrets are skipped to avoid
    overwriting values.

    Authentication to the API uses an Azure AD Bearer token obtained via Azure CLI
    (az account get-access-token). The caller must be signed in to Azure CLI with an
    account that has the Admin role in the Eklee KeyVault application.

.PARAMETER SourceKeyVaultName
    The name of the source Azure Key Vault to copy secrets from.

.PARAMETER ApiBaseUrl
    The base URL of the Eklee KeyVault API. Default: http://localhost:5000.

.EXAMPLE
    .\copy-keyvault-secrets.ps1 -SourceKeyVaultName my-source-kv

.EXAMPLE
    .\copy-keyvault-secrets.ps1 -SourceKeyVaultName my-source-kv -ApiBaseUrl https://my-app.azurewebsites.net
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$SourceKeyVaultName,

    [Parameter(Mandatory = $false)]
    [string]$ApiBaseUrl = "http://localhost:5000"
)

# ============================================================================
# Configuration
# ============================================================================

$ErrorActionPreference = 'Stop'
$InformationPreference = 'Continue'

# ============================================================================
# Helper Functions
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

function Write-Skip {
    param([string]$Message)
    Write-Host "  ○ $Message" -ForegroundColor DarkGray
}

function Write-Failure {
    param([string]$Message)
    Write-Host "  ✗ $Message" -ForegroundColor Red
}

# ============================================================================
# Step 1: Validate Prerequisites
# ============================================================================

Write-Header "Copy Key Vault Secrets to Eklee KeyVault API"
Write-Step "Validating Azure CLI is available..."

if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    Write-Failure "Azure CLI (az) is not installed or not in PATH."
    exit 1
}

$account = az account show --output json 2>$null | ConvertFrom-Json
if (-not $account) {
    Write-Failure "Not signed in to Azure CLI. Run 'az login' first."
    exit 1
}
Write-Success "Signed in as $($account.user.name) (subscription: $($account.name))"

# ============================================================================
# Step 2: Get API Bearer Token
# ============================================================================

Write-Header "Acquiring API Bearer Token"

$appSettings = Get-Content -Raw -Path "$PSScriptRoot\..\Eklee.KeyVault.Api\appsettings.json" | ConvertFrom-Json
$clientId = $appSettings.AzureAd.ClientId

Write-Step "Requesting token for api://$clientId..."
$token = az account get-access-token --scope "api://$clientId/.default" --query "accessToken" -o tsv
if (-not $token) {
    Write-Failure "Failed to acquire access token. Ensure you have consent for the API scope."
    exit 1
}
Write-Success "Bearer token acquired."

$headers = @{
    "Authorization" = "Bearer $token"
    "Content-Type"  = "application/json"
}

# ============================================================================
# Step 3: Fetch Existing Secrets from the API
# ============================================================================

Write-Header "Fetching Existing Secrets from API"
Write-Step "GET $ApiBaseUrl/api/secrets"

try {
    $existingSecrets = Invoke-RestMethod -Uri "$ApiBaseUrl/api/secrets" -Headers $headers -Method Get
    $existingNames = @($existingSecrets | ForEach-Object { $_.name })
    Write-Success "Found $($existingNames.Count) existing secret(s) in the API."
}
catch {
    Write-Failure "Failed to fetch existing secrets from API: $_"
    exit 1
}

# ============================================================================
# Step 4: List Secrets from Source Key Vault
# ============================================================================

Write-Header "Listing Secrets from Source Key Vault"
Write-Step "Source: $SourceKeyVaultName"

$sourceSecrets = az keyvault secret list `
    --vault-name $SourceKeyVaultName `
    --query "[?attributes.enabled].name" `
    --output json 2>$null | ConvertFrom-Json

if (-not $sourceSecrets -or $sourceSecrets.Count -eq 0) {
    Write-Skip "No enabled secrets found in source Key Vault."
    exit 0
}
Write-Success "Found $($sourceSecrets.Count) enabled secret(s) in source Key Vault."

# ============================================================================
# Step 5: Copy Secrets
# ============================================================================

Write-Header "Copying Secrets"

$copied = 0
$skipped = 0
$failed = 0

foreach ($secretName in $sourceSecrets) {
    if ($existingNames -contains $secretName) {
        Write-Skip "Skipping '$secretName' — already exists in API."
        $skipped++
        continue
    }

    Write-Step "Reading '$secretName' from source Key Vault..."
    $secretValue = az keyvault secret show `
        --vault-name $SourceKeyVaultName `
        --name $secretName `
        --query "value" `
        --output tsv 2>$null

    if (-not $secretValue) {
        Write-Failure "Failed to read value for '$secretName' from source Key Vault."
        $failed++
        continue
    }

    Write-Step "Setting '$secretName' via API PUT $ApiBaseUrl/api/secrets/$secretName..."
    $body = @{ value = $secretValue } | ConvertTo-Json -Compress

    try {
        Invoke-RestMethod `
            -Uri "$ApiBaseUrl/api/secrets/$secretName" `
            -Headers $headers `
            -Method Put `
            -Body $body | Out-Null

        Write-Success "Created '$secretName'."
        $copied++
    }
    catch {
        Write-Failure "Failed to set '$secretName' via API: $_"
        $failed++
    }
}

# ============================================================================
# Summary
# ============================================================================

Write-Header "Summary"
Write-Host "  Total in source : $($sourceSecrets.Count)" -ForegroundColor White
Write-Success "Copied  : $copied"
Write-Skip "Skipped : $skipped (already existed)"
if ($failed -gt 0) {
    Write-Failure "Failed  : $failed"
}
Write-Host ""
