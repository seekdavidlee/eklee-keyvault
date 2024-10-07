param(
    [string]$rgName,
    [string]$environmentName,    
    [string]$appVersion)

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
$accountName = (GetResource -solutionId $solutionId -environmentName $environmentName -resourceId "app-ui").Name
if (!$accountName) {
    throw "Unable to find app-ui resource"
}

Set-Content .\EKlee.KeyVault.Client\version.txt -Value $appVersion -Force

dotnet publish EKlee.KeyVault.Client\EKlee.KeyVault.Client.csproj -c Release -o outcli

$appSettingsContent = [System.Environment]::GetEnvironmentVariable('APPSETTINGS')
$appSettingsContent = $appSettingsContent.Replace("%STORAGENAME%", $accountName)
$appSettingsContent | Out-File -FilePath outcli\wwwroot\appsettings.json -Force

$indexHtml = Get-Content outcli\wwwroot\index.html
$indexHtml = $indexHtml.Replace("css/app.css?version=0", "css/app.css?version=$appVersion")
Set-Content outcli\wwwroot\index.html -Value $indexHtml -Force

$end = (Get-Date).AddMinutes(15).ToString("yyyy-MM-ddTHH:mm:ssZ")
$start = (Get-Date).ToString("yyyy-MM-ddTHH:mm:ssZ")
$sas = (az storage container generate-sas --auth-mode login --as-user -n `$web --account-name $accountName --permissions racwld --expiry $end --start $start --https-only | ConvertFrom-Json)
if (!$sas) {
    throw "Unable to get a sas key!"
}

azcopy_v10 sync outcli\wwwroot "https://$accountName.blob.core.windows.net/`$web?$sas" --recursive=true --delete-destination=true --compare-hash=MD5
if ($LastExitCode -ne 0) {
    throw "Unable to do az sync."
}