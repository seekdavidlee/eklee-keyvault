using System.Text.Encodings.Web;
using Microsoft.AspNetCore.Authentication;
using Microsoft.Extensions.Options;

namespace Eklee.KeyVault.Api.Services;

/// <summary>
/// Authenticates requests using claims returned by the local Microsoft Entra ID Auth SDK sidecar.
/// </summary>
public sealed class MiseAuthenticationHandler(
    IOptionsMonitor<AuthenticationSchemeOptions> options,
    ILoggerFactory logger,
    UrlEncoder encoder,
    MiseTokenValidator tokenValidator)
    : AuthenticationHandler<AuthenticationSchemeOptions>(options, logger, encoder)
{
    /// <summary>
    /// Authenticates the incoming request through the configured local MISE sidecar.
    /// </summary>
    /// <returns>A successful ticket only when the sidecar returns valid required claims.</returns>
    protected override async Task<AuthenticateResult> HandleAuthenticateAsync()
    {
        var principal = await tokenValidator.ValidateAsync(
            Request.Headers.Authorization.ToString(),
            Context.RequestAborted);

        return principal is null
            ? AuthenticateResult.Fail("MISE token validation failed.")
            : AuthenticateResult.Success(new AuthenticationTicket(principal, Scheme.Name));
    }
}
