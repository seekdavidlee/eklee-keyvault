# Eklee KeyVault Infrastructure Deployment

This folder contains the infrastructure as code (IaC) for deploying the Eklee KeyVault application to Azure using Bicep.

## 📋 Overview

The infrastructure includes:

- **Azure Container Apps Environment** - Managed serverless container hosting
- **User-Assigned Managed Identity** - For future Container App authentication
- **Azure Storage Account** - For application data and blob storage
- **Azure Key Vault** - For secure secrets and key management
- **Log Analytics Workspace** - For application monitoring and logging
- **RBAC Role Assignments** - Managed via the [direct-user script](../Scripts/assign-mi-rbac.ps1)
- **(Optional) Virtual Network** - VNET with subnets for Container Apps and private endpoints
- **(Optional) Private Endpoints** - Secure connectivity to Storage Account and Key Vault

## 🏗️ Architecture

```mermaid
graph TB
    A[Container Apps Environment] --> F[Log Analytics Workspace]
    B[User-Assigned Managed Identity] 
    C[Key Vault]
    D[Storage Account]
    G[Scripts/assign-mi-rbac.ps1] -.Assigns Permissions.-> B
    G -.Secrets User.-> C
    G -.Blob Contributor.-> D
    
    style A fill:#0078d4,stroke:#fff,stroke-width:2px,color:#fff
    style B fill:#ffb900,stroke:#fff,stroke-width:2px,color:#000
    style C fill:#f25022,stroke:#fff,stroke-width:2px,color:#fff
    style D fill:#7fba00,stroke:#fff,stroke-width:2px,color:#fff
    style G fill:#e3e3e3,stroke:#333,stroke-width:2px,color:#000
```

> **Note:** This deployment prepares the infrastructure foundation. Azure RBAC roles are assigned via the [Scripts/assign-mi-rbac.ps1](../Scripts/assign-mi-rbac.ps1) script after deployment. The Container App itself will be deployed separately using the pre-configured managed identity and public GHCR image.

## 📂 Files

| File | Description |
|------|-------------|
| `main.bicep` | Main infrastructure template |
| `networking.bicep` | Private networking module (VNET, NSGs, DNS zones, private endpoints) |
| `README.md` | This file |

## 🚀 Prerequisites

Before deploying, ensure you have:

1. **Azure CLI** installed and authenticated
   ```powershell
   az --version
   az login
   ```

2. **Public GHCR package** containing the application image
  - `ghcr.io/seekdavidlee/eklee-keyvault`
  - No Azure registry or registry credentials are required

3. **Required permissions** in your Azure subscription
   - Contributor role on the resource group
   - User Access Administrator (for RBAC assignments)

4. **Bicep CLI** (automatically installed with Azure CLI 2.20.0+)
   ```powershell
   az bicep version
   ```

## 📝 Configuration

### Review Resource Names

The template generates unique names for resources using the pattern:

- Storage Account: `{applicationName}{environment}{uniqueHash}` (e.g., `ekleekvdev8a7b9c2d`)
- Key Vault: `{applicationName}-{environment}-{hash}` (e.g., `ekleekv-dev-a7b9c2`)
- Container App: `{applicationName}-{environment}-app` (e.g., `ekleekv-dev-app`)

## GitHub Actions E2E Resource Discovery

The `dev` E2E job discovers the Key Vault and Storage Account after Azure OIDC
login. It scopes discovery to the environment's `RESOURCE_GROUP` variable and
matches the tags applied by `main.bicep`:

- `Application=Eklee-KeyVault`
- `Environment=dev` for the development workflow

Exactly one matching Key Vault and one matching Storage Account are required.
Missing or multiple matches stop the workflow with the resource group, target
environment, and required tags in the diagnostic message. The workflow derives
the Key Vault URI from `properties.vaultUri` and the Storage Account URI from
`properties.primaryEndpoints.blob`.

