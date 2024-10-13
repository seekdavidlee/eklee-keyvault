param(
    [string]$BUILD_ENV)

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

dotnet tool install --global AzSolutionManager --version 0.3.0-beta

$solutionId = "keyvault-viewer-v2"

$json = asm lookup resource --asm-rid "app-staticweb" --asm-sol $solutionId --asm-env $BUILD_ENV --logging Info
if ($LastExitCode -ne 0) {
    throw "Error with app-staticweb lookup."
}
$obj = $json | ConvertFrom-Json
$apiKey = az staticwebapp secrets list --name $obj.Name --query "properties.apiKey" | ConvertFrom-Json
"apiKey=$apiKey" >> $env:GITHUB_OUTPUT

$accountName = (GetResource -solutionId $solutionId -environmentName $BUILD_ENV -resourceId "app-ui").Name
if (!$accountName) {
    throw "Unable to find app-ui resource"
}

$appSettingsContent = [System.Environment]::GetEnvironmentVariable('APPSETTINGS')
$appSettingsContent = $appSettingsContent.Replace("%STORAGENAME%", $accountName)
$appSettingsContent | Out-File -FilePath .\EKlee.KeyVault.Client\wwwroot\appsettings.json -Force

$apimName = (GetResource -solutionId $solutionId -environmentName $BUILD_ENV -resourceId "app-apis").Name
if (!$apimName) {
    throw "Unable to get apim name."
}
$groups = asm lookup group --asm-sol $solutionId --asm-env $BUILD_ENV | ConvertFrom-Json
$rgId = $groups[0].GroupId

$url = "https://management.azure.com/$rgId/providers/Microsoft.ApiManagement/service/$apimName/subscriptions/master/listSecrets?api-version=2021-04-01-preview"
# Azure CLI does not support getting subscription key directly, so we must use REST
$apimKeys = az rest --method post --url $url | ConvertFrom-Json
if (!$apimKeys) {
    throw "Unable to get subscription."
}
$configContent = Get-Content .\Deployment\config.json
$configContent = $configContent.Replace("%SUBSCRIPTIONKEY%", $apimKeys.primaryKey)
$configContent = $configContent.Replace("%APIM%", $apimName)

New-Item -Path .\ -Name "outconfigs" -ItemType Directory
Set-Content .\outconfigs\config.json -Value $configContent 

$containerName = "configs"
$end = (Get-Date).AddMinutes(15).ToString("yyyy-MM-ddTHH:mm:ssZ")
$start = (Get-Date).ToString("yyyy-MM-ddTHH:mm:ssZ")
$sas = (az storage container generate-sas --auth-mode login --as-user -n $containerName --account-name $accountName --permissions w --expiry $end --start $start --https-only | ConvertFrom-Json)
if (!$sas) {
    throw "Unable to get a sas key!"
}

azcopy copy .\outconfigs\config.json "https://$accountName.blob.core.windows.net/$containerName/config.json?$sas"