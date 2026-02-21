namespace Eklee.KeyVault.Api.Models;

/// <summary>
/// Combined view of a Key Vault secret with its user-defined display metadata.
/// Returned by the secrets list endpoint.
/// </summary>
public class SecretItemView
{
    public SecretItemView(SecretItem secretItem, SecretItemMetaList list)
    {
        var parts = secretItem.Id!.Split('/');
        Id = parts[^1];
        Name = secretItem.Name;
        Meta = list.GetById(Id, Name);
    }

    /// <summary>The secret identifier (last segment of the Key Vault URL).</summary>
    public string Id { get; }

    /// <summary>The secret name extracted from the Key Vault URL.</summary>
    public string Name { get; }

    /// <summary>User-defined display metadata for this secret.</summary>
    public SecretItemMeta Meta { get; }
}
