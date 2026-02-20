using System.Security.Claims;
using Eklee.KeyVault.Api.Services;
using Microsoft.AspNetCore.Authentication;

namespace Eklee.KeyVault.Api.Services;

/// <summary>
/// Enriches the authenticated user's identity with a role claim based on the user_access.json blob.
/// Runs after JWT validation on every authenticated request, adding a <see cref="ClaimTypes.Role"/>
/// claim so that <c>[Authorize(Roles = "...")]</c> works natively.
/// </summary>
public class UserAccessClaimsTransformation(UserAccessService userAccessService) : IClaimsTransformation
{
    /// <summary>
    /// Inspects the user's "oid" claim (Entra ID object identifier) and, if the user is
    /// registered in user_access.json, adds a role claim to the principal.
    /// </summary>
    /// <param name="principal">The current claims principal after JWT validation.</param>
    /// <returns>The enriched <see cref="ClaimsPrincipal"/>.</returns>
    public async Task<ClaimsPrincipal> TransformAsync(ClaimsPrincipal principal)
    {
        var objectId = principal.FindFirst("http://schemas.microsoft.com/identity/claims/objectidentifier")?.Value
                    ?? principal.FindFirst("oid")?.Value;

        if (objectId is null)
        {
            return principal;
        }

        var role = await userAccessService.GetUserRoleAsync(objectId);
        if (role is null)
        {
            return principal;
        }

        var identity = principal.Identity as ClaimsIdentity;
        if (identity is not null && !principal.HasClaim(ClaimTypes.Role, role.Value.ToString()))
        {
            identity.AddClaim(new Claim(ClaimTypes.Role, role.Value.ToString()));
        }

        return principal;
    }
}
