#!/usr/bin/env pwsh
# Copyright (c) 2026 Microsoft Corporation. All rights reserved.
# SPDX-License-Identifier: MIT
#Requires -Version 7.4

<#!
.SYNOPSIS
    Deploys the maintainer dev target and configures its hosted E2E identity.

.DESCRIPTION
    Loads exactly one maintainer target from the current user's setup-dev.json,
    configures that target with azd, and deploys it. After a successful
    deployment, it creates or reconciles the dedicated development API
    application registration and service principal. The application-only
    E2E.Tester role is created only for that registration and assigned to the
    existing dev deployment principal.

    The script updates the dev GitHub Environment with the development API
    audience used by deployed Container Apps. It assigns the dedicated dev API
    test role to the existing dev deployment principal, identified by the
    environment's AZURE_CLIENT_ID variable. Configure the environment's
    repository, release-branch, and reviewer protections in GitHub before using
    that principal for hosted E2E.

.PARAMETER GitHubOrganization
    The GitHub organization or user that owns the repository. When omitted with
    GitHubRepoName, the script derives both values from the origin remote.

.PARAMETER GitHubRepoName
    The repository name. When omitted with GitHubOrganization, the script
    derives both values from the origin remote.

.PARAMETER ProfilePath
    Path to the single maintainer target. The target's appRegistrationName is
    the dedicated development API registration and must differ from customer
    registrations for the same Azure target.

.PARAMETER CustomerProfilePath
    Path to the customer target catalog. When it contains the same Microsoft
    Entra tenant, this script rejects a matching appRegistrationName.

.PARAMETER RemoveLegacyE2ERole
    Removes E2E.Tester from an explicitly named legacy maintainer registration
    and caller. Requires -ConfirmLegacyRemoval.

.PARAMETER LegacyApiClientId
    The legacy API application client ID to inspect or remediate.

.PARAMETER LegacyCallerAppId
    The legacy caller application client ID to inspect or remediate.

.PARAMETER ConfirmLegacyRemoval
    Confirms the requested legacy-role mutation.

.EXAMPLE
    ./Setup-Dev.ps1

.EXAMPLE
    ./Setup-Dev.ps1 -RemoveLegacyE2ERole -LegacyApiClientId <api-client-id> -LegacyCallerAppId <caller-client-id> -ConfirmLegacyRemoval
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory = $false)]
    [ValidateNotNullOrEmpty()]
    [string]$ProfilePath = (Join-Path $HOME '.eklee-keyvault\setup-dev.json'),

    [Parameter(Mandatory = $false)]
    [ValidateNotNullOrEmpty()]
    [string]$CustomerProfilePath = (Join-Path $HOME '.eklee-keyvault\setup.json'),

    [Parameter(Mandatory = $false)]
    [string]$GitHubOrganization,

    [Parameter(Mandatory = $false)]
    [string]$GitHubRepoName,

    [Parameter(Mandatory = $false)]
    [switch]$RemoveLegacyE2ERole,

    [Parameter(Mandatory = $false)]
    [string]$LegacyApiClientId,

    [Parameter(Mandatory = $false)]
    [string]$LegacyCallerAppId,

    [Parameter(Mandatory = $false)]
    [switch]$ConfirmLegacyRemoval
)

$ErrorActionPreference = 'Stop'

function Read-MaintainerCustomDomainName {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Prompt
    )

    while ($true) {
        $value = (Read-Host -Prompt $Prompt).Trim().TrimEnd('/')
        $uriCandidate = if ($value -match '^[a-z][a-z0-9+.-]*://') { $value } else { "https://$value" }
        $uri = $null
        if ([uri]::TryCreate($uriCandidate, [UriKind]::Absolute, [ref]$uri) -and
            $uri.Scheme -eq 'https' -and
            -not [string]::IsNullOrWhiteSpace($uri.Host)) {
            return $uri.Host
        }

        Write-Warning 'Enter a valid HTTPS hostname, such as app.example.com.'
    }
}

