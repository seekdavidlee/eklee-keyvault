param([string]$ResourceGroup, [string]$ServiceName)

dotnet publish -c Release -o out
$appFileName = "pub.zip"
Compress-Archive out\* -DestinationPath $appFileName -Force

az functionapp deployment source config-zip -g $ResourceGroup -n $ServiceName --src $appFileName
if ($LastExitCode -ne 0) {
    throw "An error has occured. Unable to deploy service."
}