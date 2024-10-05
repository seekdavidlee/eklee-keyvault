using EKlee.KeyVault.Client.Modules;

namespace KeyVaultClient.Modules;

public class Users : IAppModule
{
    public string DisplayName => "All Users";

    public string Path => "/users";

    public string Icon => "group";
}
