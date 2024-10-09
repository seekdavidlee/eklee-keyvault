param([string]$StorageAccountName, [string]$ResourceGroupName)
$ctx = New-AzStorageContext -StorageAccountName $StorageAccountName -UseConnectedAccount
Enable-AzStorageStaticWebsite -Context $ctx -IndexDocument index.html -ErrorDocument404Path index.html
$storageAccount = Get-AzStorageAccount -ResourceGroupName $ResourceGroupName -Name $StorageAccountName
$DeploymentScriptOutputs = @{}
$DeploymentScriptOutputs['endpoint'] = $storageaccount.PrimaryEndpoints.Web