#!/usr/bin/env pwsh
#Requires -Version 7.4

[CmdletBinding()]
param([string]$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path)

$ErrorActionPreference = 'Stop'
$tokens = $null
$parseErrors = $null
$setupPath = Join-Path $RepoRoot 'Setup.ps1'
$setupAst = [System.Management.Automation.Language.Parser]::ParseFile($setupPath, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count) { throw ($parseErrors | Out-String) }
. $setupPath

$mainAst = $setupAst.EndBlock.Statements[-1]
$mainText = $mainAst.Extent.Text.Replace('exit 0', 'return').Replace('exit 1', "throw 'Setup failed.'")
$mainText = $mainText.Replace('$repositoryPath = $PSScriptRoot', '$repositoryPath = $RepoRoot')
$main = [scriptblock]::Create($mainText)
$assertions = 0
$digest = 'sha256:' + ('a' * 64)
$target = [pscustomobject]@{
    displayName = 'Test'; tenantId = '22222222-2222-2222-2222-222222222222'
    subscriptionId = '11111111-1111-1111-1111-111111111111'
    environmentName = 'existing'; prefix = 'sample'; resourceGroupName = 'sample-rg'
}

function Assert-True {
    param([bool]$Condition, [string]$Label)
    if (-not $Condition) { throw "Assertion failed: $Label" }
    $script:assertions++
}

function Reset-TestState {
    param([string[]]$Answers)
    $script:answers = [System.Collections.Generic.Queue[string]]::new()
    foreach ($answer in $Answers) { $script:answers.Enqueue($answer) }
    $script:calls = [System.Collections.Generic.List[string]]::new()
    $script:failure = ''
    $script:environments = @([pscustomobject]@{ Name = 'existing'; IsDefault = $true })
    $script:environment = @{
        AZURE_SUBSCRIPTION_ID = $target.subscriptionId
        resourceGroupName = $target.resourceGroupName
        containerAppName = 'sample-app'
    }
    $script:containerNames = @('eklee-keyvault')
}

function Assert-CaseThrows {
    param([string]$Pattern)
    try { & $main }
    catch {
        Assert-True ($_.Exception.Message -like $Pattern) "failure matches $Pattern"
        return
    }
    throw "Expected failure matching $Pattern"
}

function Read-Host {
    param([string]$Prompt)
    if (-not $script:answers.Count) { throw "Unexpected prompt: $Prompt" }
    return $script:answers.Dequeue()
}

function azd {
    $global:LASTEXITCODE = 0
    $command = "azd $($args -join ' ')"
    $script:calls.Add($command)
    if ($command -eq $script:failure) { $global:LASTEXITCODE = 1; return }
    if ($command -eq 'azd env list --output json') {
        return ConvertTo-Json -InputObject $script:environments -Compress
    }
    if ($command -eq 'azd env get-values --output json') {
        return ConvertTo-Json $script:environment -Compress
    }
    if ($command -match '^azd env select ' -or
        $command -eq "azd env set CONTAINER_IMAGE ghcr.io/seekdavidlee/eklee-keyvault@$digest" -or
        $command -eq 'azd up') { return }
    throw "Unexpected azd command: $command"
}

function az {
    $global:LASTEXITCODE = 0
    $command = "az $($args -join ' ')"
    $script:calls.Add($command)
    if ($script:failure -and $command.StartsWith($script:failure)) { $global:LASTEXITCODE = 1; return }
    if ($args[0] -eq 'containerapp' -and $args[1] -eq 'show') {
        return ConvertTo-Json -InputObject $script:containerNames -Compress
    }
    if ($args[0] -eq 'containerapp' -and $args[1] -eq 'update') { return }
    throw "Unexpected Azure command: $command"
}

function git {
    $global:LASTEXITCODE = 0
    $script:calls.Add('git origin')
    return 'https://github.com/seekdavidlee/eklee-keyvault.git'
}

function Invoke-RestMethod {
    param($Uri, $Headers, [switch]$UseBasicParsing)
    $script:calls.Add('HTTP metadata')
    if ($Uri -like 'https://api.github.com/*') {
        return @([pscustomobject]@{ tag_name = '1.3.0'; draft = $false; prerelease = $false })
    }
    if ($Uri -like 'https://ghcr.io/token?*') { return [pscustomobject]@{ token = 'fake-test-token' } }
    throw "Unexpected HTTP request: $Uri"
}

function Invoke-WebRequest {
    param($Uri, $Headers, [switch]$UseBasicParsing)
    $script:calls.Add('HTTP manifest')
    if ($script:failure -eq 'manifest') { throw 'Manifest unavailable' }
    Assert-True ($Uri -eq 'https://ghcr.io/v2/seekdavidlee/eklee-keyvault/manifests/1.3.0') 'selected release manifest'
    return [pscustomobject]@{ StatusCode = 200; Headers = @{ 'docker-content-digest' = $digest } }
}