`E2E_KEYVAULT_URI` and `E2E_STORAGE_URI` remain optional environment variables.
When provided, each value is an explicit override. The workflow validates the
URI format and confirms that the named resource exists in `RESOURCE_GROUP`
before continuing with the existing RBAC, network access, readiness, and
cleanup checks.

The GitHub Actions identity must be able to list resource metadata and read the
selected Key Vault and Storage Account. The current deployment setup grants
`Contributor` on the environment resource group, which includes these lookup
operations. Resource identification does not require secret values or storage
account keys.

## 🎯 Deployment

### Deploy with Azure CLI

#### Development Environment

```powershell
# Set variables
$resourceGroup = "eklee-keyvault-dev-rg"
$location = "eastus"

# Create resource group
az group create --name $resourceGroup --location $location

# Deploy infrastructure
az deployment group create `
  --resource-group $resourceGroup `
  --template-file main.bicep `
  --name "eklee-keyvault-deployment-$(Get-Date -Format 'yyyyMMdd-HHmmss')" `
  --parameters enablePrivateNetworking=true

# Assign managed identity RBAC roles (required after deployment)
..\Scripts\assign-mi-rbac.ps1 `
  -ResourceGroup $resourceGroup
```

> **Note:** Set `enablePrivateNetworking` to `true` (default in the GitHub Actions workflow) to deploy with a VNET, private endpoints for Storage and Key Vault, and disabled public network access. Set to `false` for public network access.

#### Production Environment

```powershell
# Set variables
$resourceGroup = "eklee-keyvault-prod-rg"
$location = "eastus"

# Create resource group
az group create --name $resourceGroup --location $location

# Deploy infrastructure
az deployment group create `
  --resource-group $resourceGroup `
  --template-file main.bicep `
  --name "eklee-keyvault-deployment-$(Get-Date -Format 'yyyyMMdd-HHmmss')"

# Assign managed identity RBAC roles (required after deployment)
..\Scripts\assign-mi-rbac.ps1 `
  -ResourceGroup $resourceGroup
```

### Deploy with What-If Analysis

Preview changes before deployment:

```powershell
az deployment group what-if `
  --resource-group $resourceGroup `
  --template-file main.bicep
```

## 🔐 Assign RBAC Roles

After deploying the infrastructure, you must assign RBAC roles to the managed identity. This is handled by a separate PowerShell script.

### Why Separate RBAC Assignment?

RBAC role assignments are managed outside of Bicep to:
- Provide finer control over permissions timing
- Avoid deployment delays due to role propagation
- Simplify troubleshooting of permission issues
- Support cross-subscription role assignments more easily

### Assign Roles

```powershell
# Run the RBAC assignment script
..\Scripts\assign-mi-rbac.ps1 `
  -ResourceGroup eklee-keyvault-dev-rg
```

The script assigns these roles to the managed identity:
- **Key Vault Secrets Officer** - Read and manage secrets in Key Vault
- **Storage Blob Data Contributor** - Access blob storage data

### Verify Role Assignments

```powershell
# List all role assignments for the managed identity
az role assignment list --assignee <principal-id> --output table
```

## 🔐 Security Features

The deployment implements several security best practices:

### ✅ User-Assigned Managed Identity
- Pre-configured identity for Container App
- Passwordless authentication to Azure services
- No credentials in configuration or code

### ✅ RBAC Assignments (via PowerShell Script)
- **Key Vault Secrets Officer** - Read and manage secrets in Key Vault
- **Storage Blob Data Contributor** - Access blob storage
- Assigned separately for better control and troubleshooting

### ✅ Network Security
- HTTPS-only traffic enforced
- TLS 1.2 minimum for Storage Account
- Azure Services bypass for firewalls
- Optional private networking mode with VNET, private endpoints, and disabled public access
- Container Apps Environment integrates with VNET when private networking is enabled
- Private DNS zones for Storage and Key Vault name resolution
- Network Security Groups (NSGs) on both subnets when private networking is enabled:
  - **Container Apps subnet**: Allows VNET inbound/outbound traffic and HTTPS outbound to Internet
  - **Resource subnet**: Allows HTTPS inbound from VNET only, denies all Internet inbound

