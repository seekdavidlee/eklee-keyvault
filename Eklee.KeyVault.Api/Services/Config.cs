namespace Eklee.KeyVault.Api.Services;

/// <summary>
/// Provides strongly-typed access to application configuration values from appsettings.json.
/// Registered as a singleton in the DI container.
/// </summary>
public class Config
{
    /// <summary>
    /// Initializes configuration by reading values from the <see cref="IConfiguration"/> system.
    /// </summary>
    /// <param name="configuration">The application configuration provider.</param>
    /// <exception cref="ArgumentNullException">Thrown when <paramref name="configuration"/> is null.</exception>
    public Config(IConfiguration configuration)
    {
        ArgumentNullException.ThrowIfNull(configuration);

        StorageUri = new Uri(configuration[nameof(StorageUri)]!);
        StorageContainerName = configuration[nameof(StorageContainerName)]!;
        KeyVaultUri = new Uri(configuration[nameof(KeyVaultUri)]!);
    }

    /// <summary>The base URI for the Azure Blob Storage account.</summary>
    public Uri StorageUri { get; }

    /// <summary>The blob container name holding metadata files.</summary>
    public string StorageContainerName { get; }

    /// <summary>The URI of the Azure Key Vault instance.</summary>
    public Uri KeyVaultUri { get; }
}
