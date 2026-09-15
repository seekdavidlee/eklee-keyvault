#!/usr/bin/env pwsh
#Requires -Version 7.4

<#
.SYNOPSIS
    Exposes and assigns the E2E application role to a user-assigned identity.
.DESCRIPTION
    Ensures that the API app registration exposes an application-only E2E.Tester
    role, then assigns that role to a caller service principal. The caller can
    be a user-assigned managed identity or the GitHub Actions OIDC app. This is
    an Entra application-role assignment, not Azure RBAC on Key Vault or Storage.
.PARAMETER ApiClientId
    The client ID (application ID) of the API app registration.
.PARAMETER ManagedIdentityName
    The name of the user-assigned managed identity used by hosted E2E tests.
.PARAMETER ResourceGroup
    The resource group containing the E2E managed identity. Required when
    ManagedIdentityName is used.
.PARAMETER CallerServicePrincipalObjectId
    The object ID of an existing caller service principal, such as the GitHub
    Actions OIDC app's service principal.
.PARAMETER CallerAppId
    The client ID of an existing caller app registration. Its service principal
    object ID is resolved by the script.
.PARAMETER RoleValue
    The application role value. Defaults to E2E.Tester.
.PARAMETER RoleDisplayName
    The display name used when the role is created.
.PARAMETER RoleDescription
    The description used when the role is created.
.EXAMPLE
    .\assign-e2e-app-role.ps1 `
        -ApiClientId 00000000-0000-0000-0000-000000000000 `
        -ManagedIdentityName eklee-keyvault-dev-e2e `
        -ResourceGroup eklee-keyvault-dev

    .\assign-e2e-app-role.ps1 `
        -ApiClientId 00000000-0000-0000-0000-000000000000 `
        -CallerAppId 11111111-1111-1111-1111-111111111111
.NOTES
    Requires Azure CLI and an account with permission to update app roles and
    app role assignments in Microsoft Entra ID.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$ApiClientId,

    [Parameter(Mandatory = $false)]
    [string]$ManagedIdentityName,

    [Parameter(Mandatory = $false)]
    [string]$ResourceGroup,

    [Parameter(Mandatory = $false)]
    [string]$CallerServicePrincipalObjectId,

    [Parameter(Mandatory = $false)]
    [string]$CallerAppId,

    [Parameter(Mandatory = $false)]
    [ValidateNotNullOrEmpty()]
    [string]$RoleValue = 'E2E.Tester',

    [Parameter(Mandatory = $false)]
    [ValidateNotNullOrEmpty()]
    [string]$RoleDisplayName = 'E2E Tester',

    [Parameter(Mandatory = $false)]
    [ValidateNotNullOrEmpty()]
    [string]$RoleDescription = 'Allows hosted end-to-end tests to call the API as an application.'
)

$ErrorActionPreference = 'Stop'

#region Helpers

function Write-Header {
    <# .SYNOPSIS Writes a section header. #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Message)

    Write-Host "`n$('=' * 80)" -ForegroundColor Cyan
    Write-Host "  $Message" -ForegroundColor Cyan
    Write-Host "$('=' * 80)`n" -ForegroundColor Cyan
}

function Write-Step {
    <# .SYNOPSIS Writes a progress message. #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Message)

    Write-Host "  -> $Message" -ForegroundColor Yellow
}

function Write-Success {
    <# .SYNOPSIS Writes a success message. #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Message)

    Write-Host "  [OK] $Message" -ForegroundColor Green
}

function Invoke-AzJson {
    <#
    .SYNOPSIS
        Runs Azure CLI and parses JSON output.
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments
    )

    $output = & az @Arguments --output json 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Azure CLI command failed: az $($Arguments -join ' ')`n$($output -join [Environment]::NewLine)"
    }

    $json = $output -join [Environment]::NewLine
    if ([string]::IsNullOrWhiteSpace($json)) {
        return $null
    }

    return $json | ConvertFrom-Json
}

function Invoke-AzCommand {
    <#
    .SYNOPSIS
        Runs Azure CLI and fails when the command returns a non-zero exit code.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments
    )

    $output = & az @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Azure CLI command failed: az $($Arguments -join ' ')`n$($output -join [Environment]::NewLine)"
    }
}

function Invoke-GraphPatch {
    <#
    .SYNOPSIS
        Applies a JSON PATCH request through Azure CLI.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][object]$Body
    )

    $tempFile = Join-Path $env:TEMP "graph-patch-$([guid]::NewGuid()).json"
    try {
        $Body | ConvertTo-Json -Depth 20 | Set-Content -Path $tempFile -Encoding utf8
        Invoke-AzCommand @(
            'rest',
            '--method', 'PATCH',
            '--url', $Url,
            '--body', "@$tempFile",
            '--headers', 'Content-Type=application/json',
            '--output', 'none'
        )
    }
    finally {
        Remove-Item $tempFile -ErrorAction SilentlyContinue
    }
}

