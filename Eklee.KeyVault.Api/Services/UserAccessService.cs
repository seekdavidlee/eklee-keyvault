using Azure;
using Azure.Core;
using Azure.Storage.Blobs;
using Azure.Storage.Blobs.Models;
using Eklee.KeyVault.Api.Models;

namespace Eklee.KeyVault.Api.Services;

/// <summary>
/// Manages user access records stored as JSON in Azure Blob Storage.
/// Uses the blob's native ETag for optimistic concurrency control — no version field in the JSON.
/// </summary>
public class UserAccessService(Config config, TokenCredential credential)
{
    private const string UserAccessFileName = "user_access.json";

    /// <summary>
    /// Creates a <see cref="BlobClient"/> for the user access blob using the injected credential.
    /// </summary>
    private BlobClient GetBlobClient()
    {
        return new BlobClient(
            new Uri(config.StorageUri, $"{config.StorageContainerName}/{UserAccessFileName}"),
            credential);
    }

    /// <summary>
    /// Downloads the user access list from blob storage along with its ETag.
    /// Returns an empty list with a <c>null</c> ETag if the blob does not exist yet.
    /// </summary>
    /// <returns>
    /// A tuple of the <see cref="UserAccessList"/> and the blob ETag string (or <c>null</c> for a new blob).
    /// </returns>
    public async Task<(UserAccessList List, string? ETag)> GetUserAccessListAsync()
    {
        var blobClient = GetBlobClient();
        if (!await blobClient.ExistsAsync())
        {
            return (new UserAccessList(), null);
        }

        var response = await blobClient.DownloadContentAsync();
        var list = response.Value.Content.ToObjectFromJson<UserAccessList>()!;
        var etag = response.Value.Details.ETag.ToString();
        return (list, etag);
    }

    /// <summary>
    /// Uploads the user access list to blob storage with optimistic concurrency.
    /// When <paramref name="ifMatchEtag"/> is provided, the write only succeeds if the blob's
    /// current ETag matches (prevents overwriting concurrent changes).
    /// When <paramref name="ifMatchEtag"/> is <c>null</c>, the write only succeeds if the blob
    /// does not yet exist (prevents racing first-user registrations).
    /// </summary>
    /// <param name="list">The user access list to persist.</param>
    /// <param name="ifMatchEtag">
    /// The ETag the caller expects the blob to have, or <c>null</c> for first-time creation.
    /// </param>
    /// <returns>The new ETag after a successful write.</returns>
    /// <exception cref="RequestFailedException">
    /// Thrown with status 409 or 412 when the concurrency check fails (blob was modified or already exists).
    /// </exception>
    public async Task<string> UpdateUserAccessListAsync(UserAccessList list, string? ifMatchEtag)
    {
        var blobClient = GetBlobClient();
        var data = BinaryData.FromObjectAsJson(list);

        BlobUploadOptions options;
        if (ifMatchEtag is not null)
        {
            // Existing blob — only overwrite if ETag still matches
            options = new BlobUploadOptions
            {
                Conditions = new BlobRequestConditions { IfMatch = new ETag(ifMatchEtag) }
            };
        }
        else
        {
            // New blob — only create if it doesn't already exist (prevents first-user race)
            options = new BlobUploadOptions
            {
                Conditions = new BlobRequestConditions { IfNoneMatch = ETag.All }
            };
        }

        var response = await blobClient.UploadAsync(data, options);
        return response.Value.ETag.ToString();
    }

    /// <summary>
    /// Looks up a user's role by their Entra ID object identifier.
    /// </summary>
    /// <param name="objectId">The oid claim value from the JWT token.</param>
    /// <returns>The user's <see cref="UserRole"/>, or <c>null</c> if the user is not registered.</returns>
    public async Task<UserRole?> GetUserRoleAsync(string objectId)
    {
        var (list, _) = await GetUserAccessListAsync();
        var user = list.GetByObjectId(objectId);
        return user?.Role;
    }
}
