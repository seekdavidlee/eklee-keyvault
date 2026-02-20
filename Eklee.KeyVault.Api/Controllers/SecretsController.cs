using Eklee.KeyVault.Api.Models;
using Eklee.KeyVault.Api.Services;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;

namespace Eklee.KeyVault.Api.Controllers;

/// <summary>
/// Provides endpoints for listing Key Vault secrets and retrieving individual secret values.
/// Combines secret data from Key Vault with user-defined display metadata from blob storage.
/// </summary>
[ApiController]
[Route("api/[controller]")]
[Authorize]
public class SecretsController(KeyVaultService keyVaultService, BlobService blobService, ILogger<SecretsController> logger) : ControllerBase
{
    /// <summary>
    /// Lists all Key Vault secrets combined with their user-defined display metadata.
    /// </summary>
    /// <returns>A list of <see cref="SecretItemView"/> objects.</returns>
    /// <response code="200">Returns the list of secrets with metadata.</response>
    /// <response code="403">The caller does not have access to Key Vault or blob storage.</response>
    [HttpGet]
    [ProducesResponseType(typeof(IEnumerable<SecretItemView>), StatusCodes.Status200OK)]
    [ProducesResponseType(StatusCodes.Status403Forbidden)]
    public async Task<IActionResult> GetSecrets()
    {
        try
        {
            var metaList = await blobService.GetMetaAsync();
            var secrets = await keyVaultService.GetSecretsAsync();
            var views = secrets.Select(s => new SecretItemView(s, metaList)).ToList();

            logger.LogInformation("Returning {Count} secrets", views.Count);
            return Ok(views);
        }
        catch (Azure.RequestFailedException ex) when (ex.Status == 403)
        {
            logger.LogWarning("Access denied when listing secrets: {Message}", ex.Message);
            return Problem(
                title: "Access Denied",
                detail: "You do not have access. Please contact your administrator.",
                statusCode: StatusCodes.Status403Forbidden);
        }
    }

    /// <summary>
    /// Retrieves the value of a single Key Vault secret by name.
    /// </summary>
    /// <param name="name">The name of the secret.</param>
    /// <returns>The secret value as a plain string.</returns>
    /// <response code="200">Returns the secret value.</response>
    /// <response code="404">The secret was not found.</response>
    [HttpGet("{name}/value")]
    [ProducesResponseType(typeof(string), StatusCodes.Status200OK)]
    [ProducesResponseType(StatusCodes.Status404NotFound)]
    public async Task<IActionResult> GetSecretValue(string name)
    {
        var value = await keyVaultService.GetSecretAsync(name);
        if (value is null)
        {
            return Problem(
                title: "Not Found",
                detail: $"Secret '{name}' was not found.",
                statusCode: StatusCodes.Status404NotFound);
        }

        return Ok(new { value });
    }
}