function Get-TargetCatalog { $script:calls.Add('catalog'); return @($target) }
function Select-Target { $script:calls.Add('target'); return $target }
function Set-TargetResourceGroupName { param($Target); $script:calls.Add('resource group'); return $Target }
function Resolve-TargetResourceGroupName { param($Target); $script:calls.Add('reconcile group'); return $Target }
function Set-TargetPrivateNetworking { param($Target); $script:calls.Add('networking'); return $Target }
function Set-TargetCustomDomainName { param($Target); $script:calls.Add('domain'); return $Target }
function Set-TargetAppRegistrationName { param($Target); $script:calls.Add('registration'); return $Target }
function Connect-ToTarget { $script:calls.Add('connect') }
function Set-AzdEnvironment { $script:calls.Add('configure environment') }
function Save-TargetCatalog { throw 'Unexpected catalog write' }

Reset-TestState @('bad', '1', 'Y')
& $main
Assert-True (($script:calls -join '|') -eq 'catalog|target|resource group|reconcile group|networking|domain|registration|connect|configure environment|azd up') 'full setup preserves call sequence'
Assert-True ($script:answers.Count -eq 0) 'invalid selection retries before full setup'

Reset-TestState @('q')
& $main
Assert-True ($script:calls.Count -eq 0) 'quit has no CLI or setup operations'

Reset-TestState @('2', '1')
& $main
$expectedUpdate = "az containerapp update --name sample-app --resource-group sample-rg --subscription $($target.subscriptionId) --container-name eklee-keyvault --image ghcr.io/seekdavidlee/eklee-keyvault@$digest --output none"
Assert-True ($script:calls[-1] -eq $expectedUpdate) 'image-only update uses explicit app, container, subscription, and digest'
Assert-True ($script:calls -contains "azd env set CONTAINER_IMAGE ghcr.io/seekdavidlee/eklee-keyvault@$digest") 'saved image stays aligned with update'
Assert-True (@($script:calls | Where-Object { $_ -match '^azd (up|env new)\b' -or $_ -in @('catalog', 'connect', 'configure environment') }).Count -eq 0) 'version-only bypasses full setup'
Assert-True ($script:answers.Count -eq 0) 'version-only goes directly to release selection without another confirmation'

Reset-TestState @('2')
$WhatIfPreference = $true
try { & $main }
finally { $WhatIfPreference = $false }
Assert-True ($script:calls -contains 'azd env select existing') 'only environment selected without prompting'
Assert-True ($script:answers.Count -eq 0) 'only environment needs no selection answer'
Assert-True ($script:calls.Count -eq 4) 'WhatIf performs only environment listing, selection, and reads'

Reset-TestState @('2', 'bad', '0', '3', '2', '1')
$script:environments = @(
    [pscustomobject]@{ Name = 'dev'; IsDefault = $true }
    [pscustomobject]@{ Name = 'prod'; IsDefault = $false }
)
& $main
Assert-True ($script:calls -contains 'azd env select prod') 'numbered selection chooses the requested environment'
Assert-True ($script:answers.Count -eq 0) 'invalid environment selections retry'
Assert-True ($script:calls[-1] -eq $expectedUpdate) 'multiple environments also proceed directly to release selection'

Reset-TestState @('2')
$script:environments = @()
Assert-CaseThrows '*No existing azd environments*Run full setup first*'
Assert-True ($script:calls.Count -eq 1) 'no environments stops before selection or Azure access'

foreach ($failedCommand in @('azd env list --output json', 'azd env select existing', 'azd env get-values --output json', 'az containerapp show')) {
    Reset-TestState @('2')
    $script:failure = $failedCommand
    Assert-CaseThrows '*Setup failed:*'
    Assert-True (@($script:calls | Where-Object { $_ -match '^azd env set|^az containerapp update' }).Count -eq 0) 'preflight failure prevents image mutation'
}

foreach ($key in @('AZURE_SUBSCRIPTION_ID', 'resourceGroupName', 'containerAppName')) {
    Reset-TestState @('2')
    $script:environment.Remove($key)
    Assert-CaseThrows '*valid AZURE_SUBSCRIPTION_ID*'
    Assert-True ($script:calls.Count -eq 3) 'missing environment output stops before Azure access'
}

Reset-TestState @('2')
$script:containerNames = @('other-container')
Assert-CaseThrows '*does not contain the eklee-keyvault container*'

Reset-TestState @('2', '1')
$script:failure = 'manifest'
Assert-CaseThrows '*Could not resolve the GHCR image tag*'
Assert-True (@($script:calls | Where-Object { $_ -match '^azd env set|^az containerapp update' }).Count -eq 0) 'resolver failure prevents image mutation'

Reset-TestState @('2', '1')
$script:failure = "azd env set CONTAINER_IMAGE ghcr.io/seekdavidlee/eklee-keyvault@$digest"
Assert-CaseThrows '*Failed to set CONTAINER_IMAGE*'
Assert-True (@($script:calls | Where-Object { $_ -match '^az containerapp update' }).Count -eq 0) 'environment write failure prevents Azure update'

Reset-TestState @('2', '1')
$script:failure = 'az containerapp update'
Assert-CaseThrows '*Command failed with exit code 1*'

Write-Host "PASS: $assertions setup assertions; all CLI and HTTP calls were mocked."