function Complete-MaintainerDevTargetDomains {
    [CmdletBinding()]
    [OutputType([psobject])]
    param(
        [Parameter(Mandatory = $true)]
        [psobject]$Target,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Path
    )

    $domainPrompts = @(
        [pscustomobject]@{ PropertyName = 'customDevDomainName'; Prompt = 'Permanent main/dev Container App hostname' }
        [pscustomobject]@{ PropertyName = 'customReleaseDomainName'; Prompt = 'Permanent release Container App hostname' }
        [pscustomobject]@{ PropertyName = 'customBranchDomainName'; Prompt = 'Permanent branch Container App hostname' }
    )
    $wasUpdated = $false

    foreach ($domainPrompt in $domainPrompts) {
        $property = $Target.PSObject.Properties[$domainPrompt.PropertyName]
        if ($property -and -not [string]::IsNullOrWhiteSpace([string]$property.Value)) {
            continue
        }

        $value = Read-MaintainerCustomDomainName -Prompt $domainPrompt.Prompt
        if ($property) {
            $property.Value = $value
        }
        else {
            $Target | Add-Member -NotePropertyName $domainPrompt.PropertyName -NotePropertyValue $value
        }

        $wasUpdated = $true
    }

    if ($wasUpdated) {
        $Target | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $Path -Encoding utf8NoBOM
        Write-Host "Saved permanent Container App domains to maintainer profile '$Path'." -ForegroundColor Green
    }

    return $Target
}

function Set-MaintainerApprovedGitHubRepository {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [psobject]$Target,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [ValidatePattern('^[^/\s]+/[^/\s]+$')]
        [string]$Repository
    )

    $property = $Target.PSObject.Properties['approvedGitHubRepository']
    if ($property) {
        $property.Value = $Repository
    }
    else {
        $Target | Add-Member -NotePropertyName 'approvedGitHubRepository' -NotePropertyValue $Repository
    }

    $Target | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $Path -Encoding utf8NoBOM
}

function Get-MaintainerDevTarget {
    [CmdletBinding()]
    [OutputType([psobject])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Maintainer profile '$Path' was not found. Create exactly one target object in setup-dev.json."
    }

    try {
        $target = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    }
    catch {
        throw "Could not read maintainer profile '$Path': $($_.Exception.Message)"
    }

    if ($target.PSObject.Properties['targets']) {
        throw "Maintainer profile '$Path' must contain one target object, not a target catalog."
    }

    $target = Complete-MaintainerDevTargetDomains -Target $target -Path $Path

    foreach ($propertyName in @(
            'displayName', 'tenantId', 'subscriptionId', 'environmentName',
            'location', 'prefix', 'resourceGroupName', 'appRegistrationName',
            'customDevDomainName', 'customReleaseDomainName', 'customBranchDomainName'
        )) {
        $property = $target.PSObject.Properties[$propertyName]
        if (-not $property -or [string]::IsNullOrWhiteSpace([string]$property.Value)) {
            throw "Maintainer profile '$Path' requires a non-empty '$propertyName' property."
        }
    }

    return $target
}

function Assert-DevRegistrationIsDistinct {
    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory = $true)]
        [psobject]$Target,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$CustomerPath
    )

    if (-not (Test-Path -LiteralPath $CustomerPath)) {
        return
    }

    try {
        $customerCatalog = Get-Content -LiteralPath $CustomerPath -Raw | ConvertFrom-Json
    }
    catch {
        throw "Could not read customer profile '$CustomerPath': $($_.Exception.Message)"
    }

    if (-not $customerCatalog.PSObject.Properties['targets']) {
        throw "Customer profile '$CustomerPath' must contain a target catalog."
    }

    $matchingTarget = @($customerCatalog.targets | Where-Object {
            $_.tenantId -eq $Target.tenantId -and
            $_.appRegistrationName -eq $Target.appRegistrationName
        }) | Select-Object -First 1
    if ($null -eq $matchingTarget) {
        return
    }

    $customerAppRegistration = [string]$matchingTarget.appRegistrationName
    if (-not [string]::IsNullOrWhiteSpace($customerAppRegistration) -and
        $customerAppRegistration -eq [string]$Target.appRegistrationName) {
        throw "Maintainer target '$($Target.displayName)' reuses customer app registration '$customerAppRegistration' in the same Microsoft Entra tenant. Configure a distinct appRegistrationName in '$ProfilePath'."
    }
}

