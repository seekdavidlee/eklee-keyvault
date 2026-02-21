using Azure;
using Eklee.KeyVault.Api.Models;
using Eklee.KeyVault.Api.Services;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;

namespace Eklee.KeyVault.Api.Controllers;

/// <summary>
/// Manages user access records stored in blob storage.
/// The first authenticated user is auto-registered as Admin.
/// Subsequent users must be added by an admin before they can access the application.
/// Uses blob ETags for optimistic concurrency on writes.
/// </summary>
[ApiController]
[Route("api/[controller]")]
public class UserAccessController(UserAccessService userAccessService, ILogger<UserAccessController> logger) : ControllerBase
{
    /// <summary>
    /// Returns the current user's access record. If the user access list is empty (no blob exists),
    /// the caller is automatically registered as the first Admin.
    /// Returns 403 if the user is authenticated but not registered.
    /// </summary>
    /// <returns>The caller's <see cref="UserAccess"/> record.</returns>
    /// <response code="200">The user's access record.</response>
    /// <response code="403">The user is authenticated but not registered for access.</response>
    [HttpGet("me")]
    [Authorize]
    [ProducesResponseType(typeof(UserAccess), StatusCodes.Status200OK)]
    [ProducesResponseType(StatusCodes.Status403Forbidden)]
    public async Task<IActionResult> GetMe()
    {
        var objectId = GetObjectId();
        var email = GetEmail();

        if (objectId is null)
        {
            return Problem(
                title: "Missing Identity",
                detail: "The token does not contain an object identifier claim.",
                statusCode: StatusCodes.Status400BadRequest);
        }

        var (list, etag) = await userAccessService.GetUserAccessListAsync();

        // First-user auto-registration: when no users exist, the caller becomes Admin
        if (list.Users.Count == 0)
        {
            var adminUser = new UserAccess
            {
                ObjectId = objectId,
                Email = email ?? "unknown",
                Role = UserRole.Admin,
                CreatedAt = DateTime.UtcNow
            };
            list.Users.Add(adminUser);

            try
            {
                await userAccessService.UpdateUserAccessListAsync(list, etag);
                logger.LogInformation("First user {ObjectId} auto-registered as Admin", objectId);
                return Ok(adminUser);
            }
            catch (RequestFailedException ex) when (ex.Status is 409 or 412)
            {
                // Another user won the race to be first — re-read and fall through to lookup
                logger.LogWarning("First-user registration race detected for {ObjectId}", objectId);
                (list, etag) = await userAccessService.GetUserAccessListAsync();
            }
        }

        // Look up by Object ID first, then fall back to email
        var user = list.GetByObjectId(objectId);
        if (user is null && email is not null)
        {
            user = list.GetByEmail(email);
            if (user is not null)
            {
                // Backfill the Object ID for future lookups
                user.ObjectId = objectId;
                try
                {
                    await userAccessService.UpdateUserAccessListAsync(list, etag);
                    logger.LogInformation("Backfilled ObjectId for user {Email}", email);
                }
                catch (RequestFailedException ex) when (ex.Status is 409 or 412)
                {
                    // Non-critical — next login will retry the backfill
                    logger.LogWarning("ETag conflict during ObjectId backfill for {Email}: {Message}", email, ex.Message);
                }
            }
        }

        if (user is null)
        {
            logger.LogWarning("Access denied for unregistered user {ObjectId}", objectId);
            return Problem(
                title: "Access Denied",
                detail: "You are not registered for access. Please contact your administrator.",
                statusCode: StatusCodes.Status403Forbidden);
        }

        return Ok(user);
    }

    /// <summary>
    /// Returns the full user access list with the blob ETag for concurrency control.
    /// Admin-only endpoint.
    /// </summary>
    /// <returns>A <see cref="UserAccessResponse"/> containing all users and the current ETag.</returns>
    /// <response code="200">The user access list with ETag.</response>
    [HttpGet("users")]
    [Authorize(Roles = "Admin")]
    [ProducesResponseType(typeof(UserAccessResponse), StatusCodes.Status200OK)]
    public async Task<IActionResult> GetUsers()
    {
        var (list, etag) = await userAccessService.GetUserAccessListAsync();

        if (etag is not null)
        {
            Response.Headers.ETag = etag;
        }

        return Ok(new UserAccessResponse
        {
            ETag = etag,
            Users = list.Users
        });
    }

    /// <summary>
    /// Replaces the full user access list in blob storage.
    /// Requires the <c>If-Match</c> header with the current ETag for optimistic concurrency.
    /// Validates that at least one Admin remains after the update.
    /// Admin-only endpoint.
    /// </summary>
    /// <param name="request">The updated user access list.</param>
    /// <response code="204">The user access list was updated successfully.</response>
    /// <response code="400">Validation failed (e.g., no admins remaining).</response>
    /// <response code="409">The ETag does not match — the data was modified by another admin.</response>
    [HttpPut("users")]
    [Authorize(Roles = "Admin")]
    [ProducesResponseType(StatusCodes.Status204NoContent)]
    [ProducesResponseType(StatusCodes.Status400BadRequest)]
    [ProducesResponseType(StatusCodes.Status409Conflict)]
    public async Task<IActionResult> UpdateUsers([FromBody] UserAccessList request)
    {
        if (request is null)
        {
            return BadRequest(new ProblemDetails
            {
                Title = "Invalid Request",
                Detail = "The user access list cannot be null.",
                Status = StatusCodes.Status400BadRequest
            });
        }

        // Ensure at least one admin remains
        if (!request.Users.Exists(u => u.Role == UserRole.Admin))
        {
            return BadRequest(new ProblemDetails
            {
                Title = "Validation Failed",
                Detail = "At least one user must have the Admin role.",
                Status = StatusCodes.Status400BadRequest
            });
        }

        var ifMatchHeader = Request.Headers.IfMatch.FirstOrDefault();
        if (string.IsNullOrWhiteSpace(ifMatchHeader))
        {
            return BadRequest(new ProblemDetails
            {
                Title = "Missing If-Match Header",
                Detail = "The If-Match header with the current ETag is required for updates.",
                Status = StatusCodes.Status400BadRequest
            });
        }

        try
        {
            var newEtag = await userAccessService.UpdateUserAccessListAsync(request, ifMatchHeader);
            logger.LogInformation("Updated user access list with {Count} users", request.Users.Count);
            Response.Headers.ETag = newEtag;
            return NoContent();
        }
        catch (RequestFailedException ex) when (ex.Status is 409 or 412)
        {
            logger.LogWarning("ETag conflict when updating user access list: {Message}", ex.Message);
            return Conflict(new ProblemDetails
            {
                Title = "Conflict",
                Detail = "The user access list was modified by another admin. Please reload and try again.",
                Status = StatusCodes.Status409Conflict
            });
        }
    }

    /// <summary>
    /// Extracts the Entra ID object identifier (oid) from the current user's claims.
    /// </summary>
    private string? GetObjectId()
    {
        return User.FindFirst("http://schemas.microsoft.com/identity/claims/objectidentifier")?.Value
            ?? User.FindFirst("oid")?.Value;
    }

    /// <summary>
    /// Extracts the email or user principal name from the current user's claims.
    /// </summary>
    private string? GetEmail()
    {
        return User.FindFirst("preferred_username")?.Value
            ?? User.FindFirst("email")?.Value
            ?? User.FindFirst("upn")?.Value;
    }
}
