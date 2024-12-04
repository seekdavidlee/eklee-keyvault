# Introduction

This project demostrates how we leverage Azure RBAC (Role Based Access Control) to secure access to an Azure Key Vault instance. Specifically, we are interested to use this project to understand how a user can access secrets. Another goal is to leverage Blazor WASM as a client to access Key Vault secrets without having any custom developed backend service.

The [solution](./Docs/ARCH.md) makes use of Azure API Management (APIM) to proxy calls to Azure Key Vault REST API given Azure Key Vault does not have CORS support. APIM itself is secured by a subscription key. Azure Storage is used to host the Blazor WASM client as a Azure static webapp. Azure Storage is also used to host a runtime config that is downloaded to the Blazor WASM client. The Blazor WASM client will download the config file directly from Azure storage using the user role.

The bicep will ensure when creating Azure Key Vault, we are using Azure role-based access control for the permission control.

### Cost

By default, we are using the Free tier of static web app (for your personal private use) but we are still paying for usage on Azure Storage, Azure API Management and Azure Key Vault. The cost should be minimal if you have usage with less than a few lookup of secrets daily.

### Build Status
![Build status](https://github.com/seekdavidlee/Eklee-KeyVault/actions/workflows/app.yml/badge.svg)

## Automated setup

1. Fork this repo
1. Follow the steps listed under [AzSolutionManager (ASM)](#azsolutionmanager-asm).
1. The app need to be configured. Create an single-tenant app registeration with any name. One suggestion is to use `Eklee.KeyVaultv2`.
1. In API permissions, add `Azure Key Vault` as an API. Select `user_impersonation` and note the default as `Delegated permissions`.
1. In API permissions, add `` as an API. Select `user_impersonation` and note the default as `Delegated permissions`.
1. Select `Grant admin consent for <Tenant>` to grant admin consent.
1. Under GitHub repo settings, create a new environment named `prod`. Create a config for `APPSETTINGS` with the value listed below. Be sure to update the `<Tenant Id>` and `<Client Id>`. The `%STORAGENAME%` will be replaced with the correct value at deployment time.
1. Create 2 more configs `APIM_PUBLISHER_EMAIL` and `APIM_PUBLISHER_NAME` with the appropriate values. This is not really used but required for APIM deployment.
1. Start a Github deployment. Once deployment is completed, locate the app registration in Entra and add `Single-page application`. Look for the Azure static web app URL as the URL to add like so `https://<Static web app>/authentication/login-callback`.
1. Perform appropriate role assignments by following the steps in [Post Deployment RBAC](#post-deployment-rbac).
1. Navigate to `https://<Static web app>` with the appropriate user who is assigned the the group.

### APPSETTINGS

```json
{
	"System": {
		"Header": "KeyVault Client",
		"Footer": "KeyVault Client 2024"
	},
	"StorageUri": "https://%STORAGENAME%.blob.core.windows.net/",
	"StorageContainerName": "configs",
	"AzureAd": {
		"Authority": "https://login.microsoftonline.com/<Tenant Id>",
		"ClientId": "<Client Id>",
		"ValidateAuthority": false,
		"LoginMode": "Redirect"
	}
}
```

## Custom domain

Optionally, if you own a domain name, you can have a sub domain name configured as a variable using the key `CUSTOM_DOMAIN_NAME`. Be sure to do this after the first deployment as you will need to use the dynamic static web app default hostname. 

Once the first deployment completes, follow the steps [here](https://learn.microsoft.com/en-us/azure/static-web-apps/custom-domain) to point your sub domain (CNAME) to the static web app default hostname. You will also need to update the Authentication Url for your app registration in Entra like so `https://<Your Sub Domain>/authentication/login-callback`. The SSL cert will be taken care for you by Azure. We should note the second deployment may take several minutes to complete. If it does not complete in 15 mins, there could be related to an issue with the error `Microsoft.Web/staticSites/customDomains Forbidden`. You will still notice in static web app that it is now using your sub domain. If this is the only error, you can cancel this deployment and safely try to access your app.

## AzSolutionManager (ASM)

This project uses AzSolutionManager (ASM) for deployment to Azure Subscription. To use ASM, please follow the steps.

1. Clone Utility and follow the steps in the README to setup ASM.

```
git clone https://github.com/seekdavidlee/az-solution-manager-utils.git
```

2. Load Utility and apply manifest. Pass in dev or prod for variable like so ``` $environmentName = "dev" ```.

```
az login --tenant <TENANT ID>
Push-Location ..\az-solution-manager-utils\; .\LoadASMToSession.ps1; Pop-Location
$a = az account show | ConvertFrom-Json; Invoke-ASMSetup -DIRECTORY Deployment -TENANT $a.tenantId -SUBSCRIPTION $a.Id -ENVIRONMENT $environmentName
Set-ASMGitHubDeploymentToResourceGroup -SOLUTIONID "keyvault-viewer-v2" -ENVIRONMENT $environmentName -TENANT $a.tenantId -SUBSCRIPTION $a.Id
Set-ASMGitHubDeploymentToResourceGroup -SOLUTIONID "keyvault-viewer-v2" -ENVIRONMENT $environmentName -TENANT $a.tenantId -SUBSCRIPTION $a.Id -ROLENAME "Storage Blob Data Owner"
```

The role `Storage Blob Data Owner` is assigned to `GitHub Deployment` service principal because we need to use azcopy to sync changes to the Storage account using a shared-access-token (sas) key. This gives the service principal permission to generate the appropriate sas key.

## Post Deployment RBAC

There will be a few important roles to take note. The first would be `Azure Key Vault Reader` and the second would be `Azure Key Vault Secrets User`. Per documentation, the **Azure Key Vault Reader** role has the ability to "Read metadata of key vaults and its certificates, keys, and secrets" and the `Azure Key Vault Secrets User` role has the ability to **Read secret contents**. 

We can start by assigning all users who has access to Secrets with the **Azure Key Vault Reader** role. As a best practice, we create Group in Entra and assign this role to the users who need acccess to Azure Key Vault.

There are 2 groups created. `app-keyvault Secrets Admins` and `app-keyvault Secrets User`. The following script will assign RBAC to the 2 groups.

```powershell
.\ApplyAssignments.ps1 -EnvironmentName <dev or prod>
```

You can now assign users to the right group for access.

### Set secret

This is a utility script to set secret.

```powershell
.\SetScret.ps1 -name <name> -value <value> -environmentName <dev or prod>
```

### Out-of-scope

If we intend for all users to have access to secrets, we can assign the **Azure Key Vault Secrets User** role to the same Group. Otherwise, we can selectively choose specific secrets and assign the role to authorized users. The [best practice](https://docs.microsoft.com/en-us/azure/active-directory/roles/best-practices#6-use-groups-for-azure-ad-role-assignments-and-delegate-the-role-assignment) is to assign specific secrets to groups with the appropriate role. This way, we can delegate the assignment to one or more owners without having to invole Azure Administrators.