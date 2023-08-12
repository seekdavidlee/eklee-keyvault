param([string]$EnvironmentName)

$ErrorActionPreference = "Stop"

function GetResource {
    param (
        [string]$solutionId,
        [string]$environmentName,
        [string]$resourceId
    )
    
    $obj = asm lookup --type resource --asm-rid $resourceId --asm-sol $solutionId --asm-env $environmentName  | ConvertFrom-Json
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

$solutionId = "keyvault-viewer"

$kv = GetResource -solutionId $solutionId -environmentName $EnvironmentName -resourceId "app-keyvault"

$groupId = CreateAdGroupIfNotExist -GroupName "app-keyvault Secrets Admins" -NickName "app-keyvault-secrets-admin"
az role assignment create --assignee $groupId --role "Key Vault Secrets Officer" --scope $kv.ResourceId

$groupId = CreateAdGroupIfNotExist -GroupName "app-keyvault Secrets User" -NickName "app-keyvault-secrets-user"
az role assignment create --assignee $groupId --role "Key Vault Secrets User" --scope $kv.ResourceId