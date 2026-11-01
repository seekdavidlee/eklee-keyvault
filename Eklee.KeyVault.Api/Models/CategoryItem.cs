namespace Eklee.KeyVault.Api.Models;

/// <summary>A shared category whose persisted identity is independent of its display name.</summary>
/// <param name="Id">Stable category identifier.</param>
/// <param name="Name">User-facing name.</param>
/// <param name="IsDefault">Whether startup assigns uncategorized secrets to this category.</param>
public sealed record CategoryItem(string Id, string Name, bool IsDefault);