<#
.SYNOPSIS
    Builds and runs the Eklee KeyVault application locally in Docker using your Azure CLI credentials.

.DESCRIPTION
    This script builds a combined API + UI Docker image that includes Azure CLI, then runs the
    container with your local ~/.azure token cache mounted as a read-only volume. This allows
    the ASP.NET backend to use AzureCliCredential to access Key Vault and Storage without
    needing a managed identity.

    Configuration (ClientId, TenantId, KeyVaultUri, etc.) is read from appsettings.json by default.
    All values can be overridden via parameters.

.PARAMETER Port
    The host port to map to the container's port 8080. Default: 8080.

.PARAMETER ImageName
    The Docker image name. Default: eklee-keyvault-local.

.PARAMETER Detached
    Run the container in detached mode (background). Default: $false (foreground with logs).

.PARAMETER NoBuild
    Skip the Docker build step and run using the existing image.

.PARAMETER RedirectUri
    Override the MSAL redirect URI baked into the SPA. Default: http://localhost:<Port>.

.EXAMPLE
    .\run-local.ps1
    Builds and runs the container on port 8080 in the foreground.

.EXAMPLE
    .\run-local.ps1 -Port 9090 -Detached
    Builds and runs the container on port 9090 in detached mode.

.EXAMPLE
    .\run-local.ps1 -NoBuild
    Runs the previously built image without rebuilding.
#>

[CmdletBinding()]
param(
    [int]$Port = 8080,
    [string]$ImageName = "eklee-keyvault-local",
    [switch]$Detached,
    [switch]$NoBuild,
    [string]$RedirectUri
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ---------------------------------------------------------------------------
# Helper: Write colored status messages
# ---------------------------------------------------------------------------
function Write-Status {
    param([string]$Message, [string]$Color = "Cyan")
    Write-Host ">> $Message" -ForegroundColor $Color
}

function Write-ErrorStatus {
    param([string]$Message)
    Write-Host ">> ERROR: $Message" -ForegroundColor Red
}

# ---------------------------------------------------------------------------
# Prerequisites check
# ---------------------------------------------------------------------------
Write-Status "Checking prerequisites..."

# Docker
if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    Write-ErrorStatus "Docker is not installed or not in PATH."
    exit 1
}

try {
    docker info | Out-Null 2>&1
}
catch {
    Write-ErrorStatus "Docker daemon is not running. Please start Docker Desktop."
    exit 1
}

# Azure CLI
if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    Write-ErrorStatus "Azure CLI (az) is not installed or not in PATH."
    exit 1
}

Write-Status "Verifying Azure CLI login..."
# Temporarily allow stderr output from az CLI (extensions may emit warnings to stderr)
$prevEAP = $ErrorActionPreference
$ErrorActionPreference = "Continue"
$azAccountJson = az account show --output json 2>$null
$azExitCode = $LASTEXITCODE
$ErrorActionPreference = $prevEAP

if ($azExitCode -ne 0 -or -not $azAccountJson) {
    Write-ErrorStatus "Not logged in to Azure CLI. Run 'az login' first."
    exit 1
}
$azAccount = $azAccountJson | ConvertFrom-Json
Write-Status "Logged in as: $($azAccount.user.name) (subscription: $($azAccount.name))" "Green"

# ---------------------------------------------------------------------------
# Read configuration from appsettings.json
# ---------------------------------------------------------------------------
$scriptRoot = $PSScriptRoot
$appSettingsPath = Join-Path (Join-Path $scriptRoot "Eklee.KeyVault.Api") "appsettings.json"
if (-not (Test-Path $appSettingsPath)) {
    Write-ErrorStatus "appsettings.json not found at $appSettingsPath"
    exit 1
}

Write-Status "Reading configuration from appsettings.json..."
$appSettings = Get-Content $appSettingsPath -Raw | ConvertFrom-Json

$azureAdSection = $appSettings.AzureAd
$clientId = $azureAdSection.ClientId
$tenantId = $azureAdSection.TenantId

if (-not $clientId -or -not $tenantId) {
    Write-ErrorStatus "AzureAd:ClientId or AzureAd:TenantId is missing in appsettings.json."
    exit 1
}

$authority = "https://login.microsoftonline.com/$tenantId"
if (-not $RedirectUri) {
    $RedirectUri = "http://localhost:$Port"
}

Write-Status "  ClientId:    $clientId"
Write-Status "  TenantId:    $tenantId"
Write-Status "  Authority:   $authority"
Write-Status "  RedirectUri: $RedirectUri"