function ConvertFrom-GitHubRemoteUrl {
    [CmdletBinding()]
    [OutputType([psobject])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Url
    )

    $match = [regex]::Match(
        $Url.Trim(),
        '^(?:https://|ssh://git@|git@)github\.com(?::|/)(?<owner>[^/\s]+)/(?<repository>[^/\s]+?)(?:\.git)?/?$'
    )
    if (-not $match.Success) {
        throw "Git remote '$Url' is not a supported GitHub origin URL. Supply both -GitHubOrganization and -GitHubRepoName."
    }

    return [pscustomobject]@{
        Organization = $match.Groups['owner'].Value
        Repository = $match.Groups['repository'].Value
    }
}

function Resolve-GitHubRepository {
    [CmdletBinding()]
    [OutputType([psobject])]
    param(
        [Parameter(Mandatory = $false)]
        [string]$Organization,

        [Parameter(Mandatory = $false)]
        [string]$RepositoryName,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$RepositoryPath
    )

    if ([string]::IsNullOrWhiteSpace($Organization) -xor [string]::IsNullOrWhiteSpace($RepositoryName)) {
        throw 'Supply both -GitHubOrganization and -GitHubRepoName, or omit both to use the origin remote.'
    }

    if (-not [string]::IsNullOrWhiteSpace($Organization)) {
        return [pscustomobject]@{
            Organization = $Organization
            Repository = $RepositoryName
        }
    }

    $originUrl = & git -C $RepositoryPath remote get-url origin 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Could not resolve the GitHub origin remote: $($originUrl -join ' '). Supply -GitHubOrganization and -GitHubRepoName."
    }

    return ConvertFrom-GitHubRemoteUrl -Url ($originUrl -join [Environment]::NewLine)
}

function Invoke-AzJson {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments
    )

    $output = & az @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Azure CLI command failed: az $($Arguments -join ' '): $($output -join ' ')"
    }

    return $output | ConvertFrom-Json
}

function Get-ApplicationByDisplayName {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$DisplayName
    )

    $applications = @(Invoke-AzJson -Arguments @('ad', 'app', 'list', '--display-name', $DisplayName, '--output', 'json') |
        Where-Object { $_.displayName -eq $DisplayName })

    if ($applications.Count -gt 1) {
        throw "Multiple application registrations named '$DisplayName' were found. Resolve the duplicate registrations before continuing."
    }

    return $applications | Select-Object -First 1
}

function Get-OrCreateApplication {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$DisplayName
    )

    $application = Get-ApplicationByDisplayName -DisplayName $DisplayName
    if ($null -ne $application) {
        return $application
    }

    $application = Invoke-AzJson -Arguments @(
        'ad', 'app', 'create', '--display-name', $DisplayName,
        '--sign-in-audience', 'AzureADMyOrg', '--output', 'json'
    )
    Write-Host "Created application registration '$DisplayName'." -ForegroundColor Green
    return $application
}

function Get-OrCreateServicePrincipal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ApplicationId
    )

    $output = & az ad sp show --id $ApplicationId --output json 2>$null
    if ($LASTEXITCODE -eq 0) {
        return $output | ConvertFrom-Json
    }

    $servicePrincipal = Invoke-AzJson -Arguments @('ad', 'sp', 'create', '--id', $ApplicationId, '--output', 'json')
    Write-Host "Created service principal for application '$ApplicationId'." -ForegroundColor Green
    return $servicePrincipal
}

function Get-ExistingServicePrincipal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ApplicationId
    )

    $output = & az ad sp show --id $ApplicationId --output json 2>$null
    if ($LASTEXITCODE -ne 0) {
        throw "Service principal for application '$ApplicationId' was not found."
    }

    return $output | ConvertFrom-Json
}

