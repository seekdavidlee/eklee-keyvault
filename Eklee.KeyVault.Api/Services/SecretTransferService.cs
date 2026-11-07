using System.Text;
using System.Text.Json;
using System.Runtime.ExceptionServices;
using Azure;
using Eklee.KeyVault.Api.Models;

namespace Eklee.KeyVault.Api.Services;

/// <summary>Validates complete exports and coordinates category-aware, non-overwriting imports.</summary>
public class SecretTransferService(KeyVaultService keyVaultService, BlobService blobService, CategoryService categoryService)
{
    public const int MaximumFileBytes = 10 * 1024 * 1024;
    public const int MaximumSecrets = 1000;
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
            .Where(associations.ContainsKey).ToList();
        if (names.Count > MaximumSecrets)
        {
            throw new ArgumentException("This category exceeds the 1000-secret transfer limit.");
        }

        var items = new List<SecretExportItem>();
        foreach (var name in names)
        {
            var secret = await keyVaultService.GetSecretWithTagsAsync(name);
            items.Add(new SecretExportItem
            {
                Name = secret.Name, Value = secret.Value,
                Tags = new Dictionary<string, string>(secret.Properties.Tags),
                DisplayName = associations[name].DisplayName
            });
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
        foreach (var item in export.Secrets)
        {
            if (accessDenied)
            {
                results.Add(new(item.Name, "notAttempted", "Import stopped because storage access was denied."));
                continue;
            }

            if (!seen.Add(item.Name))
            {
                results.Add(new(item.Name, "skipped", "Duplicate name within the file."));
                continue;
            }

            try
            {
                results.Add(await ImportItemAsync(item, categoryId));
            }
            catch (RequestFailedException exception)
            {
                accessDenied = exception.Status == 403;
                results.Add(new(item.Name, "failed", accessDenied
                    ? "Storage access denied. Contact your administrator."
                    : "Storage operation failed. Check this secret and its category before retrying; a value or category reservation may have been saved."));
            }
            catch (Exception exception) when (exception is ArgumentException or KeyNotFoundException or InvalidOperationException)
            {
                results.Add(new(item.Name, "failed", "Category operation failed. Reload categories and check this secret before retrying."));
            }
        }

        return new SecretImportResponse(results, accessDenied);
    }

    /// <summary>Completes lease cleanup before returning a single entry outcome to the batch.</summary>
    private async Task<SecretImportItemResult> ImportItemAsync(SecretExportItem item, string categoryId)
    {
        var operation = await blobService.AcquireSecretOperationAsync(item.Name);
        SecretImportItemResult? outcome = null;
        Exception? operationFailure = null;
        Exception? cleanupFailure = null;
        try
        {
            if (await keyVaultService.SecretExistsAsync(item.Name))
            {
                outcome = new(item.Name, "skipped", "This name already exists in the vault.");
            }
            else
            {
                await categoryService.AssociateSecretAsync(item.Name, categoryId);
                await keyVaultService.SetSecretWithTagsAsync(item.Name, item.Value, item.Tags);
                await categoryService.SetImportedDisplayNameAsync(item.Name, item.DisplayName ?? item.Name);
                outcome = new(item.Name, "imported");
            }
        }
        catch (Exception exception)
        {
            operationFailure = exception;
        }
        finally
        {
            try
            {
                await operation.DisposeAsync();
            }
            catch (Exception exception)
            {
                cleanupFailure = exception;
            }
        }

        var failure = operationFailure is RequestFailedException { Status: 403 } ? operationFailure
            : cleanupFailure is RequestFailedException { Status: 403 } ? cleanupFailure
            : operationFailure ?? cleanupFailure;
        if (failure is not null)
        {
            ExceptionDispatchInfo.Capture(failure).Throw();
        }

        return outcome ?? throw new InvalidOperationException("Import did not complete.");
    }
}