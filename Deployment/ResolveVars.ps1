param(
    [string]$BUILD_ENV,
    [string]$RESOURCE_GROUP)

$platformRes = (az resource list --tag stack-name=platform | ConvertFrom-Json)
if (!$platformRes) {
    throw "Unable to find eligible platform resource!"
}

if ($platformRes.Length -eq 0) {
    throw "Unable to find 'ANY' eligible platform resource!"
}

# Platform specific Azure Key Vault as a Shared resource
$akvName = ($platformRes | Where-Object { $_.type -eq 'Microsoft.KeyVault/vaults' -and $_.tags.'stack-environment' -eq $BUILD_ENV }).name

Write-Host "::set-output name=keyVaultName::$akvName"

$keyVaultRefUserId = (az identity list -g $RESOURCE_GROUP | ConvertFrom-Json).id
Write-Host "::set-output name=keyVaultRefUserId::$keyVaultRefUserId"