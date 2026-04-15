<#
.SYNOPSIS
    Runs end-to-end Playwright tests against the local Docker container.

.DESCRIPTION
    This script ensures the local Docker container is running, acquires a fresh
    access token via Azure CLI, and executes the Playwright e2e test suite.

    Prerequisites:
      - Azure CLI installed and logged in (az login)
      - Docker running with the app container (run-local.ps1 -Detached)
      - Node.js and npm installed
      - Playwright browsers installed (npm run e2e:install in Eklee.KeyVault.UI)

.PARAMETER Port
    The host port where the app container is running. Default: 8080.

.PARAMETER Filter
    Optional test file or grep filter (e.g., "secrets-crud", "login"). Runs all tests if omitted.

.PARAMETER Headed
    Run the browser in headed mode so you can watch the tests. Default: headless.

.PARAMETER NoDeps
    Skip the npm ci and playwright install steps.

.EXAMPLE
    .\run-local-e2e.ps1
    Runs all e2e tests in headless mode.

.EXAMPLE
    .\run-local-e2e.ps1 -Filter secrets-crud -Headed
    Runs only the secrets CRUD test with a visible browser.

.EXAMPLE
    .\run-local-e2e.ps1 -Filter login
    Runs only the login test in headless mode.
#>

[CmdletBinding()]
param(
    [int]$Port = 8080,
    [string]$Filter,
    [switch]$Headed,
    [switch]$NoDeps
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ---------------------------------------------------------------------------
# Helpers
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
# Prerequisites
# ---------------------------------------------------------------------------
Write-Status "Checking prerequisites..."

if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    Write-ErrorStatus "Azure CLI (az) is not installed or not in PATH."
    exit 1
}

if (-not (Get-Command node -ErrorAction SilentlyContinue)) {
    Write-ErrorStatus "Node.js is not installed or not in PATH."
    exit 1
}

# Verify Azure CLI login
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
Write-Status "Logged in as: $($azAccount.user.name)" "Green"

# ---------------------------------------------------------------------------
# Read configuration from appsettings.json
# ---------------------------------------------------------------------------
$scriptRoot = $PSScriptRoot
$appSettingsPath = Join-Path (Join-Path $scriptRoot "Eklee.KeyVault.Api") "appsettings.json"
if (-not (Test-Path $appSettingsPath)) {
    Write-ErrorStatus "appsettings.json not found at $appSettingsPath"
    exit 1
}

$appSettings = Get-Content $appSettingsPath -Raw | ConvertFrom-Json
$clientId = $appSettings.AzureAd.ClientId
$tenantId = $appSettings.AzureAd.TenantId

if (-not $clientId -or -not $tenantId) {
    Write-ErrorStatus "AzureAd:ClientId or AzureAd:TenantId is missing in appsettings.json."
    exit 1
}

Write-Status "  ClientId: $clientId"
Write-Status "  TenantId: $tenantId"

# ---------------------------------------------------------------------------
# Verify the app container is running and healthy
# ---------------------------------------------------------------------------
$baseUrl = "http://localhost:$Port"
Write-Status "Checking app health at $baseUrl/healthz..."

try {
    $healthResponse = Invoke-WebRequest -Uri "$baseUrl/healthz" -UseBasicParsing -TimeoutSec 5
    if ($healthResponse.StatusCode -ne 200) {
        Write-ErrorStatus "Health check returned $($healthResponse.StatusCode). Is the app running? Start it with: .\run-local.ps1 -Detached"
        exit 1
    }
    Write-Status "App is healthy." "Green"
}
catch {
    Write-ErrorStatus "Cannot reach $baseUrl/healthz. Start the app first with: .\run-local.ps1 -Detached"
    exit 1
}

# ---------------------------------------------------------------------------
# Acquire access token
# ---------------------------------------------------------------------------
Write-Status "Acquiring access token..."

$prevEAP2 = $ErrorActionPreference
$ErrorActionPreference = "Continue"
$token = az account get-access-token --resource "api://$clientId" --query "accessToken" -o tsv 2>$null
$tokenExitCode = $LASTEXITCODE
$ErrorActionPreference = $prevEAP2

if ($tokenExitCode -ne 0 -or -not $token) {
    Write-ErrorStatus "Failed to acquire access token. Ensure you have consent for api://$clientId"
    exit 1
}
Write-Status "Access token acquired." "Green"

# ---------------------------------------------------------------------------
# Install dependencies (unless -NoDeps)
# ---------------------------------------------------------------------------
$uiDir = Join-Path $scriptRoot "Eklee.KeyVault.UI"

if (-not $NoDeps) {
    Write-Status "Installing npm dependencies..."
    Push-Location $uiDir
    try {
        npm ci --silent
        if ($LASTEXITCODE -ne 0) {
            Write-ErrorStatus "npm ci failed."
            exit $LASTEXITCODE
        }

        Write-Status "Installing Playwright browsers..."
        npx playwright install --with-deps chromium
        if ($LASTEXITCODE -ne 0) {
            Write-ErrorStatus "Playwright browser install failed."
            exit $LASTEXITCODE
        }
    }
    finally {
        Pop-Location
    }
}
else {
    Write-Status "Skipping dependency install (-NoDeps)."
}

# ---------------------------------------------------------------------------
# Run Playwright tests
# ---------------------------------------------------------------------------
Write-Status "Running e2e tests..." "Yellow"

$env:E2E_CLIENT_ID = $clientId
$env:E2E_TENANT_ID = $tenantId
$env:E2E_ACCESS_TOKEN = $token
$env:E2E_BASE_URL = $baseUrl

$playwrightArgs = @("playwright", "test")

if ($Filter) {
    $playwrightArgs += $Filter
}

if ($Headed) {
    $playwrightArgs += "--headed"
}

Push-Location $uiDir
try {
    & npx @playwrightArgs
    $testExitCode = $LASTEXITCODE
}
finally {
    # Clean up env vars
    Remove-Item Env:\E2E_CLIENT_ID -ErrorAction SilentlyContinue
    Remove-Item Env:\E2E_TENANT_ID -ErrorAction SilentlyContinue
    Remove-Item Env:\E2E_ACCESS_TOKEN -ErrorAction SilentlyContinue
    Remove-Item Env:\E2E_BASE_URL -ErrorAction SilentlyContinue
    Pop-Location
}

if ($testExitCode -ne 0) {
    Write-ErrorStatus "E2E tests failed with exit code $testExitCode."
    Write-Status "View report: npx playwright show-report (from Eklee.KeyVault.UI)" "Yellow"
    exit $testExitCode
}

Write-Status "All e2e tests passed!" "Green"
