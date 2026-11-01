using Azure;
using Eklee.KeyVault.Api.Models;
using Eklee.KeyVault.Api.Services;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;

namespace Eklee.KeyVault.Api.Controllers;

/// <summary>Lists shared categories for users and manages them for administrators.</summary>
[ApiController]
[Route("api/[controller]")]
[Authorize(Roles = "Admin,User")]
public class CategoriesController(CategoryService categoryService) : ControllerBase
{
    /// <summary>Lists categories without changing existing secret authorization.</summary>
    /// <returns>The shared category list.</returns>
    [HttpGet]
    [ProducesResponseType(typeof(IEnumerable<CategoryItem>), StatusCodes.Status200OK)]
    [ProducesResponseType(typeof(ProblemDetails), StatusCodes.Status403Forbidden)]
    public Task<IActionResult> GetCategories() => ExecuteAsync(async () => Ok(await categoryService.GetCategoriesAsync()));

    /// <summary>Creates a shared category with a validated unique name.</summary>
    /// <param name="request">Requested name.</param>
    /// <returns>The created category.</returns>
    [HttpPost]
    [Authorize(Roles = "Admin")]
    [ProducesResponseType(typeof(CategoryItem), StatusCodes.Status201Created)]
    [ProducesResponseType(typeof(ProblemDetails), StatusCodes.Status400BadRequest)]
    [ProducesResponseType(typeof(ProblemDetails), StatusCodes.Status409Conflict)]
    public Task<IActionResult> CreateCategory([FromBody] CategoryNameRequest request) => ExecuteAsync(async () =>
    {
        var category = await categoryService.CreateAsync(request.Name);
        return Created("/api/categories", category);
    });

    /// <summary>Renames a category while retaining its identity and default role.</summary>
    /// <param name="id">Stable identifier.</param>
    /// <param name="request">Requested name.</param>
    /// <returns>The renamed category.</returns>
    [HttpPut("{id}")]
    [Authorize(Roles = "Admin")]
    [ProducesResponseType(typeof(CategoryItem), StatusCodes.Status200OK)]
    [ProducesResponseType(typeof(ProblemDetails), StatusCodes.Status400BadRequest)]
    [ProducesResponseType(typeof(ProblemDetails), StatusCodes.Status404NotFound)]
    [ProducesResponseType(typeof(ProblemDetails), StatusCodes.Status409Conflict)]
    public Task<IActionResult> RenameCategory(string id, [FromBody] CategoryNameRequest request) =>
        ExecuteAsync(async () => Ok(await categoryService.RenameAsync(id, request.Name)));

    /// <summary>Deletes only empty, non-default categories.</summary>
    /// <param name="id">Stable identifier.</param>
    /// <returns>No content after deletion.</returns>
    [HttpDelete("{id}")]
    [Authorize(Roles = "Admin")]
    [ProducesResponseType(StatusCodes.Status204NoContent)]
    [ProducesResponseType(typeof(ProblemDetails), StatusCodes.Status404NotFound)]
    [ProducesResponseType(typeof(ProblemDetails), StatusCodes.Status409Conflict)]
    public Task<IActionResult> DeleteCategory(string id) => ExecuteAsync(async () =>
    {
        await categoryService.DeleteAsync(id);
        return NoContent();
    });

    /// <summary>Maps validation, deletion guards and bounded storage conflicts to actionable errors.</summary>
    private async Task<IActionResult> ExecuteAsync(Func<Task<IActionResult>> action)
    {
        try
        {
            return await action();
        }
        catch (ArgumentException exception)
        {
            return Problem(title: "Invalid Category", detail: exception.Message, statusCode: 400);
        }
        catch (KeyNotFoundException exception)
        {
            return Problem(title: "Category Not Found", detail: exception.Message, statusCode: 404);
        }
        catch (InvalidOperationException exception)
        {
            return Problem(title: "Category Conflict", detail: exception.Message, statusCode: 409);
        }
        catch (RequestFailedException exception) when (exception.Status is 409 or 412)
        {
            return Problem(title: "Category Conflict", detail: "Categories changed concurrently. Reload and try again.", statusCode: 409);
        }
        catch (RequestFailedException exception) when (exception.Status == 403)
        {
            return Problem(title: "Access Denied", detail: "You do not have access. Please contact your administrator.", statusCode: 403);
        }
    }
}