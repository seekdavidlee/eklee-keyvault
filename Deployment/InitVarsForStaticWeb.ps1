param(
    [string]$BUILD_ENV)

$ErrorActionPreference = "Stop"

dotnet tool install --global AzSolutionManager --version 0.3.0-beta

$solutionId = "keyvault-viewer-v2"

$json = asm lookup resource --asm-rid "app-staticweb" --asm-sol $solutionId --asm-env $BUILD_ENV --logging Info
if ($LastExitCode -ne 0) {
    throw "Error with app-staticweb lookup."
}
$obj = $json | ConvertFrom-Json
$apiKey = az staticwebapp secrets list --name $obj.Name --query "properties.apiKey" | ConvertFrom-Json
"apiKey=$apiKey" >> $env:GITHUB_OUTPUT