# ---------------------------------------------------------------------------
# Build the Docker image
# ---------------------------------------------------------------------------
if (-not $NoBuild) {
    Write-Status "Building Docker image '$ImageName'..."
    Write-Status "  (this may take a few minutes on first build)"

    $buildArgs = @(
        "build"
        "--target", "local"
        "-t", $ImageName
        "--build-arg", "VITE_AZURE_AD_CLIENT_ID=$clientId"
        "--build-arg", "VITE_AZURE_AD_AUTHORITY=$authority"
        "--build-arg", "VITE_AZURE_AD_REDIRECT_URI=$RedirectUri"
        "."
    )

    Push-Location $scriptRoot
    try {
        & docker @buildArgs
        if ($LASTEXITCODE -ne 0) {
            Write-ErrorStatus "Docker build failed with exit code $LASTEXITCODE."
            exit $LASTEXITCODE
        }
        Write-Status "Docker image built successfully." "Green"
    }
    finally {
        Pop-Location
    }
}
else {
    Write-Status "Skipping build (-NoBuild). Using existing image '$ImageName'."
}

# ---------------------------------------------------------------------------
# Pre-fetch Azure access tokens on the host
# ---------------------------------------------------------------------------
# Windows DPAPI-encrypts the MSAL token cache, so mounting ~/.azure into a
# Linux container doesn't work. Instead, we pre-fetch access tokens here
# (on the host, where you are already logged in) and mount them as JSON
# files into the container. A lightweight az wrapper script inside the
# container intercepts AzureCliCredential calls and returns these tokens.
Write-Status "Pre-fetching Azure access tokens from host CLI..."

$tokenDir = Join-Path $env:TEMP "eklee-keyvault-tokens"
if (Test-Path $tokenDir) {
    Remove-Item $tokenDir -Recurse -Force
}
New-Item -ItemType Directory -Path $tokenDir -Force | Out-Null

$resources = @(
    "https://vault.azure.net",
    "https://storage.azure.com"
)

$prevEAP2 = $ErrorActionPreference
$ErrorActionPreference = "Continue"

foreach ($resource in $resources) {
    Write-Status "  Fetching token for $resource..."
    $tokenJson = az account get-access-token --resource $resource --output json 2>$null
    $tokenExitCode = $LASTEXITCODE

    if ($tokenExitCode -ne 0 -or -not $tokenJson) {
        $ErrorActionPreference = $prevEAP2
        Write-ErrorStatus "Failed to get access token for $resource. Ensure you have access."
        exit 1
    }

    # Filename: strip scheme, trailing slash, replace / with _
    $filename = $resource -replace 'https://', '' -replace '/$', '' -replace '/', '_'
    $tokenPath = Join-Path $tokenDir "$filename.json"
    [System.IO.File]::WriteAllText($tokenPath, $tokenJson, [System.Text.UTF8Encoding]::new($false))
}

$ErrorActionPreference = $prevEAP2
Write-Status "Access tokens cached successfully." "Green"

# ---------------------------------------------------------------------------
# Stop any existing container with the same name
# ---------------------------------------------------------------------------
$containerName = "eklee-keyvault-local"
$existing = docker ps -aq --filter "name=$containerName" 2>$null
if ($existing) {
    Write-Status "Stopping existing container '$containerName'..."
    docker rm -f $containerName | Out-Null
}

# ---------------------------------------------------------------------------
# Run the container with pre-fetched tokens mounted
# ---------------------------------------------------------------------------
Write-Status "Starting container..."

$tokenDirDocker = $tokenDir -replace '\\', '/'

$runArgs = @(
    "run"
    "--rm"
    "--name", $containerName
    "-p", "${Port}:8080"
    "-v", "${tokenDirDocker}:/tmp/az-tokens:ro"
    "-e", "AuthenticationMode=azcli"
    "-e", "ASPNETCORE_ENVIRONMENT=Development"
)

if ($Detached) {
    $runArgs += "-d"
}

$runArgs += $ImageName

Write-Host ""
Write-Status "Container configuration:" "Yellow"
Write-Status "  Image:      $ImageName"
Write-Status "  Port:       http://localhost:$Port"
Write-Status "  Swagger:    http://localhost:$Port/swagger"
Write-Status "  Health:     http://localhost:$Port/healthz"
Write-Status "  Tokens:     $tokenDir (mounted read-only)"
Write-Host ""
Write-Host "NOTE: Pre-fetched tokens expire after ~1 hour. Re-run this script to refresh." -ForegroundColor Yellow
Write-Host ""

# Reminder about the SPA redirect URI in the app registration
Write-Host "NOTE: Ensure '$RedirectUri' is registered as a SPA redirect URI in your" -ForegroundColor Yellow
Write-Host "      Entra ID app registration. If not, run:" -ForegroundColor Yellow
Write-Host "      az ad app update --id $clientId --spa-redirect-uris $RedirectUri http://localhost:5173" -ForegroundColor White
Write-Host ""

& docker @runArgs

if ($Detached -and $LASTEXITCODE -eq 0) {
    Write-Status "Container '$containerName' is running in the background." "Green"
    Write-Status ("  View logs:   docker logs -f " + $containerName)
    Write-Status ("  Stop:        docker rm -f " + $containerName)
}
