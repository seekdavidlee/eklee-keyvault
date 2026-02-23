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
}