function Invoke-GraphPatch {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Uri,

        [Parameter(Mandatory = $true)]
        [object]$Body
    )

    $temporaryFile = New-TemporaryFile
    try {
        $Body | ConvertTo-Json -Depth 20 | Set-Content -Path $temporaryFile -Encoding utf8
        $output = & az rest --method PATCH --url $Uri --body "@$temporaryFile" --headers 'Content-Type=application/json' --output none 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "Microsoft Graph update failed: $($output -join ' ')"
        }
    }
    finally {
        Remove-Item -Path $temporaryFile -Force -ErrorAction SilentlyContinue
    }
}

function Set-DevelopmentApiRegistration {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [psobject]$Application,

        [Parameter(Mandatory = $true)]
        [string]$DisplayName
    )

    $application = Invoke-AzJson -Arguments @('ad', 'app', 'show', '--id', $Application.appId, '--output', 'json')
    $clientId = [string]$application.appId
    $identifierUri = "api://$clientId"
    $identifierUris = @($application.identifierUris | Where-Object { $_ })

    if ($identifierUris -contains $clientId) {
        throw "Development API '$clientId' has a bare identifier URI. Remove it before continuing."
    }
    if ($identifierUris -notcontains $identifierUri) {
        $identifierUris += $identifierUri
    }

    $api = [ordered]@{}
    foreach ($property in $application.api.PSObject.Properties) {
        $api[$property.Name] = $property.Value
    }
    if ($api['requestedAccessTokenVersion'] -eq 1) {
        throw "Development API '$clientId' requires v1 access tokens. Update it to v2 before continuing."
    }
    $api['requestedAccessTokenVersion'] = 2

    $scopes = @($api['oauth2PermissionScopes'] | Where-Object { $_ })
    $scope = $scopes | Where-Object { $_.value -eq 'access_as_user' } | Select-Object -First 1
    if ($null -eq $scope) {
        $scope = [ordered]@{
            adminConsentDescription = "Allow the application to access $DisplayName on behalf of the signed-in user."
            adminConsentDisplayName = "Access $DisplayName"
            id = [guid]::NewGuid().ToString()
            isEnabled = $true
            type = 'User'
            userConsentDescription = "Allow the application to access $DisplayName on your behalf."
            userConsentDisplayName = "Access $DisplayName"
            value = 'access_as_user'
        }
        $scopes += $scope
    }
    elseif (-not $scope.isEnabled -or $scope.type -ne 'User') {
        throw "Development API scope 'access_as_user' is disabled or incompatible. Resolve it manually before continuing."
    }
    $api['oauth2PermissionScopes'] = @($scopes)

    $azureCliApplicationId = '04b07795-8ddb-461a-bbee-02f9e1bf7b46'
    $preAuthorizedApplications = @($api['preAuthorizedApplications'] | Where-Object { $_ })
    $azureCliPreAuthorization = $preAuthorizedApplications |
        Where-Object { $_.appId -eq $azureCliApplicationId } |
        Select-Object -First 1
    if ($null -eq $azureCliPreAuthorization) {
        $preAuthorizedApplications += [ordered]@{
            appId = $azureCliApplicationId
            delegatedPermissionIds = @($scope.id)
        }
    }
    elseif (@($azureCliPreAuthorization.delegatedPermissionIds) -notcontains $scope.id) {
        $azureCliPreAuthorization.delegatedPermissionIds = @($azureCliPreAuthorization.delegatedPermissionIds + $scope.id)
    }
    $api['preAuthorizedApplications'] = @($preAuthorizedApplications)

    $spa = [ordered]@{}
    foreach ($property in $application.spa.PSObject.Properties) {
        $spa[$property.Name] = $property.Value
    }
    $redirectUris = @($spa['redirectUris'] | Where-Object { $_ })
    if ($redirectUris -notcontains 'http://localhost:5173') {
        $redirectUris += 'http://localhost:5173'
    }
    $spa['redirectUris'] = @($redirectUris)

    Invoke-GraphPatch -Uri "https://graph.microsoft.com/v1.0/applications/$($application.id)" -Body @{
        identifierUris = @($identifierUris)
        api = $api
        spa = $spa
    }

    return Invoke-AzJson -Arguments @('ad', 'app', 'show', '--id', $clientId, '--output', 'json')
}

