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

.PARAMETER ForceBuild
    Force a Docker rebuild even if source files haven't changed.

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
    [switch]$ForceBuild,
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

$storageUri = $appSettings.StorageUri
$storageContainerName = $appSettings.StorageContainerName
$keyVaultUri = $appSettings.KeyVaultUri

$missingVars = @()
if (-not $clientId)            { $missingVars += "AzureAd:ClientId" }
if (-not $tenantId)            { $missingVars += "AzureAd:TenantId" }
if (-not $storageUri)          { $missingVars += "StorageUri" }
if (-not $storageContainerName){ $missingVars += "StorageContainerName" }
if (-not $keyVaultUri)         { $missingVars += "KeyVaultUri" }

if ($missingVars.Count -gt 0) {
    Write-ErrorStatus "Missing required settings in appsettings.json: $($missingVars -join ', ')"
    exit 1
}

$authority = "https://login.microsoftonline.com/$tenantId"
if (-not $RedirectUri) {
    $RedirectUri = "http://localhost:$Port"
}

Write-Status "  ClientId:            $clientId"
Write-Status "  TenantId:            $tenantId"
Write-Status "  Authority:           $authority"
Write-Status "  RedirectUri:         $RedirectUri"
Write-Status "  KeyVaultUri:         $keyVaultUri"
Write-Status "  StorageUri:          $storageUri"
Write-Status "  StorageContainerName: $storageContainerName"

# ---------------------------------------------------------------------------
# Verify Key Vault RBAC for the current user
# ---------------------------------------------------------------------------
$vaultName = ([Uri]$keyVaultUri).Host.Split('.')[0]
Write-Status "Checking Key Vault RBAC for vault '$vaultName'..."

$prevEAP3 = $ErrorActionPreference
$ErrorActionPreference = "Continue"
$signedInObjectId = az ad signed-in-user show --query id -o tsv 2>$null
$adExitCode = $LASTEXITCODE
$ErrorActionPreference = $prevEAP3

if ($adExitCode -ne 0 -or -not $signedInObjectId) {
    Write-Status "Could not resolve signed-in user object ID. Skipping RBAC checks." "Yellow"
}
else {
    # --- Key Vault role check ---
    $prevEAP4 = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    $kvResourceId = az keyvault show --name $vaultName --query id -o tsv 2>$null
    $kvExitCode = $LASTEXITCODE
    $ErrorActionPreference = $prevEAP4

    if ($kvExitCode -ne 0 -or -not $kvResourceId) {
        Write-Status "Could not resolve Key Vault resource ID. Skipping Key Vault RBAC check." "Yellow"
    }
    else {
        $prevEAP5 = $ErrorActionPreference
        $ErrorActionPreference = "Continue"
        $kvRolesJson = az role assignment list --assignee $signedInObjectId --scope $kvResourceId --output json 2>$null
        $kvRaExitCode = $LASTEXITCODE
        $ErrorActionPreference = $prevEAP5

        if ($kvRaExitCode -ne 0 -or -not $kvRolesJson) {
            Write-Status "Could not query Key Vault role assignments. Skipping RBAC check." "Yellow"
        }
        else {
            $kvRoles = $kvRolesJson | ConvertFrom-Json
            $requiredKvRole = "Key Vault Secrets Officer"
            $hasKvRole = $kvRoles | Where-Object { $_.roleDefinitionName -eq $requiredKvRole }

            if ($hasKvRole) {
                Write-Status "User has '$requiredKvRole' role on vault '$vaultName'." "Green"
            }
            else {
                $assignedKvRoles = ($kvRoles | ForEach-Object { $_.roleDefinitionName }) -join ", "
                if ($assignedKvRoles) {
                    Write-ErrorStatus "User does NOT have '$requiredKvRole' on vault '$vaultName'. Assigned roles: $assignedKvRoles"
                }
                else {
                    Write-ErrorStatus "User has NO role assignments on vault '$vaultName'. Required: '$requiredKvRole'."
                }
                Write-Status "Assign it with: az role assignment create --assignee $signedInObjectId --role '$requiredKvRole' --scope $kvResourceId" "Yellow"
                exit 1
            }
        }
    }

    # --- Storage Account role check ---
    $storageAccountName = ([Uri]$storageUri).Host.Split('.')[0]
    Write-Status "Checking Storage Account RBAC for '$storageAccountName'..."

    $prevEAP6 = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    $storageResourceId = az storage account show --name $storageAccountName --query id -o tsv 2>$null
    $saExitCode = $LASTEXITCODE
    $ErrorActionPreference = $prevEAP6

    if ($saExitCode -ne 0 -or -not $storageResourceId) {
        Write-Status "Could not resolve Storage Account resource ID. Skipping Storage RBAC check." "Yellow"
    }
    else {
        $prevEAP7 = $ErrorActionPreference
        $ErrorActionPreference = "Continue"
        $storageRolesJson = az role assignment list --assignee $signedInObjectId --scope $storageResourceId --output json 2>$null
        $srExitCode = $LASTEXITCODE
        $ErrorActionPreference = $prevEAP7

        if ($srExitCode -ne 0 -or -not $storageRolesJson) {
            Write-Status "Could not query Storage role assignments. Skipping RBAC check." "Yellow"
        }
        else {
            $storageRoles = $storageRolesJson | ConvertFrom-Json
            $requiredStorageRole = "Storage Blob Data Contributor"
            $hasStorageRole = $storageRoles | Where-Object { $_.roleDefinitionName -eq $requiredStorageRole }

            if ($hasStorageRole) {
                Write-Status "User has '$requiredStorageRole' role on storage account '$storageAccountName'." "Green"
            }
            else {
                $assignedStorageRoles = ($storageRoles | ForEach-Object { $_.roleDefinitionName }) -join ", "
                if ($assignedStorageRoles) {
                    Write-ErrorStatus "User does NOT have '$requiredStorageRole' on storage account '$storageAccountName'. Assigned roles: $assignedStorageRoles"
                }
                else {
                    Write-ErrorStatus "User has NO role assignments on storage account '$storageAccountName'. Required: '$requiredStorageRole'."
                }
                Write-Status "Assign it with: az role assignment create --assignee $signedInObjectId --role '$requiredStorageRole' --scope $storageResourceId" "Yellow"
                exit 1
            }
        }
    }
}

