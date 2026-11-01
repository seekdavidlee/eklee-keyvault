namespace Eklee.KeyVault.Api.Models;

/// <summary>
/// User-defined display metadata for a Key Vault secret, stored in blob storage.
/// </summary>
public class SecretItemMeta
{
    public string? Id { get; set; }
    public string? DisplayName { get; set; }

    /// <summary>Gets or sets the stable shared category identifier; null denotes legacy metadata.</summary>
    public string? CategoryId { get; set; }
}