function Invoke-GraphPost {
    <#
    .SYNOPSIS
        Applies a JSON POST request through Azure CLI.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][object]$Body
    )

    $tempFile = Join-Path $env:TEMP "graph-post-$([guid]::NewGuid()).json"
    try {
        $Body | ConvertTo-Json -Depth 20 | Set-Content -Path $tempFile -Encoding utf8
        Invoke-AzCommand @(
            'rest',
            '--method', 'POST',
            '--url', $Url,
            '--body', "@$tempFile",
            '--headers', 'Content-Type=application/json',
            '--output', 'none'
        )
    }
    finally {
        Remove-Item $tempFile -ErrorAction SilentlyContinue
    }
}

#endregion Helpers

#region Main Execution

function Invoke-E2EAppRoleAssignment {
    <#
    .SYNOPSIS
        Ensures and assigns the E2E application role.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$ApiClientId,
        [Parameter(Mandatory = $false)][string]$ManagedIdentityName,
        [Parameter(Mandatory = $false)][string]$ResourceGroup,
        [Parameter(Mandatory = $false)][string]$CallerServicePrincipalObjectId,
        [Parameter(Mandatory = $false)][string]$CallerAppId,
        [Parameter(Mandatory = $true)][string]$RoleValue,
        [Parameter(Mandatory = $true)][string]$RoleDisplayName,
        [Parameter(Mandatory = $true)][string]$RoleDescription
    )

    Write-Header 'Hosted E2E Application Role Setup'

    Write-Step 'Checking Azure CLI authentication...'
    $account = Invoke-AzJson @('account', 'show')
    Write-Success "Authenticated to tenant $($account.tenantId)"

    $callerPrincipalId = $null
    $callerDescription = $null
    if (-not [string]::IsNullOrWhiteSpace($CallerServicePrincipalObjectId)) {
        if (-not [string]::IsNullOrWhiteSpace($CallerAppId) -or
            -not [string]::IsNullOrWhiteSpace($ManagedIdentityName)) {
            throw 'Specify only one caller: CallerServicePrincipalObjectId, CallerAppId, or ManagedIdentityName.'
        }

        Write-Step "Looking up caller service principal '$CallerServicePrincipalObjectId'..."
        $callerServicePrincipal = Invoke-AzJson @('ad', 'sp', 'show', '--id', $CallerServicePrincipalObjectId)
        $callerPrincipalId = [string]$callerServicePrincipal.id
        $callerDescription = [string]$callerServicePrincipal.displayName
    }
    elseif (-not [string]::IsNullOrWhiteSpace($CallerAppId)) {
        if (-not [string]::IsNullOrWhiteSpace($ManagedIdentityName)) {
            throw 'Specify only one caller: CallerAppId or ManagedIdentityName.'
        }

        Write-Step "Looking up caller app service principal '$CallerAppId'..."
        $callerServicePrincipal = Invoke-AzJson @('ad', 'sp', 'show', '--id', $CallerAppId)
        $callerPrincipalId = [string]$callerServicePrincipal.id
        $callerDescription = [string]$callerServicePrincipal.displayName
    }
    elseif (-not [string]::IsNullOrWhiteSpace($ManagedIdentityName)) {
        if ([string]::IsNullOrWhiteSpace($ResourceGroup)) {
            throw 'ResourceGroup is required when ManagedIdentityName is specified.'
        }

        Write-Step "Looking up managed identity '$ManagedIdentityName'..."
        $managedIdentity = Invoke-AzJson @(
            'identity', 'show',
            '--name', $ManagedIdentityName,
            '--resource-group', $ResourceGroup
        )
        $callerPrincipalId = [string]$managedIdentity.principalId
        $callerDescription = $ManagedIdentityName
    }
    else {
        throw 'Specify one caller: CallerServicePrincipalObjectId, CallerAppId, or ManagedIdentityName.'
    }

    if ([string]::IsNullOrWhiteSpace($callerPrincipalId)) {
        throw "Could not resolve a service principal for '$callerDescription'."
    }
    Write-Success "Found caller '$callerDescription' with principal ID $callerPrincipalId"

    Write-Step "Looking up API app registration '$ApiClientId'..."
    $apiApp = Invoke-AzJson @('ad', 'app', 'show', '--id', $ApiClientId)
    $apiObjectId = [string]$apiApp.id
    if ([string]::IsNullOrWhiteSpace($apiObjectId)) {
        throw 'Could not resolve the API app registration object ID.'
    }
    Write-Success "Found API app registration '$($apiApp.displayName)'"

    Write-Step 'Ensuring the API service principal exists...'
    try {
        $apiServicePrincipal = Invoke-AzJson @('ad', 'sp', 'show', '--id', $ApiClientId)
    }
    catch {
        $apiServicePrincipal = $null
    }

    if (-not $apiServicePrincipal) {
        Invoke-AzJson @('ad', 'sp', 'create', '--id', $ApiClientId) | Out-Null
        $apiServicePrincipal = Invoke-AzJson @('ad', 'sp', 'show', '--id', $ApiClientId)
    }

    $apiServicePrincipalObjectId = [string]$apiServicePrincipal.id
    if ([string]::IsNullOrWhiteSpace($apiServicePrincipalObjectId)) {
        throw 'Could not resolve the API service principal object ID.'
    }
    Write-Success "API service principal object ID: $apiServicePrincipalObjectId"

    $appRoles = @($apiApp.appRoles | Where-Object { $_ } | ForEach-Object {
        [ordered]@{
            allowedMemberTypes = @($_.allowedMemberTypes)
            description        = $_.description
            displayName        = $_.displayName
            id                 = $_.id
            isEnabled          = $_.isEnabled
            value              = $_.value
        }
    })
    $appRole = $appRoles | Where-Object { $_.value -eq $RoleValue } | Select-Object -First 1

    if ($appRole) {
        $allowedMemberTypes = @($appRole.allowedMemberTypes)
        if (-not $appRole.isEnabled -or $allowedMemberTypes -notcontains 'Application') {
            throw "Existing app role '$RoleValue' is disabled or does not allow Application members. Resolve it manually before assigning it to a managed identity."
        }

        Write-Success "API app role '$RoleValue' already exists"
    }
    else {
        Write-Step "Adding API app role '$RoleValue'..."
        $appRole = [ordered]@{
            allowedMemberTypes = @('Application')
            description        = $RoleDescription
            displayName        = $RoleDisplayName
            id                 = [guid]::NewGuid().ToString()
            isEnabled          = $true
            value              = $RoleValue
        }

        Invoke-GraphPatch `
            -Url "https://graph.microsoft.com/v1.0/applications/$apiObjectId" `
            -Body ([ordered]@{ appRoles = @($appRoles + $appRole) })

        Write-Success "Added API app role '$RoleValue'"
    }

    $appRoleId = [string]$appRole.id
    $assignmentUrl = "https://graph.microsoft.com/v1.0/servicePrincipals/$callerPrincipalId/appRoleAssignments"
    Write-Step "Checking the '$callerDescription' application-role assignment..."
    $assignments = Invoke-AzJson @('rest', '--method', 'GET', '--url', $assignmentUrl)
    $existingAssignment = @($assignments.value) | Where-Object {
        $_.resourceId -eq $apiServicePrincipalObjectId -and $_.appRoleId -eq $appRoleId
    } | Select-Object -First 1

    if ($existingAssignment) {
        Write-Success "Caller already has '$RoleValue'"
    }
    else {
        Write-Step "Assigning '$RoleValue' to '$callerDescription'..."
        Invoke-GraphPost `
            -Url $assignmentUrl `
            -Body ([ordered]@{
                principalId = $callerPrincipalId
                resourceId  = $apiServicePrincipalObjectId
                appRoleId   = $appRoleId
            })
        Write-Success "Assigned '$RoleValue' to '$callerDescription'"
    }

    Write-Header 'Setup Complete'
    Write-Information "API client ID:                 $ApiClientId"
    Write-Information "API app role:                  $RoleValue ($appRoleId)"
    Write-Information "E2E caller:                    $callerDescription"
    Write-Information "E2E caller principal:           $callerPrincipalId"
    Write-Information "`nVerify the assignment with:"
    Write-Information "  az rest --method GET --url '$assignmentUrl'"
    Write-Information "`nThe hosted E2E job must acquire a token for:"
    Write-Information "  api://$ApiClientId/.default"
}

if ($MyInvocation.InvocationName -ne '.') {
    try {
        Invoke-E2EAppRoleAssignment `
            -ApiClientId $ApiClientId `
            -ManagedIdentityName $ManagedIdentityName `
            -ResourceGroup $ResourceGroup `
            -CallerServicePrincipalObjectId $CallerServicePrincipalObjectId `
            -CallerAppId $CallerAppId `
            -RoleValue $RoleValue `
            -RoleDisplayName $RoleDisplayName `
            -RoleDescription $RoleDescription
        exit 0
    }
    catch {
        Write-Error "E2E application-role setup failed: $($_.Exception.Message)"
        exit 1
    }
}

#endregion Main Execution