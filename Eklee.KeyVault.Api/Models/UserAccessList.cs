namespace Eklee.KeyVault.Api.Models;

/// <summary>
/// Collection of user access records stored in the user_access.json blob.
/// Provides lookup helpers by Object ID and email.
/// </summary>
public class UserAccessList
{
    /// <summary>All registered user access records.</summary>
    public List<UserAccess> Users { get; set; } = [];

    /// <summary>
    /// Finds a user by their Entra ID object identifier.
    /// </summary>
    /// <param name="objectId">The oid claim value to match.</param>
    /// <returns>The matching <see cref="UserAccess"/>, or <c>null</c> if not found.</returns>
    public UserAccess? GetByObjectId(string objectId)
    {
        return Users.Find(u =>
            string.Equals(u.ObjectId, objectId, StringComparison.OrdinalIgnoreCase));
    }

    /// <summary>
    /// Finds a user by their email address or user principal name.
    /// </summary>
    /// <param name="email">The email to match (case-insensitive).</param>
    /// <returns>The matching <see cref="UserAccess"/>, or <c>null</c> if not found.</returns>
    public UserAccess? GetByEmail(string email)
    {
        return Users.Find(u =>
            string.Equals(u.Email, email, StringComparison.OrdinalIgnoreCase));
    }
}
