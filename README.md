# Introduction
This project demostrates how we leverage Azure RBAC (Role Based Access Control) to secure access to an Azure Key Vault instance. Specifically, we are interested to use this project to understand how a user can access secrets.

## Build Status
![Build status](https://github.com/seekdavidlee/Eklee-KeyVault/actions/workflows/app.yml/badge.svg)

# Setup
The following identity settings need to be configured before the project can be successfully executed. For more info see https://aka.ms/dotnet-template-ms-identity-platform. 

The Domain name would be your Azure Active Directory, usually in the form of [tenant name].onmicrosoft.com. The Tenant Id would also be found in your Azure Active Directory, in the form of a GUID. 

The Client Id and Client Secret would be part of your App Registration process. You can follow the process here to create your App Registration: https://docs.microsoft.com/en-us/azure/active-directory/develop/quickstart-register-app. As a further note when you create your App Registration, your Redirect Url would initially be http://localhost:[port number]. 

The Azure Key Vault name would be the name of your Azure Key Vault. For more information, pay attention to the Azure Key Vault Setup section below.

```
{
	"AzureAd": {
		"Instance": "https://login.microsoftonline.com/",
		"Domain": "",
		"TenantId": "",
		"ClientId": "",
		"ClientSecret": "",
		"CallbackPath": "/signin-oidc"
	},
	"KeyVaultName": "",
	"Logging": {
		"LogLevel": {
			"Default": "Information",
			"Microsoft": "Warning",
			"Microsoft.Hosting.Lifetime": "Information"
		}
	},
	"AllowedHosts": "*"
}
```

## Azure Key Vault Setup
As you are creating your Azure Key Vault, be sure to choose Azure role-based access control for the permission control.

# Azure Key Vault Roles and Usage
There will be a few important roles to take note. The first would be Azure Key Vault Reader and the second would be Azure Key Vault Secrets User.

Per documentation, the **Azure Key Vault Reader** role has the ability to "Read metadata of key vaults and its certificates, keys, and secrets" and the **Azure Key Vault Secrets User** role has the ability to "Read secret contents". 

We can start by assigning all users who has access to Secrets with the **Azure Key Vault Reader** role. As a best practice, we can create a Group in AAD and assign this role to the users for this Azure Key Vault.

Next, if we intend for all users to have access to secrets, we can assign the **Azure Key Vault Secrets User** role to the same Group. Otherwise, we can selectively choose specific secrets and assign the role to authorized users.