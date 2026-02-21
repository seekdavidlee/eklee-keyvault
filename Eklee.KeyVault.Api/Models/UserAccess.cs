namespace Eklee.KeyVault.Api.Models;

/// <summary>
/// Represents a single user's access record, stored in the user_access.json blob.
/// The <see cref="ObjectId"/> is the primary key, sourced from the Entra ID "oid" JWT claim.
/// </summary>
public class UserAccess
{
    /// <summary>The Entra ID object identifier (oid claim) — stable GUID for the user.</summary>
    public string? ObjectId { get; set; }

    /// <summary>The user's email address or user principal name, used for display and admin lookup.</summary>
    public string? Email { get; set; }

    /// <summary>The authorization role assigned to this user.</summary>
    public UserRole Role { get; set; }

    /// <summary>The UTC date and time when this user record was created.</summary>
    public DateTime CreatedAt { get; set; }
}
