param(
    [string]$BUILD_ENV)

$ErrorActionPreference = "Stop"

dotnet tool install --global Eklee.AzureResourceDiscovery --version 0.1.7-alpha

function GetResourceAndSetInOutput {
    param ($SolutionId, $ResourceId, $EnvName, $OutputKey, [switch]$UseId)

    $json = ard -- -l resource --ard-rid $ResourceId --ard-sol $SolutionId --ard-env $EnvName --disable-console-logging
    if ($LastExitCode -ne 0) {
        throw "Error with resource $ResourceId lookup."
    }

    if (! $json ) {
        return
    }

    $obj = $json | ConvertFrom-Json

    if ($UseId) {
        $objValue = $obj.Name
    }
    else {
        $objValue = $obj.Id
    }

    "$OutputKey=$objValue" >> $env:GITHUB_ENV

    return
}

$solutionId = "keyvault-viewer"
$json = ard -l group --ard-sol $solutionId --ard-env $BUILD_ENV --disable-console-logging
if ($LastExitCode -ne 0) {
    throw "Error with group lookup."
}
$obj = $json | ConvertFrom-Json
$groupName = $obj.Name
"resourceGroupName=$groupName" >> $env:GITHUB_ENV
"prefix=vs" >> $env:GITHUB_ENV

GetResourceAndSetInOutput -SolutionId "shared-services" -EnvName $BUILD_ENV -ResourceId 'shared-key-vault' -OutputKey "sharedkeyVaultName"
GetResourceAndSetInOutput -SolutionId "shared-services" -EnvName $BUILD_ENV -ResourceId 'shared-managed-identity' -OutputKey "keyVaultRefUserId" -UseId

GetResourceAndSetInOutput -SolutionId $solutionId -EnvName $BUILD_ENV -ResourceId 'app-keyvault' -OutputKey "keyVaultName"
GetResourceAndSetInOutput -SolutionId $solutionId -EnvName $BUILD_ENV -ResourceId 'app-apm' -OutputKey "appInsightsName"
GetResourceAndSetInOutput -SolutionId $solutionId -EnvName $BUILD_ENV -ResourceId 'app-svcplan' -OutputKey "appPlanName"
GetResourceAndSetInOutput -SolutionId $solutionId -EnvName $BUILD_ENV -ResourceId 'app-svc' -OutputKey "appName"