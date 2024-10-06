using EKlee.KeyVault.Client.Models;
using Microsoft.AspNetCore.Components.WebAssembly.Authentication;
using System.Net.Http.Headers;
using System.Net.Http.Json;

namespace EKlee.KeyVault.Client.Services;

public class KeyVaultService
{
    private readonly HttpClient httpClient;
    private readonly Config config;
    private readonly BlobService blobService;
    private readonly ILogger<KeyVaultService> logger;
    private ApimConfigRoot? apimConfigRoot;

    public KeyVaultService(IHttpClientFactory httpClientFactory, Config config, BlobService blobService, ILogger<KeyVaultService> logger)
    {
        httpClient = httpClientFactory.CreateClient("KeyVaultClient");
        this.config = config;
        this.blobService = blobService;
        this.logger = logger;
    }

    public async Task<IEnumerable<SecretItem>> GetSecrets(IAccessTokenProvider accessTokenProvider)
    {
        apimConfigRoot ??= await blobService.DownloadAsync(accessTokenProvider);

        List<SecretItem> items = [];

        var a = await accessTokenProvider.RequestAccessToken(new AccessTokenRequestOptions { Scopes = apimConfigRoot.APIM!.TokenScopes });
        if (a.TryGetToken(out var accessToken))
        {
            httpClient.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", accessToken.Value);
            httpClient.DefaultRequestHeaders.Add("Ocp-Apim-Subscription-Key", apimConfigRoot.APIM!.SubscriptionKey);
            var res = await httpClient.GetFromJsonAsync<SecretItemList>(new Uri(new Uri(apimConfigRoot.APIM!.BaseUrl!), apimConfigRoot.APIM!.SecretsActions!.List));
            if (res!.Value!.Count > 0)
            {
                items.AddRange(res!.Value!);
            }
        }

        return items;
    }

    public Task<string> GetSecret(string url)
    {
        throw new NotImplementedException();
    }
}