function Set-E2eApplicationRole {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [psobject]$ApiApplication,

        [Parameter(Mandatory = $true)]
        [psobject]$CallerServicePrincipal,

        [Parameter(Mandatory = $true)]
        [psobject]$ApiServicePrincipal
    )

    $appRoles = @($ApiApplication.appRoles | Where-Object { $_ })
    $e2eRole = $appRoles | Where-Object { $_.value -eq 'E2E.Tester' } | Select-Object -First 1
    if ($null -eq $e2eRole) {
        $e2eRole = [ordered]@{
            allowedMemberTypes = @('Application')
            description = 'Allows the maintainer dev hosted E2E identity to call the dev API.'
            displayName = 'E2E Tester'
            id = [guid]::NewGuid().ToString()
            isEnabled = $true
            value = 'E2E.Tester'
        }
        Invoke-GraphPatch -Uri "https://graph.microsoft.com/v1.0/applications/$($ApiApplication.id)" -Body @{ appRoles = @($appRoles + $e2eRole) }
        $ApiApplication = Invoke-AzJson -Arguments @('ad', 'app', 'show', '--id', $ApiApplication.appId, '--output', 'json')
        $e2eRole = @($ApiApplication.appRoles | Where-Object { $_.value -eq 'E2E.Tester' }) | Select-Object -First 1
    }
    elseif (-not $e2eRole.isEnabled -or @($e2eRole.allowedMemberTypes) -notcontains 'Application') {
        throw "Development API role 'E2E.Tester' is disabled or incompatible. Resolve it manually before continuing."
    }

    $assignments = Invoke-AzJson -Arguments @('rest', '--method', 'GET', '--url', "https://graph.microsoft.com/v1.0/servicePrincipals/$($CallerServicePrincipal.id)/appRoleAssignments", '--output', 'json')
    $assignment = @($assignments.value | Where-Object {
        $_.resourceId -eq $ApiServicePrincipal.id -and $_.appRoleId -eq $e2eRole.id
    }) | Select-Object -First 1
    if ($null -ne $assignment) {
        return
    }

    $temporaryFile = New-TemporaryFile
    try {
        @{
            principalId = $CallerServicePrincipal.id
            resourceId = $ApiServicePrincipal.id
            appRoleId = $e2eRole.id
        } | ConvertTo-Json | Set-Content -Path $temporaryFile -Encoding utf8
        $output = & az rest --method POST --url "https://graph.microsoft.com/v1.0/servicePrincipals/$($CallerServicePrincipal.id)/appRoleAssignments" --body "@$temporaryFile" --headers 'Content-Type=application/json' --output none 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to assign E2E.Tester to the dev deployment principal: $($output -join ' ')"
        }
    }
    finally {
        Remove-Item -Path $temporaryFile -Force -ErrorAction SilentlyContinue
    }

    $assignments = Invoke-AzJson -Arguments @('rest', '--method', 'GET', '--url', "https://graph.microsoft.com/v1.0/servicePrincipals/$($CallerServicePrincipal.id)/appRoleAssignments", '--output', 'json')
    $assignment = @($assignments.value | Where-Object {
        $_.resourceId -eq $ApiServicePrincipal.id -and $_.appRoleId -eq $e2eRole.id
    }) | Select-Object -First 1
    if ($null -eq $assignment) {
        throw 'E2E.Tester assignment was not found after creation for the dev deployment principal.'
    }
}

function Set-GitHubEnvironmentVariable {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Repository,

        [Parameter(Mandatory = $true)]
        [string]$Environment,

        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [string]$Value
    )

    $Value | & gh variable set $Name --repo $Repository --env $Environment
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to set GitHub Environment variable '$Name' in '$Environment'."
    }
}

