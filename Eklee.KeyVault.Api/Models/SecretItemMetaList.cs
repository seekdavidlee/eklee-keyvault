namespace Eklee.KeyVault.Api.Models;

/// <summary>
/// Collection of user-defined display metadata for Key Vault secrets, stored in blob storage.
/// Provides lookup by secret identifier with automatic creation of missing entries.
/// </summary>
public class SecretItemMetaList
{
    public List<SecretItemMeta>? Items { get; set; }

    /// <summary>
    /// Finds metadata by secret identifier, creating a new entry with the default display name if not found.
    /// </summary>
    /// <param name="id">The secret identifier (last segment of the Key Vault URL).</param>
    /// <param name="defaultDisplayName">The fallback display name if no metadata exists.</param>
    /// <returns>The existing or newly created <see cref="SecretItemMeta"/>.</returns>
    public SecretItemMeta GetById(string id, string defaultDisplayName)
    {
        if (Items is null)
        {
            Items = [];
            var firstItem = new SecretItemMeta { Id = id, DisplayName = defaultDisplayName };
            Items.Add(firstItem);
            return firstItem;
        }

        var item = Items.SingleOrDefault(x => x.Id == id);
        if (item is null)
        {
            item = new SecretItemMeta { Id = id, DisplayName = defaultDisplayName };
            Items.Add(item);
        }

        return item;
    }
}
