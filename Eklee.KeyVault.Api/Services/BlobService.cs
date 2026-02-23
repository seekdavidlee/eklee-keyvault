using Azure;
using Azure.Core;
using Azure.Storage.Blobs;
using Azure.Storage.Blobs.Models;
using Eklee.KeyVault.Api.Models;

namespace Eklee.KeyVault.Api.Services;

/// <summary>
/// Manages secret display-name metadata stored as JSON in Azure Blob Storage.
/// Uses a <see cref="TokenCredential"/> resolved from DI based on the configured authentication mode.
/// Uses the blob's native ETag for optimistic concurrency control on writes.
/// </summary>
public class BlobService(Config config, TokenCredential credential)
{
    private const string SecretsMetaFileName = "secrets-meta.json";

    /// <summary>
    /// Creates a <see cref="BlobClient"/> for the given blob name using the injected credential.
    /// </summary>
    private BlobClient GetBlobClient(string blobName)
    {
        return new BlobClient(new Uri(config.StorageUri, $"{config.StorageContainerName}/{blobName}"), credential);
    }

    /// <summary>
    /// Downloads the secret metadata list from blob storage along with its ETag.
    /// Returns an empty list with a <c>null</c> ETag if the metadata file does not exist yet.
    /// </summary>
    /// <returns>
    /// A tuple of the <see cref="SecretItemMetaList"/> and the blob ETag string (or <c>null</c> for a new blob).
    /// </returns>
    public async Task<(SecretItemMetaList MetaList, string? ETag)> GetMetaAsync()
    {
        var blobClient = GetBlobClient(SecretsMetaFileName);
        if (!await blobClient.ExistsAsync())
        {
            return (new SecretItemMetaList(), null);
        }

        var content = await blobClient.DownloadContentAsync();
        var metaList = content.Value.Content.ToObjectFromJson<SecretItemMetaList>()!;
        var etag = content.Value.Details.ETag.ToString();
        return (metaList, etag);
    }

    /// <summary>
    /// Uploads the secret metadata list to blob storage with optimistic concurrency.
    /// When <paramref name="ifMatchEtag"/> is provided, the write only succeeds if the blob's
    /// current ETag matches (prevents overwriting concurrent changes).
    /// When <paramref name="ifMatchEtag"/> is <c>null</c>, the blob is created only if it does
    /// not already exist (prevents racing first-time creation).
    /// </summary>
    /// <param name="secretItemMetaList">The metadata to persist.</param>
    /// <param name="ifMatchEtag">
    /// The ETag the caller expects the blob to have, or <c>null</c> for first-time creation.
    /// </param>
    /// <returns>The new ETag after a successful write.</returns>
    /// <exception cref="RequestFailedException">
    /// Thrown with status 409 or 412 when the concurrency check fails.
    /// </exception>
    public async Task<string> UpdateMetaAsync(SecretItemMetaList secretItemMetaList, string? ifMatchEtag)
    {
        var blobClient = GetBlobClient(SecretsMetaFileName);
        var data = BinaryData.FromObjectAsJson(secretItemMetaList);

        BlobUploadOptions options;
        if (ifMatchEtag is not null)
        {
            options = new BlobUploadOptions
            {
                Conditions = new BlobRequestConditions { IfMatch = new ETag(ifMatchEtag) }
            };
        }
        else
        {
            // First-time creation — only create if the blob does not already exist
            options = new BlobUploadOptions
            {
                Conditions = new BlobRequestConditions { IfNoneMatch = ETag.All }
            };
        }

        var response = await blobClient.UploadAsync(data, options);
        return response.Value.ETag.ToString();
    }
}
