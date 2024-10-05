using Azure.Storage.Blobs;
using Microsoft.AspNetCore.Components.WebAssembly.Authentication;

namespace EKlee.KeyVault.Client.Services;

public class BlobService(Config config)
{    
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
