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
        Start-Sleep -Seconds 15
    }
    else {
        $groupId = $groups.id
    }
    return $groupId
}

$solutionId = "keyvault-viewer-v2"

$groups = asm lookup group --asm-sol $solutionId --asm-env $ENVIRONMENT | ConvertFrom-Json
$groupName = $groups[0].Name
$rgId = $groups[0].GroupId

$groupId = CreateAdGroupIfNotExist -GroupName "app-keyvault Secrets Admins" -NickName "app-keyvault-secrets-admin"
az role assignment create --assignee $groupId --role "Key Vault Secrets Officer" --scope $rgId
if ($LastExitCode -ne 0) {        
    throw "Unable to assign role 'Key Vault Secrets Officer' to '$groupId'."
}
$groupId = CreateAdGroupIfNotExist -GroupName "app-keyvault Secrets User" -NickName "app-keyvault-secrets-user"
az role assignment create --assignee $groupId --role "Key Vault Secrets User" --scope $rgId
if ($LastExitCode -ne 0) {        
    throw "Unable to assign role 'Key Vault Secrets User' to '$groupId'."
}