### ✅ Key Vault Configuration
- Soft delete enabled (90-day retention)
- RBAC authorization enabled
- Purge protection enabled for production
- Premium SKU for production (HSM-backed keys)

### ✅ Storage Security
- Public blob access disabled
- Shared key access controlled
- Default to OAuth authentication
- Encryption at rest with Microsoft-managed keys

## 📊 Post-Deployment

After successful deployment, the following outputs are available:

```powershell
# Get deployment outputs
az deployment group show `
  --resource-group $resourceGroup `
  --name eklee-keyvault-deployment `
  --query properties.outputs
```

### Available Outputs

| Output | Description |
|--------|-------------|
| `keyVaultName` | Name of the Key Vault |
| `keyVaultUri` | Key Vault URI for application configuration |
| `storageAccountName` | Name of the Storage Account |
| `containerAppEnvironmentName` | Name of the Container Apps Environment |
| `containerAppEnvironmentId` | Resource ID of the Container Apps Environment |
| `managedIdentityName` | Name of the user-assigned managed identity |
| `managedIdentityClientId` | Client ID for the managed identity |
| `managedIdentityPrincipalId` | Principal ID for RBAC assignments |
| `managedIdentityId` | Full resource ID of the managed identity |
| `virtualNetworkName` | Name of the Virtual Network (empty if private networking is disabled) |

## 🔧 Common Tasks

### Deploy Container App Using the Managed Identity

After infrastructure deployment, use the managed identity to deploy your Container App:

```powershell
# Get the managed identity resource ID
$identityId = az deployment group show `
  --resource-group $resourceGroup `
  --name eklee-keyvault-deployment `
  --query "properties.outputs.managedIdentityId.value" -o tsv

# Get the environment ID
$envId = az deployment group show `
  --resource-group $resourceGroup `
  --name eklee-keyvault-deployment `
  --query "properties.outputs.containerAppEnvironmentId.value" -o tsv

# Deploy Container App
az containerapp create `
  --name ekleekv-dev-app `
  --resource-group $resourceGroup `
  --environment $envId `
  --image ghcr.io/seekdavidlee/eklee-keyvault:latest `
  --user-assigned $identityId `
  --ingress external `
  --target-port 8080 `
  --cpu 0.5 `
  --memory 1Gi
```

### Update Container Image

```powershell
# Update the container app with a new image
az containerapp update `
  --name ekleekv-dev-app `
  --resource-group $resourceGroup `
  --image ghcr.io/seekdavidlee/eklee-keyvault:latest
```

### View Logs

```powershell
# Stream container app logs
az containerapp logs show `
  --name ekleekv-dev-app `
  --resource-group $resourceGroup `
  --follow
```

### Scale Container App

```powershell
# Scale replicas
az containerapp update `
  --name ekleekv-dev-app `
  --resource-group $resourceGroup `
  --min-replicas 2 `
  --max-replicas 15
```

### Add Secret to Key Vault

```powershell
# Add a secret
az keyvault secret set `
  --vault-name ekleekv-dev-a7b9c2 `
  --name "ApiKey" `
  --value "your-secret-value"
```

## 🧪 Testing

### Validate Deployment

```powershell
# Check if Container Apps Environment is ready
az containerapp env show `
  --name ekleekv-dev-env `
  --resource-group $resourceGroup `
  --query "properties.provisioningState"

# Verify managed identity
az identity show `
  --name ekleekv-dev-identity `
  --resource-group $resourceGroup `
  --query "{name:name, principalId:principalId, clientId:clientId}"
```

### Verify RBAC Assignments

```powershell
# List role assignments for the managed identity
$principalId = az identity show `
  --name ekleekv-dev-identity `
  --resource-group $resourceGroup `
  --query "principalId" -o tsv

az role assignment list --assignee $principalId --output table
```

