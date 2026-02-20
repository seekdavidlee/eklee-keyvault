namespace Eklee.KeyVault.Api.Models;

/// <summary>
/// API response wrapper for the user access list.
/// Includes the blob ETag so the client can send it back via <c>If-Match</c> for optimistic concurrency.
/// </summary>
public class UserAccessResponse
{
    /// <summary>The blob ETag representing the current version of the user access data.</summary>
    public string? ETag { get; set; }

    /// <summary>All registered user access records.</summary>
    public List<UserAccess> Users { get; set; } = [];
}
