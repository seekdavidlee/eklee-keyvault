using System.Text.Json;
using Azure;
using Eklee.KeyVault.Api.Models;
using Eklee.KeyVault.Api.Services;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;

namespace Eklee.KeyVault.Api.Controllers;

/// <summary>Transfers unencrypted secrets under the same read and write roles as the secrets API.</summary>
[ApiController]
[Route("api/secret-transfers")]
[Authorize(Roles = "Admin,User")]
[ResponseCache(NoStore = true, Location = ResponseCacheLocation.None)]
public class SecretTransfersController(SecretTransferService service) : ControllerBase
{
    /// <summary>Downloads all secrets belonging to a required existing category as unencrypted JSON.</summary>
    [HttpGet("export")]
    [ProducesResponseType(typeof(SecretExport), StatusCodes.Status200OK)]
    [ProducesResponseType(typeof(ProblemDetails), StatusCodes.Status400BadRequest)]
    [ProducesResponseType(typeof(ProblemDetails), StatusCodes.Status403Forbidden)]
    [ProducesResponseType(typeof(ProblemDetails), StatusCodes.Status503ServiceUnavailable)]
    public async Task<IActionResult> Export([FromQuery] string categoryId)
    {
        try
        {
            var export = await service.ExportAsync(categoryId);
            var bytes = JsonSerializer.SerializeToUtf8Bytes(export, new JsonSerializerOptions(JsonSerializerDefaults.Web));
            if (bytes.Length > SecretTransferService.MaximumFileBytes)
            {
                return Problem(title: "Export Too Large", detail: "This category exceeds the 10 MiB transfer limit.", statusCode: 400);
            }

            return File(bytes, "application/json", "secrets-export.json");
        }
        catch (Exception exception) when (exception is ArgumentException or KeyNotFoundException)
        {
            return Problem(title: "Invalid Category", detail: "Choose an existing category containing at most 1000 secrets.", statusCode: 400);
        }
        catch (RequestFailedException exception)
        {
            return StorageProblem(exception.Status);
        }
    }

    /// <summary>Validates the entire file before writing; returns value-free per-entry results and rejects unauthorized writes.</summary>
    [HttpPost("import")]
    [Authorize(Roles = "Admin")]
    [RequestSizeLimit(SecretTransferService.MaximumFileBytes)]
    [ProducesResponseType(typeof(SecretImportResponse), StatusCodes.Status200OK)]
    [ProducesResponseType(typeof(ProblemDetails), StatusCodes.Status400BadRequest)]
    [ProducesResponseType(StatusCodes.Status403Forbidden)]
    [ProducesResponseType(typeof(ProblemDetails), StatusCodes.Status503ServiceUnavailable)]
    public async Task<IActionResult> Import([FromQuery] string? categoryId, [FromBody] JsonElement document)
    {
        try
        {
            var result = await service.ImportAsync(categoryId, document);
            return StatusCode(result.AccessDenied ? 403 : 200, result);
        }
        catch (ArgumentException exception)
        {
            return Problem(title: "Invalid Import", detail: exception.Message, statusCode: 400);
        }
        catch (KeyNotFoundException)
        {
            return Problem(title: "Invalid Category", detail: "Choose an existing destination category.", statusCode: 400);
        }
        catch (RequestFailedException exception)
        {
            return StorageProblem(exception.Status);
        }
    }

    /// <summary>Maps storage failures without disclosing SDK messages, request bodies, tags or values.</summary>
    private ObjectResult StorageProblem(int status) => Problem(title: status == 403 ? "Access Denied" : "Transfer Failed",
        detail: status == 403 ? "You do not have storage access. Contact your administrator." : "Storage is unavailable. Reload and try again.",
        statusCode: status == 403 ? 403 : 503);
}