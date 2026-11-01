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
public partial class SecretsController(
    KeyVaultService keyVaultService,
    BlobService blobService,
    SecretGenerationService secretGenerationService,
    ILogger<SecretsController> logger,
    CategoryService categoryService) : ControllerBase
{
    /// <summary>
    /// Lists Key Vault secrets with display metadata, optionally filtered by category.
    /// </summary>
    /// <param name="categoryId">A persisted category ID, or null to list all secrets.</param>
    /// <returns>A list of <see cref="SecretItemView"/> objects.</returns>
    /// <response code="200">Returns the list of secrets with metadata.</response>
    /// <response code="403">The caller does not have access to Key Vault or blob storage.</response>
    /// <response code="404">The requested category does not exist.</response>
    [HttpGet]
    [ProducesResponseType(typeof(IEnumerable<SecretItemView>), StatusCodes.Status200OK)]
    [ProducesResponseType(StatusCodes.Status403Forbidden)]
    [ProducesResponseType(StatusCodes.Status404NotFound)]
    public async Task<IActionResult> GetSecrets([FromQuery] string? categoryId = null)
    {
        try
        {
            var (metaList, _) = await blobService.GetMetaAsync();
            if (categoryId is not null && !metaList.Categories.Any(category => category.Id == categoryId))
            {
                return Problem(title: "Category Not Found", detail: "Choose an existing category.", statusCode: 404);
            }

            var secrets = await keyVaultService.GetSecretsAsync();
            var views = secrets.Select(s => new SecretItemView(s, metaList)).ToList();
            if (categoryId is not null)
            {
                views = views.Where(view => view.Meta.CategoryId == categoryId).ToList();
            }

            LogReturningSecrets(logger, views.Count);
            return Ok(views);
        }
        catch (Azure.RequestFailedException ex) when (ex.Status == 403)
        {
            LogAccessDeniedListingSecrets(logger, ex.Message);
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
    /// <param name="request">The secret value and, for creation, a required category ID. Existing associations cannot change.</param>
    /// <returns>The name of the secret that was set.</returns>
    /// <response code="200">The secret was created or updated successfully.</response>
    /// <response code="400">The request body is invalid.</response>
    /// <response code="403">The caller does not have the Admin role.</response>
    /// <response code="409">An association change or concurrent metadata write was rejected.</response>
    [HttpPut("{name}")]
    [Authorize(Roles = "Admin")]
    [ProducesResponseType(StatusCodes.Status200OK)]
    [ProducesResponseType(StatusCodes.Status400BadRequest)]
    [ProducesResponseType(StatusCodes.Status403Forbidden)]
    [ProducesResponseType(StatusCodes.Status409Conflict)]
    public async Task<IActionResult> SetSecret(string name, [FromBody] SecretSetRequest request)
    {
        if (string.IsNullOrEmpty(name) || name.Length > 127 ||
            name.Any(character => !char.IsAsciiLetterOrDigit(character) && character != '-'))
        {
            return Problem(
                title: "Invalid Request",
                detail: "Secret name must contain between 1 and 127 ASCII letters, digits, or hyphens.",
                statusCode: StatusCodes.Status400BadRequest);
        }

        try
        {
            await using var operation = await blobService.AcquireSecretOperationAsync(name);
            await categoryService.AssociateSecretAsync(name, request.CategoryId);
            var secretName = await keyVaultService.SetSecretAsync(name, request.Value);
            LogAdminSetSecret(logger, secretName.SanitizeForLog());
            return Ok(new { name = secretName });
        }
        catch (ArgumentException ex)
        {
            return Problem(title: "Invalid Category", detail: ex.Message, statusCode: 400);
        }
        catch (KeyNotFoundException ex)
        {
            return Problem(title: "Invalid Category", detail: ex.Message, statusCode: 400);
        }
        catch (InvalidOperationException ex)
        {
            return Problem(title: "Category Conflict", detail: ex.Message, statusCode: 409);
        }
        catch (Azure.RequestFailedException ex) when (ex.Status is 409 or 412)
        {
            return Problem(title: "Category Conflict", detail: "Another operation is modifying this secret or its category metadata. Reload and try again.", statusCode: 409);
        }
        catch (Azure.RequestFailedException ex) when (ex.Status == 403)
        {
            LogAccessDeniedSettingSecret(logger, name.SanitizeForLog(), ex.Message);
            return Problem(
                title: "Access Denied",
                detail: "You do not have permission to modify secrets in Key Vault.",
                statusCode: StatusCodes.Status403Forbidden);
        }
    }

    /// <summary>
    /// Generates a candidate secret value without persisting it. Only users with the Admin role can call this endpoint.
    /// </summary>
    /// <param name="request">The character policy for the candidate value.</param>
    /// <returns>A generated secret candidate for administrator review.</returns>
    /// <response code="200">Returns a generated candidate value.</response>
    /// <response code="400">The requested generation policy is invalid.</response>
    /// <response code="403">The caller does not have the Admin role.</response>
    [HttpPost("generate")]
    [Authorize(Roles = "Admin")]
    [ProducesResponseType(typeof(SecretGenerationResponse), StatusCodes.Status200OK)]
    [ProducesResponseType(typeof(ProblemDetails), StatusCodes.Status400BadRequest)]
    [ProducesResponseType(StatusCodes.Status403Forbidden)]
    public IActionResult GenerateSecret([FromBody] SecretGenerationRequest request)
    {
        if (!secretGenerationService.TryGenerate(request, out var response, out var validationError))
        {
            return Problem(
                title: "Invalid Generation Policy",
                detail: validationError,
                statusCode: StatusCodes.Status400BadRequest);
        }

        return Ok(response);
    }

    /// <summary>
    /// Deletes a Key Vault secret by name. Only users with the Admin role can call this endpoint.
    /// The secret is soft-deleted and can be recovered within the vault's retention period.
    /// </summary>
    /// <param name="name">The name of the secret to delete.</param>
    /// <response code="204">The secret was deleted successfully.</response>
    /// <response code="403">The caller does not have the Admin role.</response>
    /// <response code="404">The secret was not found.</response>
    /// <response code="409">The delete or metadata cleanup conflicted; retry the same deletion.</response>
    [HttpDelete("{name}")]
    [Authorize(Roles = "Admin")]
    [ProducesResponseType(StatusCodes.Status204NoContent)]
    [ProducesResponseType(StatusCodes.Status403Forbidden)]
    [ProducesResponseType(StatusCodes.Status404NotFound)]
    [ProducesResponseType(StatusCodes.Status409Conflict)]
    public async Task<IActionResult> DeleteSecret(string name)
    {
        try
        {
            await using var operation = await blobService.AcquireSecretOperationAsync(name);
            var notFound = false;
            try
            {
                await keyVaultService.DeleteSecretAsync(name);
            }
            catch (Azure.RequestFailedException ex) when (ex.Status == 404)
            {
                notFound = true;
            }

            await categoryService.RemoveSecretAsync(name);
            if (notFound)
            {
                LogSecretNotFoundForDeletion(logger, name.SanitizeForLog());
                return Problem(
                    title: "Not Found",
                    detail: $"Secret '{name}' was not found.",
                    statusCode: StatusCodes.Status404NotFound);
            }

            LogAdminDeletedSecret(logger, name.SanitizeForLog());
            return NoContent();
        }
        catch (Azure.RequestFailedException ex) when (ex.Status is 409 or 412)
        {
            return Problem(title: "Metadata Conflict", detail: "Secret deletion or metadata cleanup conflicted. Reload and retry deleting the same secret.", statusCode: 409);
        }
        catch (Azure.RequestFailedException ex) when (ex.Status == 403)
        {
            LogAccessDeniedDeletingSecret(logger, name.SanitizeForLog(), ex.Message);
            return Problem(
                title: "Access Denied",
                detail: "You do not have permission to delete secrets in Key Vault.",
                statusCode: StatusCodes.Status403Forbidden);
        }
    }

    [LoggerMessage(Level = LogLevel.Information, Message = "Returning {Count} secrets")]
    private static partial void LogReturningSecrets(ILogger logger, int count);

    [LoggerMessage(Level = LogLevel.Warning, Message = "Access denied when listing secrets: {ErrorMessage}")]
    private static partial void LogAccessDeniedListingSecrets(ILogger logger, string errorMessage);

    [LoggerMessage(Level = LogLevel.Information, Message = "Admin set secret {SecretName}")]
    private static partial void LogAdminSetSecret(ILogger logger, string secretName);

    [LoggerMessage(Level = LogLevel.Warning, Message = "Access denied when setting secret {SecretName}: {ErrorMessage}")]
    private static partial void LogAccessDeniedSettingSecret(ILogger logger, string secretName, string errorMessage);

    [LoggerMessage(Level = LogLevel.Information, Message = "Admin deleted secret {SecretName}")]
    private static partial void LogAdminDeletedSecret(ILogger logger, string secretName);

    [LoggerMessage(Level = LogLevel.Warning, Message = "Secret {SecretName} not found for deletion")]
    private static partial void LogSecretNotFoundForDeletion(ILogger logger, string secretName);

    [LoggerMessage(Level = LogLevel.Warning, Message = "Access denied when deleting secret {SecretName}: {ErrorMessage}")]
    private static partial void LogAccessDeniedDeletingSecret(ILogger logger, string secretName, string errorMessage);
}
