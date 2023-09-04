param(
    [string]$BUILD_ENV)

$ErrorActionPreference = "Stop"

dotnet tool install --global azsolutionmanager --version 0.1.6-beta

function GetResourceAndSetInOutput {
    param ($SolutionId, $ResourceId, $EnvName, $OutputKey, [switch]$UseId, [switch]$ThrowIfMissing)

    $json = asm lookup resource --asm-rid $ResourceId --asm-sol $SolutionId --asm-env $EnvName --logging Info
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
        $objValue = $obj.ResourceId
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
$json = asm lookup group --asm-sol $solutionId --asm-env $BUILD_ENV --logging Info
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