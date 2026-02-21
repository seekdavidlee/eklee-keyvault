$appSettings = Get-Content -Raw -Path "$PSScriptRoot/appsettings.json" | ConvertFrom-Json
$clientId = $appSettings.AzureAd.ClientId
$token = az account get-access-token --scope "api://$clientId/.default" --query "accessToken" -o tsv

Write-Host "Bearer $token"
