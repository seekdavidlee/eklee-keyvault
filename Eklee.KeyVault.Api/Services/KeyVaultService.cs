using Azure.Core;
using Azure.Security.KeyVault.Secrets;
using Eklee.KeyVault.Api.Models;

namespace Eklee.KeyVault.Api.Services;

/// <summary>
/// Provides direct access to Azure Key Vault secrets using <see cref="SecretClient"/> with
/// a <see cref="TokenCredential"/> resolved from DI based on the configured authentication mode.
/// </summary>
public class KeyVaultService
{
    private readonly SecretClient secretClient;
    private readonly ILogger<KeyVaultService> logger;

    /// <summary>
    /// Initializes the Key Vault service with a <see cref="SecretClient"/> targeting the configured vault URI.
    /// </summary>
    /// <param name="config">Application configuration containing the Key Vault URI.</param>
    /// <param name="credential">The Azure token credential injected from DI.</param>
    /// <param name="logger">Logger for diagnostic output.</param>
    public KeyVaultService(Config config, TokenCredential credential, ILogger<KeyVaultService> logger)
    {
        this.logger = logger;
        secretClient = new SecretClient(config.KeyVaultUri, credential);
    }

    /// <summary>
    /// Lists all secrets in the Key Vault by iterating over secret properties.
    /// Only returns secrets that are currently enabled.
    /// </summary>
    /// <returns>A collection of <see cref="SecretItem"/> representing each secret.</returns>
    public async Task<IEnumerable<SecretItem>> GetSecretsAsync()
    {
        List<SecretItem> items = [];

        await foreach (var secretProperties in secretClient.GetPropertiesOfSecretsAsync())
        {
            items.Add(new SecretItem
            {
                Id = secretProperties.Id.ToString(),
                Enabled = secretProperties.Enabled ?? false
            });
        }

        logger.LogInformation("Listed {Count} secrets from Key Vault", items.Count);
        return items;
    }

    /// <summary>
    /// Retrieves the value of a single secret by name.
    /// </summary>
    /// <param name="name">The name of the secret to retrieve.</param>
    /// <returns>The secret value, or <c>null</c> if the secret could not be found.</returns>
    public async Task<string?> GetSecretAsync(string name)
    {
        var response = await secretClient.GetSecretAsync(name);
        if (response?.Value is not null)
        {
            logger.LogInformation("Retrieved secret {SecretName}", name);
            return response.Value.Value;
        }

        logger.LogWarning("Secret {SecretName} not found or has no value", name);
        return null;
    }

    /// <summary>
    /// Creates or updates a secret in Key Vault with the specified name and value.
    /// If a secret with the given name already exists, its value is replaced.
    /// </summary>
    /// <param name="name">The name of the secret to create or update.</param>
    /// <param name="value">The secret value to store.</param>
    /// <returns>The name of the secret that was set.</returns>
    public async Task<string> SetSecretAsync(string name, string value)
    {
        var response = await secretClient.SetSecretAsync(name, value);
        logger.LogInformation("Set secret {SecretName}", name);
        return response.Value.Name;
    }

    /// <summary>
    /// Starts a soft-delete operation for a secret in Key Vault.
    /// The secret can be recovered during the vault's retention period.
    /// </summary>
    /// <param name="name">The name of the secret to delete.</param>
    /// <returns>A task that completes when the delete operation has been initiated.</returns>
    public async Task DeleteSecretAsync(string name)
    {
        var operation = await secretClient.StartDeleteSecretAsync(name);
        logger.LogInformation("Initiated delete for secret {SecretName}", name);
        await operation.WaitForCompletionAsync();
        logger.LogInformation("Deleted secret {SecretName}", name);
    }
}
