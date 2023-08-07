param(
    [string]$BUILD_ENV)

$ErrorActionPreference = "Stop"

dotnet tool install --global Eklee.AzureResourceDiscovery --version 0.1.7-alpha

function GetResourceAndSetInOutput {
    param ($SolutionId, $ResourceId, $EnvName, $OutputKey, [switch]$UseId, [switch]$ThrowIfMissing)

    $json = ard -l resource --ard-rid $ResourceId --ard-sol $SolutionId --ard-env $EnvName --disable-console-logging
    if ($LastExitCode -ne 0) {
        throw "Error with resource $ResourceId lookup."
    }

    if (!$json) {

        if ($ThrowIfMissing) {
            throw "Value for $OutputKey is missing!"
        }
        return
    }

    $obj = $json | ConvertFrom-Json

    if ($UseId) {
        $objValue = $obj.Id
    }
    else {
        $objValue = $obj.Name
    }

    if ($ThrowIfMissing -and !$objValue) {
        throw "Value for $OutputKey is missing!"
    }

    "$OutputKey=$objValue" >> $env:GITHUB_OUTPUT

    return
}

$solutionId = "keyvault-viewer"
$json = ard -l group --ard-sol $solutionId --ard-env $BUILD_ENV --disable-console-logging
if ($LastExitCode -ne 0) {
    throw "Error with group lookup."
}
$obj = $json | ConvertFrom-Json
$groupName = $obj.Name
"resourceGroupName=$groupName" >> $env:GITHUB_OUTPUT
"prefix=vs" >> $env:GITHUB_OUTPUT

GetResourceAndSetInOutput -SolutionId "shared-services" -EnvName "prod" -ResourceId 'shared-key-vault' -OutputKey "sharedkeyVaultName" -ThrowIfMissing
GetResourceAndSetInOutput -SolutionId "shared-services" -EnvName "prod" -ResourceId 'shared-managed-identity' -OutputKey "keyVaultRefUserId" -UseId -ThrowIfMissing

GetResourceAndSetInOutput -SolutionId $solutionId -EnvName $BUILD_ENV -ResourceId 'app-keyvault' -OutputKey "keyVaultName"
GetResourceAndSetInOutput -SolutionId $solutionId -EnvName $BUILD_ENV -ResourceId 'app-apm' -OutputKey "appInsightsName"
GetResourceAndSetInOutput -SolutionId $solutionId -EnvName $BUILD_ENV -ResourceId 'app-svcplan' -OutputKey "appPlanName"
GetResourceAndSetInOutput -SolutionId $solutionId -EnvName $BUILD_ENV -ResourceId 'app-svc' -OutputKey "appName"