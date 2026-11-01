using System.ComponentModel.DataAnnotations;

namespace Eklee.KeyVault.Api.Models;

/// <summary>
/// Request body for creating or updating a Key Vault secret.
/// </summary>
public class SecretSetRequest
{
    /// <summary>The value to store in the secret.</summary>
    [Required]
    public string Value { get; set; } = string.Empty;

    /// <summary>Gets or sets the required category for new secrets; existing associations cannot be changed.</summary>
    public string? CategoryId { get; set; }
}