## 🗑️ Cleanup

To delete all resources:

```powershell
# Delete resource group and all resources
az group delete --name $resourceGroup --yes --no-wait
```

## 🚀 Quick Reference

Quick commands for common operations with your deployed infrastructure.

### RBAC Operations

#### Assign Roles to Managed Identity
```powershell
# Assign all required roles at once
..\Scripts\assign-mi-rbac.ps1 -ResourceGroup eklee-keyvault-dev-rg
```

#### Verify Role Assignments
```powershell
# Get managed identity principal ID
$principalId = az identity show --name ekleekv-dev-identity --resource-group eklee-keyvault-dev-rg --query principalId -o tsv

# List all role assignments
az role assignment list --assignee $principalId --output table

```

#### Remove Role Assignments
```powershell
# Remove all assignments for the identity
az role assignment list --assignee $principalId --query "[].id" -o tsv | ForEach-Object { az role assignment delete --ids $_ }
```

### Validation & Monitoring

#### Check Deployment Status
```powershell
az deployment group show --resource-group eklee-keyvault-dev-rg --name eklee-keyvault-20250221-143000
```

#### View Logs
```powershell
# Container App logs
az containerapp logs show --name ekleekv-dev-app --resource-group eklee-keyvault-dev-rg --follow

# Log Analytics query
az monitor log-analytics query --workspace {workspace-id} --analytics-query "ContainerAppConsoleLogs_CL | take 100"
```

### Container App Operations

#### Update Container Image
```powershell
# Update to new version
az containerapp update --name ekleekv-dev-app --resource-group eklee-keyvault-dev-rg --image ghcr.io/seekdavidlee/eklee-keyvault:latest

# Restart container app
az containerapp revision restart --name ekleekv-dev-app --resource-group eklee-keyvault-dev-rg
```

#### Scale Container App
```powershell
# Update scaling rules
az containerapp update --name ekleekv-dev-app --resource-group eklee-keyvault-dev-rg --min-replicas 2 --max-replicas 15

# View current replicas
az containerapp show --name ekleekv-dev-app --resource-group eklee-keyvault-dev-rg --query "properties.template.scale"
```

#### Manage Revisions
```powershell
# List revisions
az containerapp revision list --name ekleekv-dev-app --resource-group eklee-keyvault-dev-rg --output table

# Activate specific revision
az containerapp revision activate --name ekleekv-dev-app--{revision-suffix} --resource-group eklee-keyvault-dev-rg

# Deactivate revision
az containerapp revision deactivate --name ekleekv-dev-app--{revision-suffix} --resource-group eklee-keyvault-dev-rg
```

### Key Vault Operations

#### Add Secrets
```powershell
# Add a secret
az keyvault secret set --vault-name ekleekv-dev-a7b9c2 --name "ApiKey" --value "secret-value"

# Import certificate
az keyvault certificate import --vault-name ekleekv-dev-a7b9c2 --name "ssl-cert" --file certificate.pfx --password "cert-password"

# List secrets
az keyvault secret list --vault-name ekleekv-dev-a7b9c2 --output table
```

#### Access Control
```powershell
# Grant user access to secrets
az role assignment create --assignee user@domain.com --role "Key Vault Secrets User" --scope /subscriptions/{sub-id}/resourceGroups/eklee-keyvault-dev-rg/providers/Microsoft.KeyVault/vaults/ekleekv-dev-a7b9c2

# List role assignments
az role assignment list --scope /subscriptions/{sub-id}/resourceGroups/eklee-keyvault-dev-rg/providers/Microsoft.KeyVault/vaults/ekleekv-dev-a7b9c2
```

### Storage Account Operations

