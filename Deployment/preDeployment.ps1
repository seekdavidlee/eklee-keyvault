param([string]$EnvironmentName)

asm apply -f .\manifest.json --asm-env $EnvironmentName --logging Info

$groupName = "GitHub Deployment"
$groups = az ad group list --display-name $groupName | ConvertFrom-Json

if ($groups.Length -eq 0) {
    throw "$groupName does not exist."
}

$solutionId = "keyvault-viewer"
$obj = asm lookup --type group --asm-sol $solutionId --asm-env $EnvironmentName  | ConvertFrom-Json
if ($LastExitCode -ne 0) {
    throw "Error with group lookup."
}

az role assignment create --assignee $groups.Id --role "Contributor" --resource-group $obj.Name