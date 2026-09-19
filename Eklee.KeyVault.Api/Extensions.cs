namespace Eklee.KeyVault.Api;

using System.Security.Claims;

/// <summary>
/// Shared helper methods used across the application.
/// </summary>
public static class Extensions
{
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
