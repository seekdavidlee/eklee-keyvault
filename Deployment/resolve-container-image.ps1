<#
.SYNOPSIS
    Resolves the latest container image digest from ghcr.io and stores it in the
    azd environment so Bicep receives a unique image reference on every deployment.

.DESCRIPTION
    1. Obtains an anonymous pull token from ghcr.io (public repository).
    2. Fetches the manifest digest for the 'latest' tag.
    3. Stores the full image reference (with digest) in the azd environment
       variable CONTAINER_IMAGE so Bicep always gets a deterministic, unique
       value that forces a new Container App revision when the image changes.

.NOTES
    Requires: Azure Developer CLI (azd) with an active environment.
    Works without authentication because the ghcr.io repository is public.

.EXAMPLE
    .\Deployment\resolve-container-image.ps1
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$ImageRepo = "seekdavidlee/eklee-keyvault"
$Tag = "latest"

Write-Host "Resolving latest container image digest for $ImageRepo`:$Tag ..." -ForegroundColor Cyan

# ---------------------------------------------------------------------------
# 1. Obtain anonymous pull token from ghcr.io
# ---------------------------------------------------------------------------
$tokenUri = "https://ghcr.io/token?scope=repository:${ImageRepo}:pull"
$tokenResponse = Invoke-RestMethod -Uri $tokenUri -UseBasicParsing
$token = $tokenResponse.token

if (-not $token) {
    Write-Error "Failed to obtain pull token from ghcr.io."
    exit 1
}

# ---------------------------------------------------------------------------
# 2. Fetch the manifest digest for the tag
# ---------------------------------------------------------------------------
$manifestUri = "https://ghcr.io/v2/${ImageRepo}/manifests/${Tag}"
$headers = @{
    Authorization = "Bearer $token"
    Accept        = "application/vnd.oci.image.index.v1+json,application/vnd.docker.distribution.manifest.v2+json,application/vnd.docker.distribution.manifest.list.v2+json"
}

$response = Invoke-WebRequest -Uri $manifestUri -Headers $headers -UseBasicParsing
$digest = $response.Headers['docker-content-digest']

# Handle the case where the header value is returned as an array
if ($digest -is [System.Collections.IEnumerable] -and $digest -isnot [string]) {
    $digest = $digest[0]
}

if (-not $digest) {
    Write-Error "Failed to retrieve docker-content-digest header from ghcr.io."
    exit 1
}

$imageRef = "ghcr.io/${ImageRepo}@${digest}"
Write-Host "Resolved image: $imageRef" -ForegroundColor Green

# ---------------------------------------------------------------------------
# 3. Store in the azd environment for Bicep parameter mapping
# ---------------------------------------------------------------------------
azd env set CONTAINER_IMAGE $imageRef
if ($LASTEXITCODE -ne 0) {
    Write-Error "Failed to set CONTAINER_IMAGE in azd environment."
    exit 1
}

Write-Host "CONTAINER_IMAGE stored in azd environment." -ForegroundColor Green
