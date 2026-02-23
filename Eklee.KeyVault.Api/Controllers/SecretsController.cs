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
[Authorize(Roles = "Admin,User")]
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
            var (metaList, _) = await blobService.GetMetaAsync();
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

    /// <summary>
    /// Creates or updates a Key Vault secret. Only users with the Admin role can call this endpoint.
    /// If a secret with the specified name already exists, its value is replaced.
    /// </summary>
    /// <param name="name">The name of the secret to create or update.</param>
    /// <param name="request">The request body containing the secret value.</param>
    /// <returns>The name of the secret that was set.</returns>
    /// <response code="200">The secret was created or updated successfully.</response>
    /// <response code="400">The request body is invalid.</response>
    /// <response code="403">The caller does not have the Admin role.</response>
    [HttpPut("{name}")]
    [Authorize(Roles = "Admin")]
    [ProducesResponseType(StatusCodes.Status200OK)]
    [ProducesResponseType(StatusCodes.Status400BadRequest)]
    [ProducesResponseType(StatusCodes.Status403Forbidden)]
    public async Task<IActionResult> SetSecret(string name, [FromBody] SecretSetRequest request)
    {
        if (string.IsNullOrWhiteSpace(name))
        {
            return Problem(
                title: "Invalid Request",
                detail: "Secret name cannot be empty.",
                statusCode: StatusCodes.Status400BadRequest);
        }

        try
        {
            var secretName = await keyVaultService.SetSecretAsync(name, request.Value);
            logger.LogInformation("Admin set secret {SecretName}", secretName);
            return Ok(new { name = secretName });
        }
        catch (Azure.RequestFailedException ex) when (ex.Status == 403)
        {
            logger.LogWarning("Access denied when setting secret {SecretName}: {Message}", name, ex.Message);
            return Problem(
                title: "Access Denied",
                detail: "You do not have permission to modify secrets in Key Vault.",
                statusCode: StatusCodes.Status403Forbidden);
        }
    }

    /// <summary>
    /// Deletes a Key Vault secret by name. Only users with the Admin role can call this endpoint.
    /// The secret is soft-deleted and can be recovered within the vault's retention period.
    /// </summary>
    /// <param name="name">The name of the secret to delete.</param>
    /// <response code="204">The secret was deleted successfully.</response>
    /// <response code="403">The caller does not have the Admin role.</response>
    /// <response code="404">The secret was not found.</response>
    [HttpDelete("{name}")]
    [Authorize(Roles = "Admin")]
    [ProducesResponseType(StatusCodes.Status204NoContent)]
    [ProducesResponseType(StatusCodes.Status403Forbidden)]
    [ProducesResponseType(StatusCodes.Status404NotFound)]
    public async Task<IActionResult> DeleteSecret(string name)
    {
        try
        {
            await keyVaultService.DeleteSecretAsync(name);
            logger.LogInformation("Admin deleted secret {SecretName}", name);
            return NoContent();
        }
        catch (Azure.RequestFailedException ex) when (ex.Status == 404)
        {
            logger.LogWarning("Secret {SecretName} not found for deletion", name);
            return Problem(
                title: "Not Found",
                detail: $"Secret '{name}' was not found.",
                statusCode: StatusCodes.Status404NotFound);
        }
        catch (Azure.RequestFailedException ex) when (ex.Status == 403)
        {
            logger.LogWarning("Access denied when deleting secret {SecretName}: {Message}", name, ex.Message);
            return Problem(
                title: "Access Denied",
                detail: "You do not have permission to delete secrets in Key Vault.",
                statusCode: StatusCodes.Status403Forbidden);
        }
    }
}
