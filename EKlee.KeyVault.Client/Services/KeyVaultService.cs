using EKlee.KeyVault.Client.Models;
using Microsoft.AspNetCore.Components.WebAssembly.Authentication;
using System.Net.Http.Headers;
using System.Net.Http.Json;

namespace EKlee.KeyVault.Client.Services;

public class KeyVaultService
{
    private readonly IHttpClientFactory httpClientFactory;
    private readonly IAccessTokenProvider accessTokenProvider;
    private readonly Config config;
    private readonly BlobService blobService;
    private readonly ILogger<KeyVaultService> logger;
    private ApimConfigRoot? apimConfigRoot;

    public KeyVaultService(IHttpClientFactory httpClientFactory, IAccessTokenProvider accessTokenProvider, Config config, BlobService blobService, ILogger<KeyVaultService> logger)
    {

        this.httpClientFactory = httpClientFactory;
        this.accessTokenProvider = accessTokenProvider;
        this.config = config;
        this.blobService = blobService;
        this.logger = logger;
    }

    private async Task<HttpClient?> TryGetHttpClientAsync()
    {
        apimConfigRoot ??= await blobService.DownloadAsync();
        var tokenResult = await accessTokenProvider.RequestAccessToken(new AccessTokenRequestOptions { Scopes = apimConfigRoot.APIM!.TokenScopes });
        if (tokenResult.TryGetToken(out var accessToken))
        {
            var httpClient = httpClientFactory.CreateClient("KeyVaultClient");
            httpClient.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", accessToken.Value);
            httpClient.DefaultRequestHeaders.Add("Ocp-Apim-Subscription-Key", apimConfigRoot.APIM!.SubscriptionKey);
            return httpClient;
        }

        logger.LogWarning("unable to get access token for user");
        return default;
    }

    public async Task<IEnumerable<SecretItem>> GetSecretsAsync()
    {
        List<SecretItem> items = [];

        var httpClient = await TryGetHttpClientAsync();
        if (httpClient is not null && apimConfigRoot is not null)
        {
            string? skiptoken = "";

            while (skiptoken is not null)
            {
                string skipTokenAppend = string.IsNullOrEmpty(skiptoken) ? "" : $"?$skiptoken={skiptoken}";
                string listUrl = $"{apimConfigRoot.APIM!.SecretsActions!.List}{skipTokenAppend}";

                var res = await httpClient.GetFromJsonAsync<SecretItemList>(new Uri(new Uri(apimConfigRoot.APIM!.BaseUrl!), listUrl));
                if (res!.Value!.Count > 0)
                {
                    items.AddRange(res!.Value!);
                }
                if (res.NextLink is not null)
                {
                    var uri = new Uri(res.NextLink);
                    var values = System.Web.HttpUtility.ParseQueryString(uri.Query);
                    skiptoken = values.Get("$skiptoken");
                }
                else
                {
                    skiptoken = null;
                }
            }

        }

        return items;
    }

    public async Task<string?> GetSecretAsync(string url)
    {
        var httpClient = await TryGetHttpClientAsync();
        if (httpClient is not null && apimConfigRoot is not null)
        {
            string getUrl = $"{apimConfigRoot.APIM!.SecretsActions!.Get}?id={url}";
            var res = await httpClient.GetFromJsonAsync<SecretValue>(new Uri(new Uri(apimConfigRoot.APIM!.BaseUrl!), getUrl));
            if (res is not null)
            {
                return res.Value!;
            }
        }

        return default;
    }
}