function Get-GitHubEnvironmentVariable {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Repository,

        [Parameter(Mandatory = $true)]
        [string]$Environment,

        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    $output = & gh variable get $Name --repo $Repository --env $Environment 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to get GitHub Environment variable '$Name' from '$Environment': $($output -join ' ')"
    }

    $value = ($output -join [Environment]::NewLine).Trim()
    if ([string]::IsNullOrWhiteSpace($value)) {
        throw "GitHub Environment variable '$Name' in '$Environment' is empty."
    }

    return $value
}

function Get-AzdEnvironmentValue {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Name
    )

    $output = & azd env get-value $Name 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to get azd environment value '$Name': $($output -join ' ')"
    }

    $value = (($output | Out-String) -split 'Update available:', 2)[0].Trim()
    if ([string]::IsNullOrWhiteSpace($value) -or $value -match '^ERROR') {
        throw "azd environment value '$Name' is empty. Provision the permanent dev targets before configuring GitHub Environment values."
    }

    return $value
}

function Set-GitHubPermanentTargetVariables {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Repository,

        [Parameter(Mandatory = $true)]
        [string]$Environment
    )

    $targetVariables = @(
        [pscustomobject]@{ NameOutput = 'devContainerAppName'; UrlOutput = 'devContainerAppUrl'; NameVariable = 'DEV_CONTAINER_APP_NAME'; UrlVariable = 'DEV_E2E_BASE_URL' }
        [pscustomobject]@{ NameOutput = 'releaseContainerAppName'; UrlOutput = 'releaseContainerAppUrl'; NameVariable = 'RELEASE_CONTAINER_APP_NAME'; UrlVariable = 'RELEASE_E2E_BASE_URL' }
        [pscustomobject]@{ NameOutput = 'branchContainerAppName'; UrlOutput = 'branchContainerAppUrl'; NameVariable = 'BRANCH_CONTAINER_APP_NAME'; UrlVariable = 'BRANCH_E2E_BASE_URL' }
    )

    foreach ($targetVariable in $targetVariables) {
        $containerAppName = Get-AzdEnvironmentValue -Name $targetVariable.NameOutput
        $containerAppUrl = Get-AzdEnvironmentValue -Name $targetVariable.UrlOutput
        if ($containerAppUrl -notmatch '^https://') {
            throw "azd environment value '$($targetVariable.UrlOutput)' must be an HTTPS URL."
        }

        Set-GitHubEnvironmentVariable -Repository $Repository -Environment $Environment -Name $targetVariable.NameVariable -Value $containerAppName
        Set-GitHubEnvironmentVariable -Repository $Repository -Environment $Environment -Name $targetVariable.UrlVariable -Value $containerAppUrl
    }
}

function Set-MaintainerDevAzdEnvironment {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [psobject]$Target,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$RepositoryPath
    )

    Set-AzdEnvironment -Target $Target -RepositoryPath $RepositoryPath

    $domainEnvironmentValues = @(
        [pscustomobject]@{ ProfileProperty = 'customDevDomainName'; EnvironmentName = 'CUSTOM_DEV_DOMAIN_NAME' }
        [pscustomobject]@{ ProfileProperty = 'customReleaseDomainName'; EnvironmentName = 'CUSTOM_RELEASE_DOMAIN_NAME' }
        [pscustomobject]@{ ProfileProperty = 'customBranchDomainName'; EnvironmentName = 'CUSTOM_BRANCH_DOMAIN_NAME' }
    )
    foreach ($domainEnvironmentValue in $domainEnvironmentValues) {
        Invoke-ExternalCommand -CommandName 'azd' -Arguments @(
            'env', 'set', $domainEnvironmentValue.EnvironmentName, ([string]$Target.$($domainEnvironmentValue.ProfileProperty))
        )
    }
}

