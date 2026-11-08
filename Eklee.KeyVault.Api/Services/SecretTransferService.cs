using System.Text;
using System.Text.Json;
using Azure;
using Eklee.KeyVault.Api.Models;

namespace Eklee.KeyVault.Api.Services;

/// <summary>Validates complete exports and coordinates category-aware, non-overwriting imports.</summary>
public class SecretTransferService(KeyVaultService keyVaultService, BlobService blobService, CategoryService categoryService)
{
    public const int MaximumFileBytes = 10 * 1024 * 1024;
    public const int MaximumSecrets = 1000;
    private const int OperationBatchSize = 100;
    private static readonly JsonSerializerOptions TransferJson = new(JsonSerializerDefaults.Web)
    {
        PropertyNameCaseInsensitive = false,
        AllowDuplicateProperties = false
    };

    /// <summary>Rejects malformed or unsupported documents before any storage operation, without reflecting input values.</summary>
    public static SecretExport Parse(JsonElement document)
    {
        SecretExport? export;
        try
        {
            export = document.Deserialize<SecretExport>(TransferJson);
        }
        catch (JsonException)
        {
            throw new ArgumentException("Use an application export with formatVersion, secrets, and string name/value/tag fields. Duplicate JSON properties and unknown fields are not allowed.");
        }

        return Validate(export);
    }

    /// <summary>Uses identical record constraints for outgoing exports and incoming imports.</summary>
    private static SecretExport Validate(SecretExport? export)
    {
        if (export is null || export.FormatVersion != 1 || export.Secrets is null || export.Secrets.Count > MaximumSecrets)
        {
            throw new ArgumentException("Use formatVersion 1 with a secrets array containing at most 1000 entries.");
        }

        for (var index = 0; index < export.Secrets.Count; index++)
        {
            var item = export.Secrets[index];
            if (item is null || string.IsNullOrEmpty(item.Name) || item.Name.Length > 127 ||
                item.Name.Any(character => !char.IsAsciiLetterOrDigit(character) && character != '-') ||
                item.Value is null || Encoding.UTF8.GetByteCount(item.Value) > 25 * 1024 ||
                item.Tags is null || item.Tags.Count > 15 ||
                item.Tags.Any(tag => string.IsNullOrEmpty(tag.Key) || tag.Key.Length > 512 || tag.Value is null || tag.Value.Length > 256))
            {
                throw new ArgumentException($"Entry {index + 1} is invalid. Names require 1-127 ASCII letters, digits or hyphens; values allow 25 KiB; tags allow 15 string pairs (keys 1-512, values 0-256 characters).");
            }
        }

        return export;
    }

    /// <summary>Exports only the selected category, retaining all tags and display names without rewriting stored values.</summary>
    public async Task<SecretExport> ExportAsync(string categoryId)
    {
        var (metadata, _) = await blobService.GetMetaAsync();
        metadata.GetCategory(categoryId);
        var associations = (metadata.Items ?? []).Where(item => item.CategoryId == categoryId)
            .ToDictionary(item => item.Id!, StringComparer.OrdinalIgnoreCase);
        var names = (await keyVaultService.GetSecretsAsync()).Select(secret => secret.Name)
            .Where(associations.ContainsKey).Order(StringComparer.OrdinalIgnoreCase).ToList();
        if (names.Count > MaximumSecrets)
        {
            throw new ArgumentException("This category exceeds the 1000-secret transfer limit.");
        }

        var items = new List<SecretExportItem>();
        foreach (var batch in names.Chunk(OperationBatchSize))
        {
            var operations = new List<IAsyncDisposable>();
            try
            {
                foreach (var name in batch)
                {
                    operations.Add(await blobService.AcquireSecretOperationAsync(name));
                }

                var (current, _) = await blobService.GetMetaAsync();
                current.GetCategory(categoryId);
                var currentAssociations = (current.Items ?? []).Where(item => item.CategoryId == categoryId)
                    .ToDictionary(item => item.Id!, StringComparer.OrdinalIgnoreCase);
                foreach (var name in batch)
                {
                    if (!currentAssociations.TryGetValue(name, out var association)) continue;
                    var secret = await keyVaultService.GetSecretWithTagsAsync(name);
                    items.Add(new SecretExportItem
                    {
                        Name = secret.Name, Value = secret.Value,
                        Tags = new Dictionary<string, string>(secret.Properties.Tags),
                        DisplayName = association.DisplayName
                    });
                }
            }
            finally
            {
                await Task.WhenAll(operations.Select(async operation => await operation.DisposeAsync()));
            }
        }

        return Validate(new SecretExport { FormatVersion = 1, Secrets = items });
    }

    /// <summary>Requires a destination and checks vault-wide duplicates under the same leases as normal creation and deletion.</summary>
    public async Task<SecretImportResponse> ImportAsync(string? categoryId, JsonElement document)
    {
        var export = Parse(document);
        if (string.IsNullOrWhiteSpace(categoryId))
        {
            throw new ArgumentException("Choose a destination category before importing.");
        }

        var (metadata, _) = await blobService.GetMetaAsync();
        metadata.GetCategory(categoryId);
        var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        var results = new List<SecretImportItemResult>();
        var accessDenied = false;
        foreach (var batch in export.Secrets.Chunk(OperationBatchSize))
        {
            if (accessDenied)
            {
                results.AddRange(batch.Select(item => NotAttempted(item.Name)));
                continue;
            }

            var response = await ImportBatchAsync(batch, categoryId, seen);
            results.AddRange(response.Results);
            accessDenied = response.AccessDenied;
        }

        return new SecretImportResponse(results, accessDenied);
    }

