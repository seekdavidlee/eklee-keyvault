namespace EKlee.KeyVault.Client.Models;

public class ApimConfig
{
    public string? SubscriptionKey { get; set; }

    public string? BaseUrl { get; set; }

    public string[]? TokenScopes { get; set; }

    public ApimSecretsActions? SecretsActions { get; set; }
}
