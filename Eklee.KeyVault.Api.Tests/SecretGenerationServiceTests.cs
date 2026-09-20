using System.Reflection;
using Eklee.KeyVault.Api.Controllers;
using Eklee.KeyVault.Api.Models;
using Eklee.KeyVault.Api.Services;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Mvc;
using Microsoft.Extensions.Logging.Abstractions;
using Xunit;

namespace Eklee.KeyVault.Api.Tests;

public class SecretGenerationServiceTests
{
    private readonly SecretGenerationService _sut = new();

    [Fact]
    public void GivenDefaultPolicy_WhenTryGenerate_ReturnsFifteenCharactersWithThreeSpecialCharacters()
    {
        var generated = _sut.TryGenerate(new SecretGenerationRequest(), out var response, out var validationError);

        var value = Assert.IsType<SecretGenerationResponse>(response).Value;
        Assert.True(generated);
        Assert.Null(validationError);
        Assert.Equal(15, value.Length);
        Assert.True(value.Count(SecretGenerationService.SpecialCharacters.Contains) >= 3);
        Assert.True(value.Count(char.IsLetter) >= 1);
        Assert.True(value.Count(char.IsDigit) >= 1);
    }

    [Fact]
    public void GivenCustomPolicy_WhenTryGenerate_MeetsEveryConfiguredMinimum()
    {
        var request = new SecretGenerationRequest
        {
            TotalLength = 24,
            MinimumAlphabeticCharacters = 7,
            MinimumNumericCharacters = 5,
            MinimumSpecialCharacters = 4
        };

        var generated = _sut.TryGenerate(request, out var response, out var validationError);

        var value = Assert.IsType<SecretGenerationResponse>(response).Value;
        Assert.True(generated);
        Assert.Null(validationError);
        Assert.Equal(request.TotalLength, value.Length);
        Assert.True(value.Count(char.IsLetter) >= request.MinimumAlphabeticCharacters);
        Assert.True(value.Count(char.IsDigit) >= request.MinimumNumericCharacters);
        Assert.True(value.Count(SecretGenerationService.SpecialCharacters.Contains) >= request.MinimumSpecialCharacters);
    }

    [Fact]
    public void GivenValidPolicy_WhenTryGenerate_UsesOnlyDocumentedCharacterSets()
    {
        var generated = _sut.TryGenerate(new SecretGenerationRequest(), out var response, out _);

        var allowedCharacters = SecretGenerationService.AlphabeticCharacters +
            SecretGenerationService.NumericCharacters +
            SecretGenerationService.SpecialCharacters;

        Assert.True(generated);
        Assert.All(Assert.IsType<SecretGenerationResponse>(response).Value, character => Assert.Contains(character, allowedCharacters));
    }

    [Theory]
    [InlineData(0, 0, 0, 0, "Total length")]
    [InlineData(15, -1, 0, 0, "between 0 and 128")]
    [InlineData(128, 129, 0, 0, "between 0 and 128")]
    [InlineData(4, 2, 2, 1, "cannot exceed")]
    public void GivenInvalidPolicy_WhenTryGenerate_ReturnsValidationError(
        int totalLength,
        int minimumAlphabeticCharacters,
        int minimumNumericCharacters,
        int minimumSpecialCharacters,
        string expectedError)
    {
        var request = new SecretGenerationRequest
        {
            TotalLength = totalLength,
            MinimumAlphabeticCharacters = minimumAlphabeticCharacters,
            MinimumNumericCharacters = minimumNumericCharacters,
            MinimumSpecialCharacters = minimumSpecialCharacters
        };

        var generated = _sut.TryGenerate(request, out var response, out var validationError);

        Assert.False(generated);
        Assert.Null(response);
        Assert.Contains(expectedError, validationError);
    }

    [Fact]
    public void GivenCategoryMinimumsExceedTotalLength_WhenGenerateSecret_ReturnsBadRequestProblemDetails()
    {
        var controller = new SecretsController(
            null!,
            null!,
            _sut,
            NullLogger<SecretsController>.Instance);

        var result = controller.GenerateSecret(new SecretGenerationRequest
        {
            TotalLength = 4,
            MinimumAlphabeticCharacters = 2,
            MinimumNumericCharacters = 2,
            MinimumSpecialCharacters = 1
        });

        var problemResult = Assert.IsType<ObjectResult>(result);
        var problemDetails = Assert.IsType<ProblemDetails>(problemResult.Value);
        Assert.Equal(StatusCodes.Status400BadRequest, problemResult.StatusCode);
        Assert.Equal("Invalid Generation Policy", problemDetails.Title);
        Assert.Contains("cannot exceed", problemDetails.Detail);
    }

    [Fact]
    public void GivenGenerateSecretEndpoint_WhenInspectingAuthorization_RequiresAdminRole()
    {
        var method = typeof(SecretsController).GetMethod(nameof(SecretsController.GenerateSecret));
        var authorize = Assert.Single(method!.GetCustomAttributes<AuthorizeAttribute>());

        Assert.Equal("Admin", authorize.Roles);
    }
}