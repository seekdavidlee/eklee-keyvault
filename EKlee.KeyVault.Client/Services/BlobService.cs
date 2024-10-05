using Azure.Storage.Blobs;
using EKlee.KeyVault.Client.Models;
using Microsoft.AspNetCore.Components.WebAssembly.Authentication;

namespace EKlee.KeyVault.Client.Services;

public class BlobService(Config config)
{
    public async Task<ApimConfigRoot> DownloadAsync(IAccessTokenProvider accessTokenProvider)
    {
        var credential = new AccessTokenProviderTokenCredential(accessTokenProvider);
        BlobClient blobContainerClient = new(new Uri(config.StorageUri, $"{config.StorageContainerName}/config.json"), credential);
        var content = await blobContainerClient.DownloadContentAsync();
        return content.Value.Content.ToObjectFromJson<ApimConfigRoot>();
    }

    public async Task<IEnumerable<string>> ListAsync(IAccessTokenProvider accessTokenProvider)
    {
        List<string> items = [];

        var credential = new AccessTokenProviderTokenCredential(accessTokenProvider);
        var blobServiceClient = new BlobServiceClient(config.StorageUri, credential);
        var blobContainerClient = blobServiceClient.GetBlobContainerClient(config.StorageContainerName);
        await foreach (var b in blobContainerClient.GetBlobsAsync())
        {
            items.Add(b.Name);
        }

        return items;
    }
}
