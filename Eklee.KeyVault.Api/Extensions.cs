namespace Eklee.KeyVault.Api;

using System.Security.Claims;
using System.Text.RegularExpressions;

/// <summary>
/// Shared helper methods used across the application.
/// </summary>
public static class Extensions
{
    private static readonly Regex hashedAssetName = new(
        @"^.+-[A-Za-z0-9_-]{8}\.(js|css|png|jpg|jpeg|gif|svg|webp|avif|ico|woff|woff2|ttf|otf)$",
        RegexOptions.CultureInvariant | RegexOptions.NonBacktracking);

    /// <summary>Creates the shared cache policy for physical SPA files and entry-page fallbacks.</summary>
    public static StaticFileOptions CreateFrontendStaticFileOptions() => new()
    {
        OnPrepareResponse = response =>
        {
            var path = response.Context.Request.Path;
            if (string.Equals(response.File.Name, "index.html", StringComparison.OrdinalIgnoreCase))
            {
                response.Context.Response.Headers.CacheControl = "no-cache";
            }
            else if (path.Equals(new PathString("/config.js")))
            {
                response.Context.Response.Headers.CacheControl = "no-store";
            }
            else if (path.StartsWithSegments("/assets", StringComparison.Ordinal) &&
                     hashedAssetName.IsMatch(response.File.Name))
            {
                response.Context.Response.Headers.CacheControl = "public, max-age=31536000, immutable";
            }
        }
    };

    /// <summary>
    /// Determines whether a principal carries the maintainer dev hosted E2E
    /// application role issued by Microsoft Entra ID.
    /// </summary>
    /// <param name="principal">The authenticated principal to inspect.</param>
    /// <returns><see langword="true"/> when the E2E application role is present.</returns>
    public static bool HasE2eApplicationRole(this ClaimsPrincipal principal) =>
        principal.Claims.Any(claim =>
            claim.Value == "E2E.Tester" &&
            claim.Type is ClaimTypes.Role or "roles");

    /// <summary>
    /// Strips carriage-return and line-feed characters from a value before it is
    /// written to a log sink, preventing log-forging attacks (CWE-117).
    /// </summary>
    /// <param name="value">The raw value to sanitize.</param>
    /// <returns>The sanitized string, or <see cref="string.Empty"/> when <paramref name="value"/> is <c>null</c>.</returns>
    public static string SanitizeForLog(this string? value) =>
        value?.Replace("\r", "").Replace("\n", "") ?? string.Empty;
}
