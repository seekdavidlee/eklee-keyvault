namespace Eklee.KeyVault.Api.Models;

/// <summary>
/// Defines the access roles available for user authorization.
/// </summary>
public enum UserRole
{
    /// <summary>Full access including user management and metadata editing.</summary>
    Admin,

    /// <summary>Read-only access to secrets.</summary>
    User
}
