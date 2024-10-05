using EKlee.KeyVault.Client;
using System.Security.Claims;
using System.Text.Json;

namespace EKlee.KeyVault.Client.Services;

public class Config
{
    private readonly string header;
    public Config(IConfiguration configuration)
    {
        ArgumentNullException.ThrowIfNull(configuration);

        var config = configuration.GetSection("System");
        header = config["Header"] ?? "Please configure text for header!";
        Footer = config["Footer"] ?? "Please configure text for footer!";

        StorageUri = new Uri(configuration[nameof(StorageUri)]!);
        StorageContainerName = configuration[nameof(StorageContainerName)]!;
    }

    public Uri StorageUri { get; }

    public string StorageContainerName { get; }

    public string Header
    {
        get
        {
            return $"{header} - {Username}";
        }
    }

    public string Footer { get; }

    public string Username { get; set; } = Constants.Unknown;

    public string Displayname { get; set; } = Constants.Unknown;

    public void Update(ClaimsPrincipal user)
    {
        if (Displayname == Constants.Unknown)
        {
            var claimName = user.FindFirst(x => x.Type == "name");
            if (claimName is not null)
            {
                Displayname = claimName.Value;
            }
        }

        if (Username == Constants.Unknown)
        {
            var claimEmail = user.FindFirst(x => x.Type == "emails");
            if (claimEmail is not null)
            {
                var values = JsonSerializer.Deserialize<string[]>(claimEmail.Value);
                if (values is not null)
                {
                    Username = values.First();
                }
            }
        }
    }
}
