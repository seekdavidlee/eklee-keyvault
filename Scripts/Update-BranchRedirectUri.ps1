#!/usr/bin/env pwsh
# SPDX-License-Identifier: MIT
#Requires -Version 7.4

<#
.SYNOPSIS
    Registers or removes a deployed Container App URL as a SPA redirect URI.

.DESCRIPTION
    Discovers the ingress URL of a deployed Azure Container App and adds or
    removes it from the specified Microsoft Entra SPA app registration without
    changing other redirect URIs. When registering, configures the app to use
    the same URL at runtime.

.PARAMETER EnvironmentName
    The azd environment to use. When omitted, the script prompts for an
    environment name.

.PARAMETER ResourceGroupName
    The resource group containing the deployed Container App. When omitted,
    the script reads resourceGroupName from the selected azd environment.

.PARAMETER ContainerAppName
    The name of the deployed Container App. When omitted, the script derives
    the CI-compatible name from the current Git branch.

.PARAMETER SpaAppClientId
    The client ID of the Microsoft Entra SPA app registration. When omitted,
    the script reads APP_CLIENT_ID from the selected azd environment.

.PARAMETER Remove
    Removes the deployed Container App URL from the SPA redirect URIs. The
    Container App must still exist so its ingress URL can be discovered.

.EXAMPLE
    ./Scripts/Update-BranchRedirectUri.ps1

.EXAMPLE
    ./Scripts/Update-BranchRedirectUri.ps1 -EnvironmentName dev

.EXAMPLE
    ./Scripts/Update-BranchRedirectUri.ps1 -Remove -ContainerAppName ekv-branch-example-1234567

.NOTES
    Requires Azure CLI authentication as a user who can update the Container
    App and the specified Microsoft Entra application registration.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [ValidateNotNullOrEmpty()]
    [string]$EnvironmentName,

    [Parameter(Mandatory = $false)]
    [ValidateNotNullOrEmpty()]
    [string]$ResourceGroupName,

    [Parameter(Mandatory = $false)]
    [ValidateNotNullOrEmpty()]
    [string]$ContainerAppName,

    [Parameter(Mandatory = $false)]
    [ValidatePattern('^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$')]
    [string]$SpaAppClientId,

    [Parameter(Mandatory = $false)]
    [switch]$Remove
)

$ErrorActionPreference = 'Stop'

#region Functions
function Get-AzdEnvironmentValue {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$EnvironmentName,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Name
    )

    $Value = & azd env get-value $Name --environment $EnvironmentName 2>$null
    if ($LASTEXITCODE -ne 0) {
        return $null
    }

    return ($Value | Out-String).Trim().Trim('"')
}

function Get-AzdEnvironmentName {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $false)]
        [string]$EnvironmentName
    )

    if (-not [string]::IsNullOrWhiteSpace($EnvironmentName)) {
        return $EnvironmentName
    }

    $AvailableEnvironments = & azd env list 2>$null
    if ($LASTEXITCODE -ne 0) {
        throw 'Unable to list azd environments.'
    }

    Write-Host 'Available azd environments:' -ForegroundColor Cyan
    $AvailableEnvironments | Write-Host
    $EnvironmentName = Read-Host -Prompt 'Enter the azd environment name'
    if ([string]::IsNullOrWhiteSpace($EnvironmentName)) {
        throw 'An azd environment name is required.'
    }

    return $EnvironmentName.Trim()
}

