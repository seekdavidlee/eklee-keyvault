using System.ComponentModel.DataAnnotations;

namespace Eklee.KeyVault.Api.Models;

/// <summary>
/// Defines the policy used to generate a candidate secret value.
/// </summary>
public class SecretGenerationRequest
{
    /// <summary>Gets or sets the total number of characters in the generated value.</summary>
    [Range(1, 128)]
    public int TotalLength { get; set; } = 15;

    /// <summary>Gets or sets the minimum number of alphabetic characters.</summary>
    [Range(0, 128)]
    public int MinimumAlphabeticCharacters { get; set; } = 1;

    /// <summary>Gets or sets the minimum number of numeric characters.</summary>
    [Range(0, 128)]
    public int MinimumNumericCharacters { get; set; } = 1;

    /// <summary>Gets or sets the minimum number of special characters.</summary>
    [Range(0, 128)]
    public int MinimumSpecialCharacters { get; set; } = 3;
}