using System.Diagnostics;
using Eklee.KeyVault.Api;
using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Http;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.FileProviders;
using Xunit;

namespace Eklee.KeyVault.Api.Tests;

/// <summary>Exercises static-file and SPA fallback middleware without a server or external services.</summary>
public sealed class FrontendCachePolicyTests : IDisposable
{
    private readonly string root = Path.Combine(Path.GetTempPath(), $"frontend-cache-{Guid.NewGuid():N}");
    private readonly PhysicalFileProvider files;
    private readonly ServiceProvider services;
    private readonly RequestDelegate pipeline;

    /// <summary>Builds an isolated pipeline with the same file options used in production.</summary>
    public FrontendCachePolicyTests()
    {
        Directory.CreateDirectory(Path.Combine(root, "assets"));
        File.WriteAllText(Path.Combine(root, "index.html"), "<script src='/assets/index-aldWdMlR.js'></script>");
        File.WriteAllText(Path.Combine(root, "config.js"), "window.config = {};");
        foreach (var name in new[] { "index-aldWdMlR.js", "index-aB1_-234.css", "logo.svg", "unversioned.js" })
        {
            File.WriteAllText(Path.Combine(root, "assets", name), "fixture");
        }
        File.WriteAllText(Path.Combine(root, "index-aldWdMlR.js"), "unversioned location");
        files = new PhysicalFileProvider(root);
        var environment = new TestEnvironment(files, root);
        services = new ServiceCollection()
            .AddLogging()
            .AddRouting()
            .AddSingleton(new DiagnosticListener("FrontendCachePolicyTests"))
            .AddSingleton<DiagnosticSource>(provider => provider.GetRequiredService<DiagnosticListener>())
            .AddSingleton<IWebHostEnvironment>(environment)
            .BuildServiceProvider();
        var app = new ApplicationBuilder(services);
        var options = Extensions.CreateFrontendStaticFileOptions();
        options.FileProvider = files;
        app.UseDefaultFiles(new DefaultFilesOptions { FileProvider = files });
        app.UseStaticFiles(options);
        app.UseRouting();
        app.UseEndpoints(endpoints =>
        {
            endpoints.MapGet("/api/test", context => context.Response.WriteAsync("api"));
            endpoints.MapGet("/api/protected", context =>
            {
                context.Response.StatusCode = StatusCodes.Status401Unauthorized;
                context.Response.Headers.WWWAuthenticate = "Bearer";
                return Task.CompletedTask;
            });
            endpoints.MapGet("/healthz", context => context.Response.WriteAsync("Healthy"));
            endpoints.MapFallbackToFile("index.html", options);
        });
        pipeline = app.Build();
    }

    /// <summary>Checks entry pages, runtime config, versioned assets, and unchanged responses.</summary>
    [Theory]
    [InlineData("/", 200, "no-cache")]
    [InlineData("/index.html", 200, "no-cache")]
    [InlineData("/categories/business", 200, "no-cache")]
    [InlineData("/config.js", 200, "no-store")]
    [InlineData("/assets/index-aldWdMlR.js", 200, "public, max-age=31536000, immutable")]
    [InlineData("/assets/index-aB1_-234.css", 200, "public, max-age=31536000, immutable")]
    [InlineData("/assets/missing-aldWdMlR.js", 404, "")]
    [InlineData("/assets/unversioned.js", 200, "")]
    [InlineData("/assets/logo.svg", 200, "")]
    [InlineData("/index-aldWdMlR.js", 200, "")]
    [InlineData("/api/test", 200, "")]
    [InlineData("/api/protected", 401, "")]
    [InlineData("/healthz", 200, "")]
    public async Task GivenFrontendRequest_WhenServed_AppliesOnlyItsCachePolicy(string path, int status, string cacheControl)
    {
        var context = await SendAsync(path);

        Assert.Equal(status, context.Response.StatusCode);
        Assert.Equal(cacheControl, context.Response.Headers.CacheControl.ToString());
        if (path == "/api/protected")
        {
            Assert.Equal("Bearer", context.Response.Headers.WWWAuthenticate.ToString());
        }
    }

    /// <summary>Checks that validators retain the policy on not-modified responses.</summary>
    [Theory]
    [InlineData("/", "no-cache")]
    [InlineData("/index.html", "no-cache")]
    [InlineData("/categories/business", "no-cache")]
    [InlineData("/config.js", "no-store")]
    [InlineData("/assets/index-aldWdMlR.js", "public, max-age=31536000, immutable")]
    public async Task GivenCachedFile_WhenRevalidated_RetainsCachePolicy(string path, string cacheControl)
    {
        var original = await SendAsync(path);
        Assert.NotEmpty(original.Response.Headers.ETag.ToString());
        var revalidated = await SendAsync(path, original.Response.Headers.ETag.ToString());

        Assert.Equal(StatusCodes.Status304NotModified, revalidated.Response.StatusCode);
        Assert.Equal(cacheControl, revalidated.Response.Headers.CacheControl.ToString());
    }

    /// <summary>Checks that revalidation of the same URL discovers replaced entry HTML.</summary>
    [Fact]
    public async Task GivenUpdatedEntryPage_WhenReloadedWithoutQueryString_DiscoversNewBundle()
    {
        var original = await SendAsync("/");
        var entryPath = Path.Combine(root, "index.html");
        File.WriteAllText(entryPath, "<script src='/assets/index-new12345.js'></script><title>New release</title>");
        File.SetLastWriteTimeUtc(entryPath, DateTime.UtcNow.AddMinutes(2));

        var refreshed = await SendAsync("/", original.Response.Headers.ETag.ToString());
        refreshed.Response.Body.Position = 0;
        using var reader = new StreamReader(refreshed.Response.Body);

        Assert.Equal(StatusCodes.Status200OK, refreshed.Response.StatusCode);
        Assert.Equal("no-cache", refreshed.Response.Headers.CacheControl.ToString());
        Assert.Contains("/assets/index-new12345.js", await reader.ReadToEndAsync());
        Assert.NotEqual(original.Response.Headers.ETag.ToString(), refreshed.Response.Headers.ETag.ToString());
    }

    /// <summary>Creates an HTTP request context without binding a network port.</summary>
    private async Task<DefaultHttpContext> SendAsync(string path, string? etag = null)
    {
        var context = new DefaultHttpContext { RequestServices = services };
        context.Request.Method = HttpMethods.Get;
        context.Request.Path = path;
        context.Response.Body = new MemoryStream();
        if (etag is not null)
        {
            context.Request.Headers.IfNoneMatch = etag;
        }
        await pipeline(context);
        return context;
    }

    /// <summary>Releases providers before removing the temporary fixtures.</summary>
    public void Dispose()
    {
        services.Dispose();
        files.Dispose();
        Directory.Delete(root, true);
    }

    private sealed class TestEnvironment(IFileProvider provider, string path) : IWebHostEnvironment
    {
        public string ApplicationName { get; set; } = typeof(FrontendCachePolicyTests).Assembly.GetName().Name!;
        public string EnvironmentName { get; set; } = "Production";
        public string ContentRootPath { get; set; } = path;
        public IFileProvider ContentRootFileProvider { get; set; } = provider;
        public string WebRootPath { get; set; } = path;
        public IFileProvider WebRootFileProvider { get; set; } = provider;
    }
}