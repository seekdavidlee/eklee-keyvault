namespace Eklee.KeyVault.Api.Models;

/// <summary>
/// Contains a generated secret value that has not been persisted.
/// </summary>
public class SecretGenerationResponse
{
    /// <summary>Gets or sets the generated secret value.</summary>
    public string Value { get; set; } = string.Empty;
}