namespace Eklee.KeyVault.Api.Models;

/// <summary>Requests a shared category name; validation returns actionable problem details.</summary>
public sealed record CategoryNameRequest
{
    /// <summary>Gets the requested name, trimmed and validated by category rules.</summary>
    public string? Name { get; init; }
}