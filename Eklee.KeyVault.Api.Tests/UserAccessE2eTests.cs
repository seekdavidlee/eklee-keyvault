using System.Security.Claims;
using Azure.Core;
using Eklee.KeyVault.Api.Controllers;
using Eklee.KeyVault.Api.Models;
using Eklee.KeyVault.Api.Services;
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Mvc;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.Logging.Abstractions;
using Xunit;

namespace Eklee.KeyVault.Api.Tests;

public class UserAccessE2eTests
{
    [Fact]
    public async Task GivenE2eApplicationRole_WhenTransformAsync_AddsAdminRoleWithoutStorageAccess()
    {
        var credential = new CountingTokenCredential();
        var sut = new UserAccessClaimsTransformation(CreateUserAccessService(credential), NullLogger<UserAccessClaimsTransformation>.Instance);
        var principal = CreateE2ePrincipal();

        var transformed = await sut.TransformAsync(principal);

        Assert.True(transformed.IsInRole(UserRole.Admin.ToString()));
        Assert.Equal(0, credential.RequestCount);
    }

    [Fact]
    public async Task GivenE2eApplicationRole_WhenGetMe_ReturnsEphemeralAdminWithoutStorageAccess()
    {
        var credential = new CountingTokenCredential();
        var sut = new UserAccessController(CreateUserAccessService(credential), NullLogger<UserAccessController>.Instance)
        {
            ControllerContext = new ControllerContext
            {
                HttpContext = new DefaultHttpContext
                {
                    User = CreateE2ePrincipal()
                }
            }
        };

        var result = await sut.GetMe();

        var response = Assert.IsType<OkObjectResult>(result);
        var user = Assert.IsType<UserAccess>(response.Value);
        Assert.Equal(UserRole.Admin, user.Role);
        Assert.Equal(0, credential.RequestCount);
    }

    private static ClaimsPrincipal CreateE2ePrincipal() => new(
        new ClaimsIdentity([new Claim("roles", "E2E.Tester")], "Test"));

    private static UserAccessService CreateUserAccessService(TokenCredential credential)
    {
        var configuration = new ConfigurationBuilder()
            .AddInMemoryCollection(new Dictionary<string, string?>
            {
                ["StorageUri"] = "https://storage.example.test/",
                ["StorageContainerName"] = "configs",
                ["KeyVaultUri"] = "https://keyvault.example.test/"
            })
            .Build();

        return new UserAccessService(new Config(configuration), credential);
    }

    private sealed class CountingTokenCredential : TokenCredential
    {
        public int RequestCount { get; private set; }

        public override AccessToken GetToken(TokenRequestContext requestContext, CancellationToken cancellationToken)
        {
            RequestCount++;
            throw new InvalidOperationException("Storage access is not expected for the E2E identity.");
        }

        public override ValueTask<AccessToken> GetTokenAsync(TokenRequestContext requestContext, CancellationToken cancellationToken)
        {
            RequestCount++;
            throw new InvalidOperationException("Storage access is not expected for the E2E identity.");
        }
    }
}