#### Manage Containers
```powershell
# List containers
az storage container list --account-name ekleekvdev8a7b9c2d --auth-mode login

# Create container
az storage container create --name app-data --account-name ekleekvdev8a7b9c2d --auth-mode login

# Set RBAC
az role assignment create --assignee {principal-id} --role "Storage Blob Data Contributor" --scope /subscriptions/{sub-id}/resourceGroups/eklee-keyvault-dev-rg/providers/Microsoft.Storage/storageAccounts/ekleekvdev8a7b9c2d
```

#### Upload Files
```powershell
# Upload file to blob storage
az storage blob upload --account-name ekleekvdev8a7b9c2d --container-name app-data --name myfile.json --file ./myfile.json --auth-mode login

# List blobs
az storage blob list --account-name ekleekvdev8a7b9c2d --container-name app-data --auth-mode login --output table
```

### Networking & Custom Domains

#### Add Custom Domain
```powershell
# Add custom domain to Container App
az containerapp hostname add --hostname www.example.com --name ekleekv-dev-app --resource-group eklee-keyvault-dev-rg

# Bind certificate
az containerapp hostname bind --hostname www.example.com --name ekleekv-dev-app --resource-group eklee-keyvault-dev-rg --certificate {cert-id}
```

#### View Endpoints
```powershell
# Get Container App URL
az containerapp show --name ekleekv-dev-app --resource-group eklee-keyvault-dev-rg --query "properties.latestRevisionFqdn" -o tsv

# Get ingress configuration
az containerapp show --name ekleekv-dev-app --resource-group eklee-keyvault-dev-rg --query "properties.configuration.ingress"
```

### Resource Information

#### Get Resource Details
```powershell
# List all resources in resource group
az resource list --resource-group eklee-keyvault-dev-rg --output table

# Get Container App details
az containerapp show --name ekleekv-dev-app --resource-group eklee-keyvault-dev-rg

# Get managed identity
az containerapp show --name ekleekv-dev-app --resource-group eklee-keyvault-dev-rg --query "identity.principalId" -o tsv
```

#### Cost Analysis
```powershell
# View costs for resource group (requires Cost Management + Billing reader role)
az consumption usage list --start-date 2025-02-01 --end-date 2025-02-28

# View Container App costs
az containerapp show --name ekleekv-dev-app --resource-group eklee-keyvault-dev-rg --query "properties.template.containers[0].resources"
```

### Cleanup Operations

#### Automated Merge Cleanup

The `cleanup-container-app.yml` workflow runs after same-repository pull requests
are merged. It removes the temporary Container App and matching public GHCR image:

- Merging a normal branch into `release/*` deletes its `ekv-branch-*` Container App
  and `branch-<normalized-branch>` image tag.
- Merging `release/<version>` into `main` deletes its `ekv-release-*` Container App
  and `release-<normalized-version>` image tag.

The cleanup is idempotent when either resource is already absent and never targets
the long-lived `main` Container App or its production image tags.

#### Delete Individual Resources
```powershell
# Delete Container App (keeps environment)
az containerapp delete --name ekleekv-dev-app --resource-group eklee-keyvault-dev-rg --yes

# Delete environment variables
az containerapp update --name ekleekv-dev-app --resource-group eklee-keyvault-dev-rg --remove-env-vars VAR_NAME
```

#### Complete Cleanup
```powershell
# Delete entire resource group
az group delete --name eklee-keyvault-dev-rg --yes --no-wait

# Purge soft-deleted Key Vault
az keyvault purge --name ekleekv-dev-a7b9c2 --no-wait
```

### Environment Variables

#### Update Environment Variables
```powershell
# Add environment variable
az containerapp update --name ekleekv-dev-app --resource-group eklee-keyvault-dev-rg --set-env-vars NEW_VAR="value"

# Update existing variable
az containerapp update --name ekleekv-dev-app --resource-group eklee-keyvault-dev-rg --replace-env-vars EXISTING_VAR="new-value"

# Remove variable
az containerapp update --name ekleekv-dev-app --resource-group eklee-keyvault-dev-rg --remove-env-vars VAR_NAME
```