function Get-BranchContainerAppName {
    [CmdletBinding()]
    [OutputType([string])]
    param()

    $BranchName = (& git branch --show-current 2>$null | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($BranchName)) {
        throw 'Unable to determine the current Git branch. Pass -ContainerAppName explicitly.'
    }

    if ($BranchName -eq 'main') {
        return 'eklee-keyvault'
    }

    $Kind = if ($BranchName -like 'release/*') { 'release' } else { 'branch' }
    $NormalizedName = ($BranchName.ToLowerInvariant() -replace '[^a-z0-9]+', '-').Trim('-')
    if ([string]::IsNullOrWhiteSpace($NormalizedName)) {
        throw "Current Git branch '$BranchName' cannot be converted to a Container App name. Pass -ContainerAppName explicitly."
    }

    $Hash = [System.Convert]::ToHexString(
        [System.Security.Cryptography.SHA256]::HashData([System.Text.Encoding]::UTF8.GetBytes($BranchName))
    ).Substring(0, 7).ToLowerInvariant()
    $Slug = $NormalizedName.Substring(0, [Math]::Min(12, $NormalizedName.Length)).TrimEnd('-')
    $ContainerAppName = "ekv-$Kind-$Slug-$Hash"
    if ($ContainerAppName.Length -gt 32) {
        throw "Derived Container App name '$ContainerAppName' exceeds Azure's 32-character limit. Pass -ContainerAppName explicitly."
    }

    return $ContainerAppName
}

function Invoke-BranchRedirectUriUpdate {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ResourceGroupName,

        [Parameter(Mandatory = $true)]
        [string]$ContainerAppName,

        [Parameter(Mandatory = $true)]
        [string]$SpaAppClientId,

        [Parameter(Mandatory = $false)]
        [switch]$Remove
    )

    if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
        throw 'Azure CLI is required.'
    }

    az account show --only-show-errors --output none
    if ($LASTEXITCODE -ne 0) {
        throw 'Azure CLI is not authenticated. Run az login and select the deployment subscription.'
    }

    $ContainerAppJson = az containerapp show `
        --name $ContainerAppName `
        --resource-group $ResourceGroupName `
        --only-show-errors `
        --output json
    if ($LASTEXITCODE -ne 0 -or -not $ContainerAppJson) {
        throw "Unable to load Container App '$ContainerAppName'."
    }

    $ContainerApp = $ContainerAppJson | ConvertFrom-Json
    $Fqdn = $ContainerApp.properties.configuration.ingress.fqdn
    if ([string]::IsNullOrWhiteSpace($Fqdn)) {
        throw "Container App '$ContainerAppName' does not have an ingress FQDN."
    }

    $RedirectUri = "https://$Fqdn".TrimEnd('/')
    $ParsedUri = $null
    if (-not [System.Uri]::TryCreate($RedirectUri, [System.UriKind]::Absolute, [ref]$ParsedUri) -or $ParsedUri.Scheme -ne 'https') {
        throw "Container App '$ContainerAppName' returned an invalid HTTPS redirect URI."
    }

    $SpaApplicationJson = az ad app show --id $SpaAppClientId --only-show-errors --output json
    if ($LASTEXITCODE -ne 0 -or -not $SpaApplicationJson) {
        throw "Unable to load SPA app registration '$SpaAppClientId'."
    }

    $SpaApplication = $SpaApplicationJson | ConvertFrom-Json
    if ([string]::IsNullOrWhiteSpace($SpaApplication.id)) {
        throw "SPA app registration '$SpaAppClientId' has no object ID."
    }

    $RedirectUris = [System.Collections.Generic.List[string]]::new()
    $RedirectUriExists = $false
    $ExistingRedirectUris = if ($SpaApplication.spa -and $SpaApplication.spa.redirectUris) {
        @($SpaApplication.spa.redirectUris)
    }
    else {
        @()
    }
    foreach ($ExistingRedirectUri in $ExistingRedirectUris) {
        if ([string]::IsNullOrWhiteSpace($ExistingRedirectUri)) {
            throw "SPA app registration '$SpaAppClientId' contains an invalid redirect URI."
        }

        if ([string]::Equals($ExistingRedirectUri.TrimEnd('/'), $RedirectUri, [System.StringComparison]::OrdinalIgnoreCase)) {
            $RedirectUriExists = $true
            if ($Remove) {
                continue
            }
        }

        [void]$RedirectUris.Add($ExistingRedirectUri)
    }

    if (-not $Remove -and -not $RedirectUriExists) {
        [void]$RedirectUris.Add($RedirectUri)
    }

    $ShouldUpdateRedirectUris = ($Remove -and $RedirectUriExists) -or (-not $Remove -and -not $RedirectUriExists)
    if ($ShouldUpdateRedirectUris) {
        $RequestBody = @{
            spa = @{
                redirectUris = @($RedirectUris)
            }
        } | ConvertTo-Json -Depth 6 -Compress

        $TemporaryBodyFile = Join-Path ([System.IO.Path]::GetTempPath()) "app-redirect-update-$([guid]::NewGuid()).json"
        try {
            Set-Content -Path $TemporaryBodyFile -Value $RequestBody -Encoding utf8 -NoNewline
            az rest `
                --method PATCH `
                --url "https://graph.microsoft.com/v1.0/applications/$($SpaApplication.id)" `
                --headers 'Content-Type=application/json' `
                --body "@$TemporaryBodyFile" `
                --output none
            if ($LASTEXITCODE -ne 0) {
                throw "Failed to update redirect URIs on SPA app registration '$SpaAppClientId'."
            }
        }
        finally {
            Remove-Item -Path $TemporaryBodyFile -ErrorAction SilentlyContinue
        }

        $Action = if ($Remove) { 'Removed' } else { 'Registered' }
        Write-Host "${Action} SPA redirect URI: $RedirectUri" -ForegroundColor Green
    }
    else {
        $Action = if ($Remove) { 'is not registered' } else { 'is already registered' }
        Write-Host "SPA redirect URI ${Action}: $RedirectUri" -ForegroundColor Yellow
    }

    if ($Remove) {
        return
    }

    az containerapp update `
        --name $ContainerAppName `
        --resource-group $ResourceGroupName `
        --set-env-vars "VITE_AZURE_AD_REDIRECT_URI=$RedirectUri" `
        --only-show-errors `
        --output none
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to set the runtime redirect URI on Container App '$ContainerAppName'."
    }

    Write-Host "Configured Container App redirect URI: $RedirectUri" -ForegroundColor Green
}
#endregion Functions

