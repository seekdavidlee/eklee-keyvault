namespace EKlee.KeyVault.Client.Models;

public class SecretItemView
{
    public const string PlaceHolderValue = "***";
    public SecretItemView(SecretItem secretItem, SecretItemMetaList list)
    {
        var parts = secretItem.Id!.Split('/');
        Id = parts[^1];
        Name = secretItem.Name;
        Value = PlaceHolderValue;
        Meta = list.GetById(Id, Name);
    }
    public string Id { get; }
    public string Name { get; }
    public SecretItemMeta Meta { get; }
    public string Value { get; set; }

    public bool IsEditDisplayName { get; set; }
}