#### Reference Secrets
```powershell
# Add secret
az containerapp secret set --name ekleekv-dev-app --resource-group eklee-keyvault-dev-rg --secrets "secret-name=secret-value"

# Use secret in environment variable
az containerapp update --name ekleekv-dev-app --resource-group eklee-keyvault-dev-rg --set-env-vars "API_KEY=secretref:secret-name"
```

### Useful Queries

#### Find Resource IDs
```powershell
# Container App ID
az containerapp show --name ekleekv-dev-app --resource-group eklee-keyvault-dev-rg --query "id" -o tsv

# Key Vault ID
az keyvault show --name ekleekv-dev-a7b9c2 --resource-group eklee-keyvault-dev-rg --query "id" -o tsv

# Storage Account ID
az storage account show --name ekleekvdev8a7b9c2d --resource-group eklee-keyvault-dev-rg --query "id" -o tsv
```

#### Export Configuration
```powershell
# Export Container App configuration
az containerapp show --name ekleekv-dev-app --resource-group eklee-keyvault-dev-rg > container-app-config.json

# Export as Bicep
az bicep decompile --file template.json
```

## 📚 Additional Resources

- [Azure Container Apps Documentation](https://learn.microsoft.com/en-us/azure/container-apps/)
- [Azure Key Vault Best Practices](https://learn.microsoft.com/en-us/azure/key-vault/general/best-practices)
- [Bicep Language Reference](https://learn.microsoft.com/en-us/azure/azure-resource-manager/bicep/)
- [Managed Identity Overview](https://learn.microsoft.com/en-us/azure/active-directory/managed-identities-azure-resources/)

## 🐛 Troubleshooting

### Issue: Managed Identity not created

**Solution:** Check deployment logs:
```powershell
az deployment group show --resource-group $resourceGroup --name eklee-keyvault-deployment
```

### Issue: RBAC assignments failed

**Solution:** Ensure you have User Access Administrator role:

```powershell
az role assignment create `
  --assignee-object-id {your-object-id} `
  --assignee-principal-type User `
  --role "User Access Administrator" `
  --scope /subscriptions/{subscription-id}/resourceGroups/$resourceGroup
```

### Issue: Cannot access Key Vault after deployment

**Solution:** Verify RBAC assignments on Key Vault:
```powershell
$vaultName = az deployment group show `
  --resource-group $resourceGroup `
  --name eklee-keyvault-deployment `
  --query "properties.outputs.keyVaultName.value" -o tsv

az role assignment list --scope /subscriptions/{sub-id}/resourceGroups/$resourceGroup/providers/Microsoft.KeyVault/vaults/$vaultName
```

### View Container App Events
```powershell
# Show recent events
az containerapp show --name ekleekv-dev-app --resource-group eklee-keyvault-dev-rg --query "properties.latestReadyRevisionName"

# Stream console logs
az containerapp logs show --name ekleekv-dev-app --resource-group eklee-keyvault-dev-rg --follow --tail 100
```

### Diagnose Startup Issues
```powershell
# Check revision status
az containerapp revision list --name ekleekv-dev-app --resource-group eklee-keyvault-dev-rg

# View system logs
az containerapp revision show --name ekleekv-dev-app--{revision} --resource-group eklee-keyvault-dev-rg
```

### Test Connectivity
```powershell
# Test Container App endpoint
curl https://ekleekv-dev-app.{region}.azurecontainerapps.io

# Test with authentication
curl -H "Authorization: Bearer {token}" https://ekleekv-dev-app.{region}.azurecontainerapps.io/api/secrets
```

## 📞 Support

For issues or questions:
1. Check the [troubleshooting section](#-troubleshooting)
2. Review Azure Container Apps [known issues](https://github.com/microsoft/azure-container-apps/issues)
3. Open an issue in this repository

## 📄 License

This infrastructure code is part of the Eklee KeyVault project. See the main project LICENSE file for details.