    /// <summary>Checks duplicates under leases, reserves metadata once, and completes cleanup before reporting each entry.</summary>
    private async Task<SecretImportResponse> ImportBatchAsync(SecretExportItem[] batch, string categoryId, HashSet<string> seen)
    {
        var operations = batch.Select(item => new ImportOperation(item)).ToArray();
        var results = new List<SecretImportItemResult>();
        var accessDenied = false;
        try
        {
            foreach (var operation in operations)
            {
                if (!seen.Add(operation.Item.Name))
                {
                    operation.Outcome = new(operation.Item.Name, "skipped", "Duplicate name within the file.");
                    continue;
                }

                try
                {
                    operation.Lease = await blobService.AcquireSecretOperationAsync(operation.Item.Name);
                    if (await keyVaultService.SecretExistsAsync(operation.Item.Name))
                    {
                        operation.Outcome = new(operation.Item.Name, "skipped", "This name already exists in the vault.");
                    }
                }
                catch (Exception exception)
                {
                    operation.Failure = exception;
                    if (exception is RequestFailedException { Status: 403 })
                    {
                        accessDenied = true;
                        break;
                    }
                }
            }

            var pending = operations.Where(operation => operation.Outcome is null && operation.Failure is null && operation.Lease is not null).ToArray();
            if (!accessDenied && pending.Length > 0)
            {
                try
                {
                    var conflicts = await categoryService.ReserveImportedSecretsAsync(pending.Select(operation => operation.Item).ToArray(), categoryId);
                    foreach (var operation in pending.Where(operation => conflicts.Contains(operation.Item.Name)))
                    {
                        operation.Failure = new InvalidOperationException("Moving existing secrets between categories is not supported.");
                    }
                }
                catch (Exception exception)
                {
                    if (exception is RequestFailedException { Status: 403 })
                    {
                        pending[0].Failure = exception;
                        foreach (var operation in pending.Skip(1)) operation.Outcome = NotAttempted(operation.Item.Name);
                    }
                    else
                    {
                        foreach (var operation in pending) operation.Failure = exception;
                    }
                }
            }

            foreach (var operation in operations)
            {
                Exception? cleanupFailure = null;
                try
                {
                    if (accessDenied && operation.Failure is not RequestFailedException { Status: 403 })
                    {
                        operation.Failure = null;
                        operation.Outcome = NotAttempted(operation.Item.Name);
                    }
                    else if (operation.Failure is null && operation.Outcome is null)
                    {
                        await keyVaultService.SetSecretWithTagsAsync(operation.Item.Name, operation.Item.Value, operation.Item.Tags);
                        operation.Outcome = new(operation.Item.Name, "imported");
                    }
                }
                catch (Exception exception)
                {
                    operation.Failure = exception;
                }
                finally
                {
                    if (operation.Lease is not null)
                    {
                        var lease = operation.Lease;
                        operation.Lease = null;
                        try
                        {
                            await lease.DisposeAsync();
                        }
                        catch (Exception exception)
                        {
                            cleanupFailure = exception;
                        }
                    }
                }

                var failure = operation.Failure is RequestFailedException { Status: 403 } ? operation.Failure
                    : cleanupFailure is RequestFailedException { Status: 403 } ? cleanupFailure
                    : operation.Failure ?? cleanupFailure;
                if (failure is not null)
                {
                    accessDenied |= failure is RequestFailedException { Status: 403 };
                    results.Add(FailureResult(operation.Item.Name, failure));
                }
                else
                {
                    results.Add(operation.Outcome ?? throw new InvalidOperationException("Import did not complete."));
                }
            }
        }
        finally
        {
            await Task.WhenAll(operations.Where(operation => operation.Lease is not null)
                .Select(async operation => await operation.Lease!.DisposeAsync()));
        }

        return new SecretImportResponse(results, accessDenied);
    }

    /// <summary>Reports unattempted values while warning about metadata reserved earlier in the current batch.</summary>
    private static SecretImportItemResult NotAttempted(string name) => new(name, "notAttempted",
        "Import stopped because storage access was denied. A category reservation may have been saved; check this secret before retrying.");

    /// <summary>Maps expected storage and category failures without exposing values or SDK messages.</summary>
    private static SecretImportItemResult FailureResult(string name, Exception exception) => exception switch
    {
        RequestFailedException { Status: 403 } => new(name, "failed", "Storage access denied. A value or category reservation may have been saved. Contact your administrator."),
        RequestFailedException => new(name, "failed", "Storage operation failed. Check this secret and its category before retrying; a value or category reservation may have been saved."),
        ArgumentException or KeyNotFoundException or InvalidOperationException => new(name, "failed", "Category operation failed. Reload categories and check this secret before retrying."),
        _ => throw exception
    };

    private sealed class ImportOperation(SecretExportItem item)
    {
        public SecretExportItem Item { get; } = item;
        public IAsyncDisposable? Lease { get; set; }
        public SecretImportItemResult? Outcome { get; set; }
        public Exception? Failure { get; set; }
    }
}