# ---------------------------------------------------------------------------
# Build the Docker image (with content-hash caching)
# ---------------------------------------------------------------------------
function Get-BuildContextHash {
    # Hash all files that contribute to the Docker build, respecting .dockerignore.
    $excludeDirs = @('bin', 'obj', 'node_modules', 'dist', '.git', '.vs', '.vscode')
    $excludeExtensions = @('.md')

    $sourceFiles = Get-ChildItem $scriptRoot -Recurse -File |
        Where-Object {
            $rel = $_.FullName.Substring($scriptRoot.Length + 1)
            $parts = $rel.Split([IO.Path]::DirectorySeparatorChar)
            # Exclude files whose path contains an ignored directory segment
            $inExcluded = $false
            foreach ($part in $parts) {
                if ($excludeDirs -contains $part) { $inExcluded = $true; break }
            }
            -not $inExcluded -and $excludeExtensions -notcontains $_.Extension
        } |
        Sort-Object FullName

    $sha = [System.Security.Cryptography.SHA256]::Create()
    foreach ($file in $sourceFiles) {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($file.FullName.Substring($scriptRoot.Length))
        $sha.TransformBlock($bytes, 0, $bytes.Length, $bytes, 0) | Out-Null
        $content = [System.IO.File]::ReadAllBytes($file.FullName)
        $sha.TransformBlock($content, 0, $content.Length, $content, 0) | Out-Null
    }
    $sha.TransformFinalBlock(@(), 0, 0) | Out-Null
    return ([BitConverter]::ToString($sha.Hash) -replace '-', '').Substring(0, 12).ToLowerInvariant()
}

if (-not $NoBuild) {
    Write-Status "Computing build context hash..."
    $currentHash = Get-BuildContextHash
    $taggedImage = "${ImageName}:${currentHash}"

    $imageExists = (docker images -q $taggedImage 2>$null)

    if ($imageExists -and -not $ForceBuild) {
        Write-Status "Source files unchanged — skipping Docker build ($currentHash)." "Green"
    }
    else {
        if (-not $imageExists) {
            Write-Status "No image for hash $currentHash — building '$taggedImage'..."
        }
        else {
            Write-Status "Force rebuilding '$taggedImage'..."
        }
        Write-Status "  (this may take a few minutes on first build)"

        $buildArgs = @(
            "build"
            "--target", "local"
            "-t", $taggedImage
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
    # Always point the run at the hash-tagged image
    $ImageName = $taggedImage
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
    "-e", "KeyVaultUri=$keyVaultUri"
    "-e", "StorageUri=$storageUri"
    "-e", "StorageContainerName=$storageContainerName"
    "-e", "VITE_AZURE_AD_CLIENT_ID=$clientId"
    "-e", "VITE_AZURE_AD_AUTHORITY=$authority"
    "-e", "VITE_AZURE_AD_REDIRECT_URI=$RedirectUri"
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
