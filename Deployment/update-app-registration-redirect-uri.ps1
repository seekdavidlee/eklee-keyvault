Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

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

function Normalize-RedirectUri {
    param(
        [Parameter(Mandatory = $true)]
        [string]$UriValue
    )

    $candidate = ($UriValue | Out-String).Trim().Trim('"')
    if (-not $candidate) {
        return $null
    }

    $parsedUri = $null
    if (-not [System.Uri]::TryCreate($candidate, [System.UriKind]::Absolute, [ref]$parsedUri)) {
        return $null
    }

    if ($parsedUri.Scheme -eq 'https') {
        return $parsedUri.AbsoluteUri.TrimEnd('/')
    }

    if ($parsedUri.Scheme -eq 'http' -and ($parsedUri.Host -eq 'localhost' -or $parsedUri.Host -eq '127.0.0.1')) {
        return $parsedUri.AbsoluteUri.TrimEnd('/')
    }

    return $null
}

function Get-AzdConfigValue {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    $value = azd env config get $Name 2>&1
    $value = Extract-AzdValue -CommandOutput $value
    if ($LASTEXITCODE -ne 0 -or -not $value) {
        return $null
    }

    return $value
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

$clientId = Get-AzdConfigValue -Name "infra.parameters.clientId"
if (-not $clientId) {
    Write-Error "Missing infra.parameters.clientId in azd environment config."
    exit 1
}

$containerAppUrl = Get-AzdEnvValue -Name "containerAppUrl"
if (-not $containerAppUrl) {
    $containerAppFqdn = Get-AzdEnvValue -Name "containerAppFqdn"
    if (-not $containerAppFqdn) {
        Write-Error "Missing containerAppUrl/containerAppFqdn in azd environment."
        exit 1
    }

    $containerAppUrl = "https://$containerAppFqdn"
}

$containerAppUrl = Normalize-RedirectUri -UriValue $containerAppUrl
if (-not $containerAppUrl) {
    Write-Error "containerAppUrl/containerAppFqdn resolved to an invalid redirect URI."
    exit 1
}

$appJson = az ad app show --id $clientId --output json 2>$null
if ($LASTEXITCODE -ne 0 -or -not $appJson) {
    Write-Error "Unable to load app registration for clientId '$clientId'."
    exit 1
}

$app = $appJson | Out-String | ConvertFrom-Json
$objectId = $app.id
if (-not $objectId) {
    Write-Error "App registration object id not found for clientId '$clientId'."
    exit 1
}

$redirectUriMap = @{}
if ($app.spa -and $app.spa.redirectUris) {
    foreach ($uri in $app.spa.redirectUris) {
        $normalizedExistingUri = Normalize-RedirectUri -UriValue $uri
        if ($normalizedExistingUri) {
            $redirectUriMap[$normalizedExistingUri.ToLowerInvariant()] = $normalizedExistingUri
        }
    }
}

$localhostRedirectUri = Normalize-RedirectUri -UriValue "http://localhost:5173"
$redirectUriMap[$localhostRedirectUri.ToLowerInvariant()] = $localhostRedirectUri
$redirectUriMap[$containerAppUrl.ToLowerInvariant()] = $containerAppUrl

# When a custom domain is configured, also register it as a redirect URI
$customDomain = Get-AzdEnvValue -Name "CUSTOM_DOMAIN_NAME"
if ($customDomain) {
    $customDomainUrl = Normalize-RedirectUri -UriValue "https://$customDomain"
    if ($customDomainUrl) {
        $redirectUriMap[$customDomainUrl.ToLowerInvariant()] = $customDomainUrl
    }
}

[string[]]$redirectUris = @($redirectUriMap.Values)
if ($redirectUris.Count -eq 0) {
    Write-Error "No redirect URIs available to apply."
    exit 1
}

$body = @{
    spa = @{
        redirectUris = $redirectUris
    }
} | ConvertTo-Json -Depth 6

$tempFile = Join-Path $env:TEMP "app-redirect-update-$([guid]::NewGuid()).json"
try {
    $body | Out-File -FilePath $tempFile -Encoding utf8
    az rest --method PATCH --url "https://graph.microsoft.com/v1.0/applications/$objectId" --body "@$tempFile" --headers "Content-Type=application/json" --output none
    if ($LASTEXITCODE -ne 0) {
        Write-Error "Failed to update SPA redirect URIs for clientId '$clientId'."
        exit 1
    }
}
finally {
    Remove-Item $tempFile -ErrorAction SilentlyContinue
}

Write-Host "Updated SPA redirect URIs for app '$clientId'." -ForegroundColor Green
Write-Host "Included redirect URI: $containerAppUrl" -ForegroundColor Green
