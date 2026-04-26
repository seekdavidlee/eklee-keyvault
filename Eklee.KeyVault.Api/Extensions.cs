namespace Eklee.KeyVault.Api;

/// <summary>
/// Shared helper methods used across the application.
/// </summary>
public static class Extensions
{
    /// <summary>
    /// Strips carriage-return and line-feed characters from a value before it is
    /// written to a log sink, preventing log-forging attacks (CWE-117).
    /// </summary>
    /// <param name="value">The raw value to sanitize.</param>
    /// <returns>The sanitized string, or <see cref="string.Empty"/> when <paramref name="value"/> is <c>null</c>.</returns>
    public static string SanitizeForLog(this string? value) =>
        value?.Replace("\r", "").Replace("\n", "") ?? string.Empty;
}
