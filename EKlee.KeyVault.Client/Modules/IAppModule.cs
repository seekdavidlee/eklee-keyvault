namespace EKlee.KeyVault.Client.Modules;

public interface IAppModule
{
    string DisplayName { get; }

    string Path { get; }

    string Icon { get; }
}
