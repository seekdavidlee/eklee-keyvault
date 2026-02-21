using System.Text.Json.Serialization;

namespace Eklee.KeyVault.Api.Models;

/// <summary>
/// Paginated list of Key Vault secret items returned by the APIM proxy.
/// </summary>
public class SecretItemList
{
    public List<SecretItem>? Value { get; set; }

    public string? NextLink { get; set; }
}

/// <summary>
/// Wrapper for a single Key Vault secret value returned by the APIM proxy.
/// </summary>
public class SecretValue
{
    [JsonPropertyName("value")]
    public string? Value { get; set; }
}

/// <summary>
/// Represents a Key Vault secret with its identifier and enabled status.
/// </summary>
public class SecretItem
{
    public string? Id { get; set; }
    public bool Enabled { get; set; }

    /// <summary>
    /// Extracts the secret name from the last segment of the Key Vault secret URL.
    /// </summary>
    public string Name
    {
        get
        {
            var parts = Id!.Split('/');
            return parts[^1];
        }
    }
}
