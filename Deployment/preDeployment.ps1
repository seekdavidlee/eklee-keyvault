param([string]$EnvironmentName)

$acc = az account show | ConvertFrom-Json
asm apply -f .\manifest.json --asm-env $EnvironmentName -s $acc.id -t $acc.homeTenantId --logging Info

$groupName = "GitHub Deployment"
$groups = az ad group list --display-name $groupName | ConvertFrom-Json

if ($groups.Length -eq 0) {
    throw "$groupName does not exist."
}

$solutionId = "keyvault-viewer"
$obj = asm lookup --type group --asm-sol $solutionId --asm-env $EnvironmentName -s $acc.id -t $acc.homeTenantId --logging Info | ConvertFrom-Json
if ($LastExitCode -ne 0) {
    throw "Error with group lookup."
}

az role assignment create --assignee $groups.Id --role "Contributor" --resource-group $obj.Name