#region Main Execution
if ($MyInvocation.InvocationName -ne '.') {
    try {
        $NeedsAzdEnvironment = [string]::IsNullOrWhiteSpace($ResourceGroupName) -or [string]::IsNullOrWhiteSpace($SpaAppClientId)
        if ($NeedsAzdEnvironment) {
            if (-not (Get-Command azd -ErrorAction SilentlyContinue)) {
                throw 'Azure Developer CLI is required to infer values. Install azd or pass -ResourceGroupName and -SpaAppClientId explicitly.'
            }

            $EnvironmentName = Get-AzdEnvironmentName -EnvironmentName $EnvironmentName

            if ([string]::IsNullOrWhiteSpace($ResourceGroupName)) {
                $ResourceGroupName = Get-AzdEnvironmentValue -EnvironmentName $EnvironmentName -Name 'resourceGroupName'
                if ([string]::IsNullOrWhiteSpace($ResourceGroupName)) {
                    throw "azd environment '$EnvironmentName' does not define resourceGroupName. Pass -ResourceGroupName explicitly."
                }
            }

            if ([string]::IsNullOrWhiteSpace($SpaAppClientId)) {
                $SpaAppClientId = Get-AzdEnvironmentValue -EnvironmentName $EnvironmentName -Name 'APP_CLIENT_ID'
                if ([string]::IsNullOrWhiteSpace($SpaAppClientId)) {
                    throw "azd environment '$EnvironmentName' does not define APP_CLIENT_ID. Pass -SpaAppClientId explicitly."
                }
            }
        }

        if ($SpaAppClientId -notmatch '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$') {
            throw "SPA app client ID '$SpaAppClientId' is not a valid GUID."
        }

        if ([string]::IsNullOrWhiteSpace($ContainerAppName)) {
            $ContainerAppName = Get-BranchContainerAppName
        }

        Invoke-BranchRedirectUriUpdate `
            -ResourceGroupName $ResourceGroupName `
            -ContainerAppName $ContainerAppName `
            -SpaAppClientId $SpaAppClientId `
            -Remove:$Remove
    }
    catch {
        Write-Error -ErrorAction Continue "Update-BranchRedirectUri failed: $($_.Exception.Message)"
        exit 1
    }
}
#endregion Main Execution