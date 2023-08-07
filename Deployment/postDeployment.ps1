param([string]$EnvironmentName)

$ErrorActionPreference = "Stop"

function GetResource {
    param (
        [string]$solutionId,
        [string]$environmentName,
        [string]$resourceId
    )
    
    $obj = ard -- -l resource --ard-rid $resourceId --ard-sol $solutionId --ard-env $environmentName --disable-console-logging | ConvertFrom-Json
    if ($LastExitCode -ne 0) {
        Pop-Location
        throw "Unable to lookup resource."
    }
    
    return $obj
}

function CreateGroupIfNotExist {
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

$groupId = CreateGroupIfNotExist -GroupName "app-keyvault Secrets Admins" -NickName "app-keyvault-secrets-admin"
az role assignment create --assignee $groupId --role "Key Vault Secrets Officer" --scope $kv.ResourceId

$groupId = CreateGroupIfNotExist -GroupName "app-keyvault Secrets User" -NickName "app-keyvault-secrets-user"
az role assignment create --assignee $groupId --role "Key Vault Secrets User" --scope $kv.ResourceId