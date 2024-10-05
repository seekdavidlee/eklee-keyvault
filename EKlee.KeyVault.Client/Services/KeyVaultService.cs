using EKlee.KeyVault.Client.Models;
using Microsoft.AspNetCore.Components.WebAssembly.Authentication;
using System.Net.Http.Headers;

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

    public async Task<IEnumerable<string>> GetSecrets(IAccessTokenProvider accessTokenProvider)
    {
        apimConfigRoot ??= await blobService.DownloadAsync(accessTokenProvider);

        List<string> items = [];

        // get with headers
        var a = await accessTokenProvider.RequestAccessToken(new AccessTokenRequestOptions { Scopes = apimConfigRoot.APIM!.TokenScopes });
        if (a.TryGetToken(out var accessToken))
        {
            httpClient.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", accessToken.Value);
            httpClient.DefaultRequestHeaders.Add("Ocp-Apim-Subscription-Key", apimConfigRoot.APIM!.SubscriptionKey);
            var res = await httpClient.GetStringAsync(new Uri(new Uri(apimConfigRoot.APIM!.BaseUrl!), apimConfigRoot.APIM!.SecretsActions!.List));
            items.Add(res);
        }
        else
        {
            items.Add("Failed to obtain access token");
        }

        return items;
    }
}
