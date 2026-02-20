using Azure.Identity;
using Azure.Storage.Blobs;
using Eklee.KeyVault.Api.Models;

namespace Eklee.KeyVault.Api.Services;

/// <summary>
/// Manages secret display-name metadata stored as JSON in Azure Blob Storage.
/// Uses <see cref="DefaultAzureCredential"/> for authentication (managed identity in production).
/// </summary>
public class BlobService(Config config)
{
    private const string SecretsMetaFileName = "secrets-meta.json";

    private BlobClient GetBlobClient(string blobName)
    {
        var credential = new DefaultAzureCredential();
        return new BlobClient(new Uri(config.StorageUri, $"{config.StorageContainerName}/{blobName}"), credential);
    }

    /// <summary>
    /// Downloads the secret metadata list from blob storage.
    /// Returns an empty list if the metadata file does not exist yet.
    /// </summary>
    /// <returns>The <see cref="SecretItemMetaList"/> stored in blob, or an empty instance.</returns>
    public async Task<SecretItemMetaList> GetMetaAsync()
    {
        var blobClient = GetBlobClient(SecretsMetaFileName);
        if (!await blobClient.ExistsAsync())
        {
            return new SecretItemMetaList();
        }

        var content = await blobClient.DownloadContentAsync();
        return content.Value.Content.ToObjectFromJson<SecretItemMetaList>()!;
    }

    /// <summary>
    /// Uploads the secret metadata list to blob storage, overwriting any existing file.
    /// </summary>
    /// <param name="secretItemMetaList">The metadata to persist.</param>
    public async Task UpdateMetaAsync(SecretItemMetaList secretItemMetaList)
    {
        var blobClient = GetBlobClient(SecretsMetaFileName);
        await blobClient.UploadAsync(BinaryData.FromObjectAsJson(secretItemMetaList), overwrite: true);
    }
}
