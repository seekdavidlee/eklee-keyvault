param(
    [Parameter(Mandatory = $true)][string]$SUBSCRIPTION,
    [Parameter(Mandatory = $true)][string]$TENANT,
    [Parameter(Mandatory = $true)][string]$ENVIRONMENT,
    [Parameter(Mandatory = $false)][string]$REGION)

$ErrorActionPreference = "Stop"

function GetResource {
    param (
        [string]$solutionId,
        [string]$environmentName,
        [string]$resourceId
    )
    
    $obj = asm lookup resource --asm-rid $resourceId --asm-sol $solutionId --asm-env $environmentName  | ConvertFrom-Json
    if ($LastExitCode -ne 0) {
        Pop-Location
        throw "Unable to lookup resource."
    }
    
    return $obj
}

function CreateAdGroupIfNotExist {
    param (
        [string]$GroupName,
        [string]$NickName
    )
    $groups = az ad group list --display-name $GroupName | ConvertFrom-Json
    if ($groups.Length -eq 0) {
        $result = az ad group create --display-name $groupName --mail-nickname $NickName | ConvertFrom-Json
        if ($LastExitCode -ne 0) {
            Pop-Location
            throw "Unable to create group $groupName."
        }
        $groupId = $result.id
    }
    else {
        $groupId = $groups.id
    }
    return $groupId
}

$sharedKv = GetResource -solutionId "shared-services" -environmentName "prod" -resourceId "shared-key-vault"
$sharedKvName = $sharedKv.Name
$appId = az keyvault secret show --name "keyvault-viewer-client-id" --vault-name $sharedKvName --query "value" | ConvertFrom-Json

$solutionId = "keyvault-viewer"

$svc = GetResource -solutionId $solutionId -environmentName $ENVIRONMENT -resourceId "app-svc"
$svcName = $svc.Name
az ad app update --id $appId --web-redirect-uris "https://$svcName.azurewebsites.net/signin-oidc"

Write-Host "Url: https://$svcName.azurewebsites.net"

$kv = GetResource -solutionId $solutionId -environmentName $ENVIRONMENT -resourceId "app-keyvault"

$groupId = CreateAdGroupIfNotExist -GroupName "app-keyvault Secrets Admins" -NickName "app-keyvault-secrets-admin"
az role assignment create --assignee $groupId --role "Key Vault Secrets Officer" --scope $kv.ResourceId

$groupId = CreateAdGroupIfNotExist -GroupName "app-keyvault Secrets User" -NickName "app-keyvault-secrets-user"
az role assignment create --assignee $groupId --role "Key Vault Secrets User" --scope $kv.ResourceId