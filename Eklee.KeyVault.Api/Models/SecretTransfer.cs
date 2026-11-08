using System.Text.Json.Serialization;

namespace Eklee.KeyVault.Api.Models;

/// <summary>An unencrypted, versioned application export. Category associations are deliberately not transferred.</summary>
[JsonUnmappedMemberHandling(JsonUnmappedMemberHandling.Disallow)]
public sealed record SecretExport
{
    public required int FormatVersion { get; init; }
    public required List<SecretExportItem> Secrets { get; init; }
}

/// <summary>A secret's original vault name, value, display name, and all user-defined vault tags.</summary>
[JsonUnmappedMemberHandling(JsonUnmappedMemberHandling.Disallow)]
public sealed record SecretExportItem
{
    public required string Name { get; init; }
    public required string Value { get; init; }
    public required Dictionary<string, string> Tags { get; init; }
    public string? DisplayName { get; init; }
}

/// <summary>A value-free outcome for one import entry.</summary>
public sealed record SecretImportItemResult(string Name, string Status, string? Error = null);

/// <summary>Reports partial completion without returning imported values or tags.</summary>
public sealed record SecretImportResponse(List<SecretImportItemResult> Results, bool AccessDenied);