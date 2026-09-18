using System.Net.Http.Headers;
using System.Security.Claims;
using System.Text.Json;

namespace Eklee.KeyVault.Api.Services;

/// <summary>
/// Validates an incoming bearer token through the local Microsoft Entra ID Auth SDK sidecar.
/// </summary>
public sealed class MiseTokenValidator(HttpClient httpClient)
{
    private const string AuthorizationHeaderName = "Authorization";

    /// <summary>
    /// Gets the authentication scheme name used for validated MISE principals.
    /// </summary>
    public const string SchemeName = "Mise";

    /// <summary>
    /// Validates an authorization header and creates an authenticated principal from trusted sidecar claims.
    /// </summary>
    /// <param name="authorizationHeader">The incoming bearer authorization header.</param>
    /// <param name="cancellationToken">The request cancellation token.</param>
    /// <returns>A claims principal when validation succeeds; otherwise, <c>null</c>.</returns>
    public async Task<ClaimsPrincipal?> ValidateAsync(
        string? authorizationHeader,
        CancellationToken cancellationToken)
    {
        if (!AuthenticationHeaderValue.TryParse(authorizationHeader, out var header) ||
            !string.Equals(header.Scheme, "Bearer", StringComparison.OrdinalIgnoreCase) ||
            string.IsNullOrWhiteSpace(header.Parameter))
        {
            return null;
        }

        using var request = new HttpRequestMessage(HttpMethod.Get, "Validate");
        request.Headers.TryAddWithoutValidation(AuthorizationHeaderName, authorizationHeader);

        try
        {
            using var response = await httpClient.SendAsync(
                request,
                HttpCompletionOption.ResponseHeadersRead,
                cancellationToken);

            if (!response.IsSuccessStatusCode)
            {
                return null;
            }

            await using var responseStream = await response.Content.ReadAsStreamAsync(cancellationToken);
            using var document = await JsonDocument.ParseAsync(responseStream, cancellationToken: cancellationToken);

            return TryCreatePrincipal(document.RootElement, out var principal) ? principal : null;
        }
        catch (HttpRequestException)
        {
            return null;
        }
        catch (TaskCanceledException) when (!cancellationToken.IsCancellationRequested)
        {
            return null;
        }
        catch (JsonException)
        {
            return null;
        }
        catch (IOException)
        {
            return null;
        }
    }

    private static bool TryCreatePrincipal(JsonElement response, out ClaimsPrincipal? principal)
    {
        principal = null;

        if (response.ValueKind != JsonValueKind.Object ||
            !response.TryGetProperty("claims", out var claims) ||
            claims.ValueKind != JsonValueKind.Object ||
            !claims.TryGetProperty("oid", out var objectId) ||
            objectId.ValueKind != JsonValueKind.String)
        {
            return false;
        }

        var objectIdValue = objectId.GetString();
        if (string.IsNullOrWhiteSpace(objectIdValue))
        {
            return false;
        }

        var identity = new ClaimsIdentity(SchemeName);
        identity.AddClaim(new Claim("oid", objectIdValue));

        foreach (var claim in claims.EnumerateObject())
        {
            if (claim.NameEquals("oid"))
            {
                continue;
            }

            if (claim.NameEquals("roles"))
            {
                if (!TryAddRoleClaims(claim.Value, identity))
                {
                    return false;
                }

                continue;
            }

            var claimValue = claim.Value.ValueKind == JsonValueKind.String
                ? claim.Value.GetString()
                : null;
            if (
                !string.IsNullOrWhiteSpace(claimValue))
            {
                identity.AddClaim(new Claim(claim.Name, claimValue));
            }
        }

        principal = new ClaimsPrincipal(identity);
        return true;
    }

    private static bool TryAddRoleClaims(JsonElement roles, ClaimsIdentity identity)
    {
        if (roles.ValueKind != JsonValueKind.Array)
        {
            return false;
        }

        foreach (var role in roles.EnumerateArray())
        {
            var roleValue = role.ValueKind == JsonValueKind.String ? role.GetString() : null;
            if (string.IsNullOrWhiteSpace(roleValue))
            {
                return false;
            }

            identity.AddClaim(new Claim(ClaimTypes.Role, roleValue));
        }

        return true;
    }
}