function Invoke-LegacyE2ERemediation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ApiClientId,

        [Parameter(Mandatory = $true)]
        [string]$CallerAppId,

        [Parameter(Mandatory = $true)]
        [bool]$Remove
    )

    $apiApplication = Invoke-AzJson -Arguments @('ad', 'app', 'show', '--id', $ApiClientId, '--output', 'json')
    $callerPrincipal = Get-ExistingServicePrincipal -ApplicationId $CallerAppId
    $apiPrincipal = Get-ExistingServicePrincipal -ApplicationId $ApiClientId
    $e2eRole = @($apiApplication.appRoles | Where-Object { $_.value -eq 'E2E.Tester' }) | Select-Object -First 1
    if ($null -eq $e2eRole) {
        Write-Host "Legacy API '$ApiClientId' does not expose E2E.Tester." -ForegroundColor Yellow
        return
    }

    $assignments = Invoke-AzJson -Arguments @('rest', '--method', 'GET', '--url', "https://graph.microsoft.com/v1.0/servicePrincipals/$($callerPrincipal.id)/appRoleAssignments", '--output', 'json')
    $assignment = @($assignments.value | Where-Object {
        $_.resourceId -eq $apiPrincipal.id -and $_.appRoleId -eq $e2eRole.id
    }) | Select-Object -First 1
    Write-Host "Legacy E2E role found on API '$ApiClientId': $($null -ne $assignment)." -ForegroundColor Yellow

    if (-not $Remove) {
        return
    }

    if ($null -ne $assignment) {
        $output = & az rest --method DELETE --url "https://graph.microsoft.com/v1.0/servicePrincipals/$($callerPrincipal.id)/appRoleAssignments/$($assignment.id)" --output none 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to remove the legacy E2E role assignment: $($output -join ' ')"
        }
    }

    $remainingRoles = @($apiApplication.appRoles | Where-Object { $_.id -ne $e2eRole.id })
    Invoke-GraphPatch -Uri "https://graph.microsoft.com/v1.0/applications/$($apiApplication.id)" -Body @{ appRoles = $remainingRoles }
    Write-Host "Removed E2E.Tester from explicitly identified legacy API '$ApiClientId'." -ForegroundColor Green
}

if ($MyInvocation.InvocationName -eq '.') {
    return
}

$maintainerTarget = Get-MaintainerDevTarget -Path $ProfilePath
Assert-DevRegistrationIsDistinct -Target $maintainerTarget -CustomerPath $CustomerProfilePath

$setupScriptPath = Join-Path $PSScriptRoot 'Setup.ps1'
if (-not (Test-Path -LiteralPath $setupScriptPath)) {
    throw "Required customer setup helper '$setupScriptPath' was not found."
}

$maintainerProfilePath = $ProfilePath
. $setupScriptPath -ProfilePath $CustomerProfilePath
$ProfilePath = $maintainerProfilePath
foreach ($domainPropertyName in @('customDevDomainName', 'customReleaseDomainName', 'customBranchDomainName')) {
    $maintainerTarget.$domainPropertyName = ConvertTo-CustomDomainName -Value ([string]$maintainerTarget.$domainPropertyName)
}
$githubRepository = Resolve-GitHubRepository `
    -Organization $GitHubOrganization `
    -RepositoryName $GitHubRepoName `
    -RepositoryPath $PSScriptRoot
$GitHubOrganization = $githubRepository.Organization
$GitHubRepoName = $githubRepository.Repository
Set-MaintainerApprovedGitHubRepository `
    -Target $maintainerTarget `
    -Path $ProfilePath `
    -Repository "$GitHubOrganization/$GitHubRepoName"

foreach ($command in @('az', 'azd', 'gh', 'git')) {
    if ($null -eq (Get-Command $command -ErrorAction SilentlyContinue)) {
        throw "Required command '$command' is not available."
    }
}

if ($WhatIfPreference) {
    Write-Host "What if: would deploy maintainer target '$($maintainerTarget.displayName)' with azd and configure its dev E2E API role." -ForegroundColor Cyan
    return
}

