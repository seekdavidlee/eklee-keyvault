param([string]$EnvironmentName)

$acc = az account show | ConvertFrom-Json
asm manifest apply -f .\manifest.json --asm-env $EnvironmentName -s $acc.id -t $acc.homeTenantId --logging Info

$groupName = "GitHub Deployment"
$groups = az ad group list --display-name $groupName | ConvertFrom-Json

if ($groups.Length -eq 0) {
    throw "$groupName does not exist."
}

$solutionId = "keyvault-viewer"
asm role assign --role-name "Contributor" `
    --principal-id $groups.Id `
    --principal-type "Group" `
    --asm-sol $solutionId `
    --asm-env $EnvironmentName `
    -s $acc.id `
    -t $acc.homeTenantId --logging Info
if ($LastExitCode -ne 0) {
    throw "Error with role assignment."
}

