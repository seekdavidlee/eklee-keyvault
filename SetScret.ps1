param([string] $name, [string] $value, [string]$environmentName)

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

$kvName = (GetResource -solutionId $solutionId -environmentName $environmentName -resourceId "app-keyvault").Name

az keyvault secret set --vault-name $kvName --name $name --value $value