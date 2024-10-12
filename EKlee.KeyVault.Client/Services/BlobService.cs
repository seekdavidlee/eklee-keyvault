using Azure.Storage.Blobs;
using EKlee.KeyVault.Client.Models;
using Microsoft.AspNetCore.Components.WebAssembly.Authentication;

namespace EKlee.KeyVault.Client.Services;

public class BlobService(Config config, IAccessTokenProvider accessTokenProvider)
{
    private const string SECRETS_META_FILE_NAME = "secrets-meta.json";
    public async Task<ApimConfigRoot> DownloadAsync()
    {
        var credential = new AccessTokenProviderTokenCredential(accessTokenProvider);
        BlobClient blobContainerClient = new(new Uri(config.StorageUri, $"{config.StorageContainerName}/config.json"), credential);
        var content = await blobContainerClient.DownloadContentAsync();
        return content.Value.Content.ToObjectFromJson<ApimConfigRoot>()!;
    }

    public async Task<SecretItemMetaList> GetMetaAsync()
    {
        var credential = new AccessTokenProviderTokenCredential(accessTokenProvider);
        BlobClient blobContainerClient = new(new Uri(config.StorageUri, $"{config.StorageContainerName}/{SECRETS_META_FILE_NAME}"), credential);
        if (!await blobContainerClient.ExistsAsync())
        {
            return new SecretItemMetaList();
        }
        var content = await blobContainerClient.DownloadContentAsync();
        return content.Value.Content.ToObjectFromJson<SecretItemMetaList>()!;
    }

    public async Task UpdateMetaAsync(SecretItemMetaList secretItemMetaList)
    {
        var credential = new AccessTokenProviderTokenCredential(accessTokenProvider);
        BlobClient blobContainerClient = new(new Uri(config.StorageUri, $"{config.StorageContainerName}/{SECRETS_META_FILE_NAME}"), credential);
        await blobContainerClient.UploadAsync(BinaryData.FromObjectAsJson(secretItemMetaList), overwrite: true);
    }

    public async Task<IEnumerable<string>> ListAsync()
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