Push-Location $PSScriptRoot
try {
    Connect-ToTarget -Target $maintainerTarget
    Set-MaintainerDevAzdEnvironment -Target $maintainerTarget -RepositoryPath $PSScriptRoot

    if (-not $PSCmdlet.ShouldProcess("azd environment '$($maintainerTarget.environmentName)'", 'Run azd up')) {
        return
    }

    Invoke-ExternalCommand -CommandName 'azd' -Arguments @('up')
}
finally {
    Pop-Location
}

if (-not $PSCmdlet.ShouldProcess(
        "maintainer API '$($maintainerTarget.appRegistrationName)'",
    'Configure the dev deployment principal for hosted E2E')) {
    return
}

$account = Invoke-AzJson -Arguments @('account', 'show', '--output', 'json')
$tenantId = [string]$account.tenantId
$resourceGroupExists = & az group exists --name $maintainerTarget.resourceGroupName --output tsv
if ($LASTEXITCODE -ne 0 -or $resourceGroupExists -ne 'true') {
    throw "Resource group '$($maintainerTarget.resourceGroupName)' does not exist in the selected subscription."
}

if ($RemoveLegacyE2ERole) {
    if (-not $ConfirmLegacyRemoval -or [string]::IsNullOrWhiteSpace($LegacyApiClientId) -or [string]::IsNullOrWhiteSpace($LegacyCallerAppId)) {
        throw 'Legacy remediation requires -LegacyApiClientId, -LegacyCallerAppId, and -ConfirmLegacyRemoval.'
    }

    Invoke-LegacyE2ERemediation -ApiClientId $LegacyApiClientId -CallerAppId $LegacyCallerAppId -Remove $true
}
elseif (-not [string]::IsNullOrWhiteSpace($LegacyApiClientId) -or -not [string]::IsNullOrWhiteSpace($LegacyCallerAppId)) {
    if ([string]::IsNullOrWhiteSpace($LegacyApiClientId) -or [string]::IsNullOrWhiteSpace($LegacyCallerAppId)) {
        throw 'Legacy discovery requires both -LegacyApiClientId and -LegacyCallerAppId.'
    }

    Invoke-LegacyE2ERemediation -ApiClientId $LegacyApiClientId -CallerAppId $LegacyCallerAppId -Remove $false
}

$apiApplication = Get-OrCreateApplication -DisplayName $maintainerTarget.appRegistrationName
$apiApplication = Set-DevelopmentApiRegistration -Application $apiApplication -DisplayName $maintainerTarget.appRegistrationName
$apiServicePrincipal = Get-OrCreateServicePrincipal -ApplicationId $apiApplication.appId

$repository = "$GitHubOrganization/$GitHubRepoName"
$output = & gh api --method PUT "repos/$repository/environments/dev" --silent 2>&1
if ($LASTEXITCODE -ne 0) {
    throw "Failed to ensure GitHub Environment 'dev': $($output -join ' ')"
}
Set-GitHubPermanentTargetVariables -Repository $repository -Environment 'dev'
$deploymentClientId = Get-GitHubEnvironmentVariable -Repository $repository -Environment 'dev' -Name 'AZURE_CLIENT_ID'
$deploymentServicePrincipal = Get-ExistingServicePrincipal -ApplicationId $deploymentClientId
Set-E2eApplicationRole -ApiApplication $apiApplication -CallerServicePrincipal $deploymentServicePrincipal -ApiServicePrincipal $apiServicePrincipal

Set-GitHubEnvironmentVariable -Repository $repository -Environment 'dev' -Name 'VITE_AZURE_AD_CLIENT_ID' -Value $apiApplication.appId
Set-GitHubEnvironmentVariable -Repository $repository -Environment 'dev' -Name 'VITE_AZURE_AD_AUTHORITY' -Value "https://login.microsoftonline.com/$tenantId"

[PSCustomObject]@{
    DevelopmentApiClientId = $apiApplication.appId
    DevPrincipalClientId = $deploymentClientId
    RequiredEnvironmentProtections = 'Restrict dev to this repository and release branches, require reviewers, and protect the deployment and hosted E2E variables.'
}
