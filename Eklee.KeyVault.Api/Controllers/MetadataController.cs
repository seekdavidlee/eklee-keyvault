using Eklee.KeyVault.Api.Models;
using Eklee.KeyVault.Api.Services;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;

namespace Eklee.KeyVault.Api.Controllers;

/// <summary>
/// Manages user-defined display metadata for Key Vault secrets stored in blob storage.
/// </summary>
[ApiController]
[Route("api/[controller]")]
[Authorize(Roles = "Admin")]
public class MetadataController(BlobService blobService, ILogger<MetadataController> logger) : ControllerBase
{
    /// <summary>
    /// Retrieves all secret display-name metadata from blob storage.
    /// </summary>
    /// <returns>The <see cref="SecretItemMetaList"/> containing all metadata entries.</returns>
    /// <response code="200">Returns the metadata list.</response>
    [HttpGet]
    [ProducesResponseType(typeof(SecretItemMetaList), StatusCodes.Status200OK)]
    public async Task<IActionResult> GetMetadata()
    {
        var metaList = await blobService.GetMetaAsync();
        return Ok(metaList);
    }

    /// <summary>
    /// Replaces the entire secret metadata list in blob storage.
    /// </summary>
    /// <param name="metaList">The updated metadata list to persist.</param>
    /// <response code="204">The metadata was updated successfully.</response>
    /// <response code="400">The request body is invalid.</response>
    [HttpPut]
    [ProducesResponseType(StatusCodes.Status204NoContent)]
    [ProducesResponseType(StatusCodes.Status400BadRequest)]
    public async Task<IActionResult> UpdateMetadata([FromBody] SecretItemMetaList metaList)
    {
        if (metaList is null)
        {
            return BadRequest(new ProblemDetails
            {
                Title = "Invalid Request",
                Detail = "The metadata list cannot be null.",
                Status = StatusCodes.Status400BadRequest
            });
        }

        await blobService.UpdateMetaAsync(metaList);
        logger.LogInformation("Updated secret metadata with {Count} items", metaList.Items?.Count ?? 0);
        return NoContent();
    }
}
