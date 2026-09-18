using System.Net;
using System.Security.Claims;
using Eklee.KeyVault.Api.Services;
using Xunit;

namespace Eklee.KeyVault.Api.Tests;

public class MiseTokenValidatorTests
{
    private readonly StubHttpMessageHandler _httpHandler;
    private readonly MiseTokenValidator _sut;

    public MiseTokenValidatorTests()
    {
        _httpHandler = new StubHttpMessageHandler();
        var httpClient = new HttpClient(_httpHandler)
        {
            BaseAddress = new Uri("http://localhost:5000/")
        };
        _sut = new MiseTokenValidator(httpClient);
    }

    [Fact]
    public async Task GivenMalformedSidecarResponse_WhenValidateAsync_ReturnsNull()
    {
        _httpHandler.ResponseFactory = _ => CreateJsonResponse("{not-json");

        var principal = await _sut.ValidateAsync("Bearer token", CancellationToken.None);

        Assert.Null(principal);
    }

    [Fact]
    public async Task GivenMissingAuthorizationHeader_WhenValidateAsync_ReturnsNullWithoutCallingSidecar()
    {
        var principal = await _sut.ValidateAsync(null, CancellationToken.None);

        Assert.Null(principal);
        Assert.Equal(0, _httpHandler.RequestCount);
    }

    [Fact]
    public async Task GivenMissingObjectIdClaim_WhenValidateAsync_ReturnsNull()
    {
        _httpHandler.ResponseFactory = _ => CreateJsonResponse("""
            { "claims": { "roles": ["Admin"] } }
            """);

        var principal = await _sut.ValidateAsync("Bearer token", CancellationToken.None);

        Assert.Null(principal);
    }

    [Fact]
    public async Task GivenRejectedSidecarResponse_WhenValidateAsync_ReturnsNull()
    {
        _httpHandler.ResponseFactory = _ => new HttpResponseMessage(HttpStatusCode.Unauthorized);

        var principal = await _sut.ValidateAsync("Bearer token", CancellationToken.None);

        Assert.Null(principal);
    }

    [Fact]
    public async Task GivenSidecarResponseBodyReadFailure_WhenValidateAsync_ReturnsNull()
    {
        _httpHandler.ResponseFactory = _ => new HttpResponseMessage(HttpStatusCode.OK)
        {
            Content = new ThrowingHttpContent()
        };

        var principal = await _sut.ValidateAsync("Bearer token", CancellationToken.None);

        Assert.Null(principal);
    }

    [Fact]
    public async Task GivenUnavailableSidecar_WhenValidateAsync_ReturnsNull()
    {
        _httpHandler.ExceptionToThrow = new HttpRequestException("Sidecar unavailable.");

        var principal = await _sut.ValidateAsync("Bearer token", CancellationToken.None);

        Assert.Null(principal);
    }

    [Fact]
    public async Task GivenValidClaims_WhenValidateAsync_ReturnsPrincipalWithMappedRoles()
    {
        _httpHandler.ResponseFactory = _ => CreateJsonResponse("""
            {
              "claims": {
                "oid": "user-object-id",
                "roles": ["Admin", "User"],
                "tid": "tenant-id"
              }
            }
            """);

        var principal = await _sut.ValidateAsync("Bearer token", CancellationToken.None);

        Assert.NotNull(principal);
        Assert.Equal("user-object-id", principal.FindFirst("oid")?.Value);
        Assert.Equal("tenant-id", principal.FindFirst("tid")?.Value);
        Assert.True(principal.IsInRole("Admin"));
        Assert.True(principal.IsInRole("User"));
    }

    [Fact]
    public async Task GivenValidHeader_WhenValidateAsync_ForwardsOriginalAuthorizationHeader()
    {
        _httpHandler.ResponseFactory = _ => CreateJsonResponse("""
            { "claims": { "oid": "user-object-id" } }
            """);

        await _sut.ValidateAsync("Bearer original-token", CancellationToken.None);

        Assert.Equal("Bearer original-token", _httpHandler.AuthorizationHeader);
    }

    private static HttpResponseMessage CreateJsonResponse(string content) => new(HttpStatusCode.OK)
    {
        Content = new StringContent(content)
    };

    private sealed class StubHttpMessageHandler : HttpMessageHandler
    {
        public string? AuthorizationHeader { get; private set; }
        public Exception? ExceptionToThrow { get; set; }
        public int RequestCount { get; private set; }
        public Func<HttpRequestMessage, HttpResponseMessage>? ResponseFactory { get; set; }

        protected override Task<HttpResponseMessage> SendAsync(
            HttpRequestMessage request,
            CancellationToken cancellationToken)
        {
            RequestCount++;
            AuthorizationHeader = request.Headers.Authorization?.ToString();

            if (ExceptionToThrow is not null)
            {
                throw ExceptionToThrow;
            }

            return Task.FromResult(ResponseFactory?.Invoke(request) ?? new HttpResponseMessage(HttpStatusCode.OK));
        }
    }

    private sealed class ThrowingHttpContent : HttpContent
    {
        protected override Task SerializeToStreamAsync(Stream stream, TransportContext? context) =>
            Task.FromException(new IOException("Response body read failed."));

        protected override bool TryComputeLength(out long length)
        {
            length = 0;
            return false;
        }
    }
}
