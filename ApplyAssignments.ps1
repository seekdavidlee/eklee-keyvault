param(
    [string]$EnvironmentName)

$ErrorActionPreference = "Stop"

function GetResource {
    param (
        [string]$solutionId,
        [string]$environmentName,
        [string]$resourceId
    )
        
    $obj = asm lookup resource --asm-rid $resourceId --asm-sol $solutionId --asm-env $environmentName | ConvertFrom-Json
    if ($LastExitCode -ne 0) {        
        throw "Unable to lookup resource."
    }
        
    return $obj
}

$solutionId = "keyvault-viewer-v2"
Write-Host "get group resource id"
$strId = (GetResource -solutionId $solutionId -environmentName $EnvironmentName -resourceId "app-ui").ResourceId
if (!$strId) {
    throw "unable to get storage id $strId"
}
$userGroupId = az ad group show -g "app-keyvault Secrets User" --query "id" | ConvertFrom-Json
az role assignment create --assignee $userGroupId --role "Storage Blob Data Reader" --scope "$strId/blobServices/default/containers/configs"

$userGroupId = az ad group show -g "app-keyvault Secrets Admins" --query "id" | ConvertFrom-Json
az role assignment create --assignee $userGroupId --role "Storage Blob Data Contributor" --scope "$strId/blobServices/default/containers/configs"