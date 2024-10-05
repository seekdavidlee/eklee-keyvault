using Microsoft.AspNetCore.Components.WebAssembly.Authentication;
using System.Net.Http.Headers;

namespace EKlee.KeyVault.Client.Services;

public class KeyVaultService
{
    private readonly HttpClient httpClient;
    private readonly Config config;

    public KeyVaultService(IHttpClientFactory httpClientFactory, Config config)
    {
        httpClient = httpClientFactory.CreateClient("KeyVaultClient");
        this.config = config;
    }

    public async Task<IEnumerable<string>> GetSecrets(IAccessTokenProvider accessTokenProvider)
    {
        List<string> items = [];

        // get with headers
        var a = await accessTokenProvider.RequestAccessToken(new AccessTokenRequestOptions { Scopes = config.KeyVaultScopes });
        if (a.TryGetToken(out var accessToken))
        {            
            httpClient.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", accessToken.Value);
            httpClient.DefaultRequestHeaders.Add("Ocp-Apim-Subscription-Key", config.APIMSubscriptionKey);
            var res = await httpClient.GetStringAsync(config.GetSecretsUrl);
            items.Add(res);
        }
        else
        {
            items.Add("Failed to obtain access token");
        }

        return items;
    }
}
