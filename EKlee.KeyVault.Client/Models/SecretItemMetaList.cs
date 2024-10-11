namespace EKlee.KeyVault.Client.Models;

public class SecretItemMetaList
{
    public List<SecretItemMeta>? Items { get; set; }

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