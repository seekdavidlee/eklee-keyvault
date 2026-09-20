using System.Security.Cryptography;
using Eklee.KeyVault.Api.Models;

namespace Eklee.KeyVault.Api.Services;

/// <summary>
/// Generates policy-compliant secret candidates with cryptographically secure randomness.
/// </summary>
public class SecretGenerationService
{
    /// <summary>Gets the permitted alphabetic characters.</summary>
    public const string AlphabeticCharacters = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz";

    /// <summary>Gets the permitted numeric characters.</summary>
    public const string NumericCharacters = "0123456789";

    /// <summary>Gets the permitted special characters.</summary>
    public const string SpecialCharacters = "!@#$%^&*_-+=";

    private const string AllCharacters = AlphabeticCharacters + NumericCharacters + SpecialCharacters;

    /// <summary>
    /// Attempts to generate a secret candidate that satisfies the supplied policy.
    /// </summary>
    /// <param name="request">The requested generation policy.</param>
    /// <param name="response">The generated candidate when the policy is valid.</param>
    /// <param name="validationError">The validation message when the policy is invalid.</param>
    /// <returns><see langword="true"/> when a candidate was generated; otherwise, <see langword="false"/>.</returns>
    public bool TryGenerate(
        SecretGenerationRequest request,
        out SecretGenerationResponse? response,
        out string? validationError)
    {
        validationError = GetValidationError(request);
        if (validationError is not null)
        {
            response = null;
            return false;
        }

        Span<char> characters = stackalloc char[request.TotalLength];
        var position = 0;

        position = AddRandomCharacters(characters, position, request.MinimumAlphabeticCharacters, AlphabeticCharacters);
        position = AddRandomCharacters(characters, position, request.MinimumNumericCharacters, NumericCharacters);
        position = AddRandomCharacters(characters, position, request.MinimumSpecialCharacters, SpecialCharacters);
        AddRandomCharacters(characters, position, request.TotalLength - position, AllCharacters);
        Shuffle(characters);

        response = new SecretGenerationResponse { Value = new string(characters) };
        return true;
    }

    private static string? GetValidationError(SecretGenerationRequest request)
    {
        if (request.TotalLength is < 1 or > 128)
        {
            return "Total length must be between 1 and 128 characters.";
        }

        if (request.MinimumAlphabeticCharacters is < 0 or > 128 ||
            request.MinimumNumericCharacters is < 0 or > 128 ||
            request.MinimumSpecialCharacters is < 0 or > 128)
        {
            return "Character category minimums must be between 0 and 128.";
        }

        var minimumCharacters = request.MinimumAlphabeticCharacters +
            request.MinimumNumericCharacters +
            request.MinimumSpecialCharacters;

        return minimumCharacters > request.TotalLength
            ? "The sum of character category minimums cannot exceed the total length."
            : null;
    }

    private static int AddRandomCharacters(Span<char> characters, int position, int count, string characterSet)
    {
        for (var index = 0; index < count; index++)
        {
            characters[position++] = characterSet[RandomNumberGenerator.GetInt32(characterSet.Length)];
        }

        return position;
    }

    private static void Shuffle(Span<char> characters)
    {
        for (var index = characters.Length - 1; index > 0; index--)
        {
            var swapIndex = RandomNumberGenerator.GetInt32(index + 1);
            (characters[index], characters[swapIndex]) = (characters[swapIndex], characters[index]);
        }
    }
}