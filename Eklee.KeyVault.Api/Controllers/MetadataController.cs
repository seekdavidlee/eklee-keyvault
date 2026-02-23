using Azure;
using Eklee.KeyVault.Api.Models;
using Eklee.KeyVault.Api.Services;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;

namespace Eklee.KeyVault.Api.Controllers;

/// <summary>
/// Manages user-defined display metadata for Key Vault secrets stored in blob storage.
/// Uses blob ETags for optimistic concurrency control on writes.
/// </summary>
[ApiController]
[Route("api/[controller]")]
[Authorize(Roles = "Admin")]
public class MetadataController(BlobService blobService, ILogger<MetadataController> logger) : ControllerBase
{
    /// <summary>
    /// Retrieves all secret display-name metadata from blob storage.
    /// Returns the blob ETag in the response header for optimistic concurrency.
    /// </summary>
    /// <returns>The <see cref="SecretItemMetaList"/> containing all metadata entries.</returns>
    /// <response code="200">Returns the metadata list with ETag header.</response>
    [HttpGet]
    [ProducesResponseType(typeof(SecretItemMetaList), StatusCodes.Status200OK)]
    public async Task<IActionResult> GetMetadata()
    {
        var (metaList, etag) = await blobService.GetMetaAsync();

        if (etag is not null)
        {
            Response.Headers.ETag = etag;
        }

        return Ok(metaList);
    }

    /// <summary>
    /// Replaces the entire secret metadata list in blob storage.
    /// Requires the <c>If-Match</c> header with the current ETag for optimistic concurrency.
    /// When the metadata blob does not exist yet, omit the <c>If-Match</c> header.
    /// </summary>
    /// <param name="metaList">The updated metadata list to persist.</param>
    /// <response code="204">The metadata was updated successfully.</response>
    /// <response code="400">The request body or headers are invalid.</response>
    /// <response code="409">The ETag does not match — the data was modified by another admin.</response>
    [HttpPut]
    [ProducesResponseType(StatusCodes.Status204NoContent)]
    [ProducesResponseType(StatusCodes.Status400BadRequest)]
    [ProducesResponseType(StatusCodes.Status409Conflict)]
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

        // Read the If-Match header; null means first-time creation
        var ifMatchHeader = Request.Headers.IfMatch.FirstOrDefault();

        try
        {
            var newEtag = await blobService.UpdateMetaAsync(metaList, ifMatchHeader);
            logger.LogInformation("Updated secret metadata with {Count} items", metaList.Items?.Count ?? 0);
            Response.Headers.ETag = newEtag;
            return NoContent();
        }
        catch (RequestFailedException ex) when (ex.Status is 409 or 412)
        {
            logger.LogWarning("ETag conflict when updating metadata: {Message}", ex.Message);
            return Conflict(new ProblemDetails
            {
                Title = "Conflict",
                Detail = "The metadata was modified by another admin. Please reload and try again.",
                Status = StatusCodes.Status409Conflict
            });
        }
    }
}
