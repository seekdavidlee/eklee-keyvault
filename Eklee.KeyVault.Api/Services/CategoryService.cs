using Azure;
using Eklee.KeyVault.Api.Models;

namespace Eklee.KeyVault.Api.Services;

/// <summary>Persists category operations and associations together using bounded ETag retries.</summary>
public class CategoryService(BlobService blobService, KeyVaultService keyVaultService)
{
    /// <summary>Migrates legacy metadata without reading or rewriting secret values or access records.</summary>
    /// <param name="cancellationToken">Cancels startup migration and contention backoff.</param>
    /// <returns>A task completing after a durable, retry-safe migration.</returns>
    public async Task InitializeAsync(CancellationToken cancellationToken = default)
    {
        cancellationToken.ThrowIfCancellationRequested();
        var secrets = await keyVaultService.GetSecretsAsync();
        await MutateAsync(metadata => (true, metadata.InitializeCategories([])));
        var (metadata, _) = await blobService.GetMetaAsync();
        var knownNames = (metadata.Items ?? []).Select(item => item.Id).ToHashSet(StringComparer.OrdinalIgnoreCase);
        var missingNames = secrets.Select(secret => secret.Name)
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .Where(name => !knownNames.Contains(name))
            .Order(StringComparer.OrdinalIgnoreCase);
        foreach (var batch in missingNames.Chunk(100))
        {
            await InitializeBatchAsync(batch, cancellationToken);
        }
    }

    /// <summary>Holds a bounded batch's leases through existence checks and persistence, retrying temporary contention.</summary>
    private async Task InitializeBatchAsync(string[] names, CancellationToken cancellationToken)
    {
        for (var attempt = 0; attempt < 5; attempt++)
        {
            cancellationToken.ThrowIfCancellationRequested();
            var operations = new List<IAsyncDisposable>();
            try
            {
                var (metadata, _) = await blobService.GetMetaAsync();
                var knownNames = (metadata.Items ?? []).Select(item => item.Id).ToHashSet(StringComparer.OrdinalIgnoreCase);
                var confirmedNames = new List<string>();
                foreach (var name in names.Where(name => !knownNames.Contains(name)))
                {
                    cancellationToken.ThrowIfCancellationRequested();
                    operations.Add(await blobService.AcquireSecretOperationAsync(name));
                    if (await keyVaultService.SecretExistsAsync(name))
                    {
                        confirmedNames.Add(name);
                    }
                }

                cancellationToken.ThrowIfCancellationRequested();
                await MutateAsync(current => (true, current.InitializeCategories(confirmedNames)));
                return;
            }
            catch (RequestFailedException exception) when (exception.Status == 409 && attempt < 4)
            {
            }
            finally
            {
                await Task.WhenAll(operations.Select(operation => operation.DisposeAsync().AsTask()));
            }

            await Task.Delay(TimeSpan.FromMilliseconds(100 * (1 << attempt)), cancellationToken);
        }
    }

    /// <summary>Lists shared categories without implying permission to read secrets.</summary>
    /// <returns>The persisted categories.</returns>
    public async Task<IReadOnlyList<CategoryItem>> GetCategoriesAsync()
    {
        var (metadata, _) = await blobService.GetMetaAsync();
        return metadata.Categories;
    }

    /// <summary>Creates a shared category with a unique validated name.</summary>
    /// <param name="name">Requested name.</param>
    /// <returns>The persisted category.</returns>
    public Task<CategoryItem> CreateAsync(string? name) =>
        MutateAsync(metadata => (metadata.CreateCategory(name), true));

    /// <summary>Renames a category, preserving identity and default status.</summary>
    /// <param name="id">Stable category identifier.</param>
    /// <param name="name">Requested name.</param>
    /// <returns>The persisted category.</returns>
    public Task<CategoryItem> RenameAsync(string id, string? name) =>
        MutateAsync(metadata => (metadata.RenameCategory(id, name), true));

    /// <summary>Deletes an empty, non-default category under the association document's ETag.</summary>
    /// <param name="id">Stable category identifier.</param>
    /// <returns>A task completing after persistence.</returns>
    public Task DeleteAsync(string id) => MutateAsync(metadata =>
    {
        metadata.DeleteCategory(id);
        return (true, true);
    });

    /// <summary>Reserves an association before writing the value; callers must hold the per-secret lease through both operations.</summary>
    /// <param name="name">Secret name.</param>
    /// <param name="categoryId">Required category for a new secret; cannot move an existing secret.</param>
    /// <returns>A task completing after the association is durable.</returns>
    public Task AssociateSecretAsync(string name, string? categoryId) => MutateAsync(metadata =>
    {
        var existing = (metadata.Items ?? []).SingleOrDefault(item =>
            string.Equals(item.Id, name, StringComparison.OrdinalIgnoreCase));
        if (existing is not null && !string.IsNullOrEmpty(existing.CategoryId))
        {
            if (categoryId is not null && categoryId != existing.CategoryId)
            {
                throw new InvalidOperationException("Moving existing secrets between categories is not supported.");
            }

            metadata.GetCategory(existing.CategoryId);
            return (true, false);
        }

        if (string.IsNullOrWhiteSpace(categoryId))
        {
            throw new ArgumentException("Choose a category before creating a secret.", nameof(categoryId));
        }

        metadata.GetCategory(categoryId);
        var item = existing ?? metadata.GetById(name, name);
        item.CategoryId = categoryId;
        return (true, true);
    });

    /// <summary>Removes an association after deletion; callers must hold the per-secret lease through delete and cleanup.</summary>
    /// <param name="name">Deleted secret name.</param>
    /// <returns>A task completing after metadata cleanup.</returns>
    public Task RemoveSecretAsync(string name) => MutateAsync(metadata =>
    {
        var removed = metadata.Items?.RemoveAll(item =>
            string.Equals(item.Id, name, StringComparison.OrdinalIgnoreCase)) ?? 0;
        return (true, removed > 0);
    });

    /// <summary>Reloads and revalidates each mutation after a concurrent writer wins.</summary>
    private async Task<T> MutateAsync<T>(Func<SecretItemMetaList, (T Result, bool Changed)> mutation)
    {
        for (var attempt = 0; attempt < 5; attempt++)
        {
            var (metadata, etag) = await blobService.GetMetaAsync();
            var (result, changed) = mutation(metadata);
            if (!changed)
            {
                return result;
            }

            try
            {
                await blobService.UpdateMetaAsync(metadata, etag);
                return result;
            }
            catch (RequestFailedException exception) when (exception.Status is 409 or 412 && attempt < 4)
            {
                continue;
            }
        }

        throw new InvalidOperationException("Category metadata could not be saved. Reload and try again.");
    }
}