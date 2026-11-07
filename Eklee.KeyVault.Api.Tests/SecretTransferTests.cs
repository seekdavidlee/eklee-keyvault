using System.Net;
using System.Security.Claims;
using System.Text.Encodings.Web;
using System.Text.Json;
using Azure;
using Azure.Security.KeyVault.Secrets;
using Eklee.KeyVault.Api.Controllers;
using Eklee.KeyVault.Api.Models;
using Eklee.KeyVault.Api.Services;
using Microsoft.AspNetCore.Authentication;
using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Mvc;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Logging.Abstractions;
using Microsoft.Extensions.Options;
using Xunit;

namespace Eklee.KeyVault.Api.Tests;

/// <summary>Exercises transfers with isolated storage and real endpoint authorization middleware.</summary>
public class SecretTransferTests
{
    private static readonly JsonSerializerOptions Json = new(JsonSerializerDefaults.Web);

    [Fact]
    public async Task GivenCategoryExport_WhenImporting_PreservesNamesValuesAndAllTagsInDestination()
    {
        var sourceStore = new CategoryServiceTests.MetadataStore();
        var sourceVault = new TransferVault();
        var sourceCategories = new CategoryService(sourceStore, sourceVault);
        var source = await sourceCategories.CreateAsync("Source");
        var other = await sourceCategories.CreateAsync("Other");
        foreach (var name in new[] { "no-tags", "many-tags", "excluded" })
        {
            await sourceCategories.AssociateSecretAsync(name, name == "excluded" ? other.Id : source.Id);
            await sourceVault.SetSecretWithTagsAsync(name, "value-" + name, name == "many-tags"
                ? new Dictionary<string, string> { ["category"] = "user-defined", ["Environment"] = "Prod", ["empty"] = "" } : []);
        }
        await sourceCategories.SetImportedDisplayNameAsync("many-tags", "Original display");

        var export = await new SecretTransferService(sourceVault, sourceStore, sourceCategories).ExportAsync(source.Id);
        Assert.Equal(2, export.Secrets.Count);
        Assert.DoesNotContain(export.Secrets, item => item.Name == "excluded");
        var destinationStore = new CategoryServiceTests.MetadataStore();
        var destinationVault = new TransferVault();
        var destinationCategories = new CategoryService(destinationStore, destinationVault);
        var destination = await destinationCategories.CreateAsync("New destination");
        var result = await new SecretTransferService(destinationVault, destinationStore, destinationCategories)
            .ImportAsync(destination.Id, JsonSerializer.SerializeToElement(export, Json));

        Assert.All(result.Results, item => Assert.Equal("imported", item.Status));
        Assert.All(destinationStore.Read().Items!, item => Assert.Equal(destination.Id, item.CategoryId));
        Assert.Equal("Original display", destinationStore.Read().Items!.Single(item => item.Id == "many-tags").DisplayName);
        foreach (var item in export.Secrets)
        {
            Assert.Equal(item.Value, destinationVault.Secrets[item.Name].Value);
            Assert.Equal(item.Tags.OrderBy(tag => tag.Key), destinationVault.Secrets[item.Name].Properties.Tags.OrderBy(tag => tag.Key));
        }
    }

    [Theory]
    [InlineData(1000)]
    [InlineData(1001)]
    public async Task GivenExistingLongDisplayName_WhenExporting_RemainsImportableWithoutTruncation(int length)
    {
        var sourceStore = new CategoryServiceTests.MetadataStore();
        var sourceVault = new TransferVault();
        var sourceCategories = new CategoryService(sourceStore, sourceVault);
        var source = await sourceCategories.CreateAsync("Source");
        await sourceCategories.AssociateSecretAsync("valid", source.Id);
        await sourceCategories.SetImportedDisplayNameAsync("valid", new string('x', length));
        await sourceVault.SetSecretWithTagsAsync("valid", "test-value", new Dictionary<string, string>());
        var export = await new SecretTransferService(sourceVault, sourceStore, sourceCategories).ExportAsync(source.Id);
        var destinationStore = new CategoryServiceTests.MetadataStore();
        var destinationVault = new TransferVault();
        var destinationCategories = new CategoryService(destinationStore, destinationVault);
        var destination = await destinationCategories.CreateAsync("Destination");
        var response = await new SecretTransferService(destinationVault, destinationStore, destinationCategories)
            .ImportAsync(destination.Id, JsonSerializer.SerializeToElement(export, Json));
        Assert.Equal("imported", Assert.Single(response.Results).Status);
        Assert.Equal(new string('x', length), Assert.Single(destinationStore.Read().Items!).DisplayName);
    }

    [Fact]
    public async Task GivenMixedDuplicates_WhenImporting_SkipsVaultWideAndCaseInsensitiveFileDuplicates()
    {
        var store = new CategoryServiceTests.MetadataStore();
        var vault = new TransferVault();
        var categories = new CategoryService(store, vault);
        var destination = await categories.CreateAsync("Destination");
        await vault.SetSecretWithTagsAsync("existing", "original", new Dictionary<string, string> { ["keep"] = "tag" });
        var result = await new SecretTransferService(vault, store, categories).ImportAsync(destination.Id,
            Document(Item("EXISTING"), Item("new"), Item("NEW")));

        Assert.Equal(new[] { "skipped", "imported", "skipped" }, result.Results.Select(item => item.Status));
        Assert.Equal("original", vault.Secrets["existing"].Value);
        Assert.Equal("tag", vault.Secrets["existing"].Properties.Tags["keep"]);
        Assert.Equal(2, vault.Writes);
    }

    [Theory]
    [InlineData("null")]
    [InlineData("{}")]
    [InlineData("{\"formatVersion\":2,\"secrets\":[]}")]
    [InlineData("{\"formatVersion\":1,\"secrets\":null}")]
    [InlineData("{\"formatVersion\":1,\"secrets\":[null]}")]
    [InlineData("{\"formatVersion\":1,\"secrets\":[{\"name\":\"valid\",\"value\":\"sensitive-marker\",\"tags\":{}},{\"name\":\"bad_name\",\"value\":\"secret\",\"tags\":{}}]}")]
    [InlineData("{\"formatVersion\":1,\"secrets\":[{\"name\":\"valid\",\"value\":null,\"tags\":{}}]}")]
    [InlineData("{\"formatVersion\":1,\"secrets\":[{\"name\":\"valid\",\"value\":\"sensitive-marker\",\"tags\":{\"key\":4}}]}")]
    [InlineData("{\"formatVersion\":1,\"secrets\":[{\"name\":\"valid\",\"value\":\"sensitive-marker\",\"value\":\"other\",\"tags\":{}}]}")]
    [InlineData("{\"formatVersion\":1,\"secrets\":[{\"name\":\"valid\",\"value\":\"sensitive-marker\",\"tags\":{\"key\":\"one\",\"key\":\"two\"}}]}")]
    public async Task GivenMalformedDocument_WhenImporting_RejectsBeforeAnyStorageAccess(string text)
    {
        var store = new CategoryServiceTests.MetadataStore();
        var vault = new TransferVault();
        var service = new SecretTransferService(vault, store, new CategoryService(store, vault));
        using var document = JsonDocument.Parse(text);
        var exception = await Assert.ThrowsAsync<ArgumentException>(() => service.ImportAsync("destination", document.RootElement));
        Assert.DoesNotContain("sensitive-marker", exception.Message);
        Assert.Equal(0, store.LeaseAttempts);
        Assert.Equal(0, store.SuccessfulWrites);
        Assert.Equal(0, vault.Writes);
    }

    [Theory]
    [InlineData(null)]
    [InlineData("")]
    [InlineData("missing")]
    public async Task GivenMissingDestination_WhenImporting_DoesNotWrite(string? destination)
    {
        var store = new CategoryServiceTests.MetadataStore();
        var vault = new TransferVault();
        var service = new SecretTransferService(vault, store, new CategoryService(store, vault));
        await Assert.ThrowsAnyAsync<Exception>(() => service.ImportAsync(destination, Document(Item("valid"))));
        Assert.Equal(0, store.LeaseAttempts);
        Assert.Equal(0, vault.Writes);
    }

    [Theory]
    [InlineData(403, "notAttempted")]
    [InlineData(500, "imported")]
    public async Task GivenStorageFailure_WhenImporting_ReportsPartialResultsWithoutValues(int status, string followingStatus)
    {
        var store = new CategoryServiceTests.MetadataStore();
        var vault = new TransferVault { FailureStatus = status };
        var categories = new CategoryService(store, vault);
        var destination = await categories.CreateAsync("Destination");
        var result = await new SecretTransferService(vault, store, categories).ImportAsync(destination.Id,
            Document(Item("good"), Item("failure"), Item("following")));
        Assert.Equal(new[] { "imported", "failed", followingStatus }, result.Results.Select(item => item.Status));
        Assert.Equal(status == 403, result.AccessDenied);
        Assert.DoesNotContain("sensitive-marker", JsonSerializer.Serialize(result));
        Assert.False(store.IsSecretLeased("failure"));
    }

    [Theory]
    [InlineData(500, false, "imported")]
    [InlineData(500, true, "imported")]
    [InlineData(403, false, "notAttempted")]
    [InlineData(403, true, "notAttempted")]
    public async Task GivenLeaseReleaseFailure_WhenImporting_ReportsExactlyOneOutcomeAndPreservesStopRules(int status, bool existing, string followingStatus)
    {
        var store = new CategoryServiceTests.MetadataStore
        {
            LeaseReleaseFailureStatus = status, LeaseReleaseFailureName = "release-failure"
        };
        var vault = new TransferVault();
        var categories = new CategoryService(store, vault);
        var destination = await categories.CreateAsync("Destination");
        if (existing) await vault.SetSecretWithTagsAsync("release-failure", "original", new Dictionary<string, string>());
        var response = await new SecretTransferService(vault, store, categories).ImportAsync(destination.Id,
            Document(Item("first"), Item("release-failure"), Item("following")));
        Assert.Equal(3, response.Results.Count);
        Assert.Equal(new[] { "imported", "failed", followingStatus }, response.Results.Select(item => item.Status));
        Assert.Equal(status == 403, response.AccessDenied);
        Assert.Single(response.Results, item => item.Name == "release-failure");
        Assert.Equal(existing ? "original" : "sensitive-marker", vault.Secrets["release-failure"].Value);
        Assert.True(store.IsSecretLeased("release-failure"));
        Assert.DoesNotContain("sensitive-marker", JsonSerializer.Serialize(response));
    }

    [Theory]
    [InlineData(403, 500)]
    [InlineData(500, 403)]
    [InlineData(403, 403)]
    public async Task GivenCombinedWriteAndCleanupFailures_WhenEitherDeniesAccess_StopsRemainingWritesAndReturns403(int writeStatus, int cleanupStatus)
    {
        var store = new CategoryServiceTests.MetadataStore
        {
            LeaseReleaseFailureStatus = cleanupStatus, LeaseReleaseFailureName = "failure"
        };
        var vault = new TransferVault { FailureStatus = writeStatus };
        var categories = new CategoryService(store, vault);
        var destination = await categories.CreateAsync("Destination");
        var controller = new SecretTransfersController(new SecretTransferService(vault, store, categories));
        var result = Assert.IsType<ObjectResult>(await controller.Import(destination.Id,
            Document(Item("first"), Item("failure"), Item("following"))));
        Assert.Equal(403, result.StatusCode);
        var response = Assert.IsType<SecretImportResponse>(result.Value);
        Assert.Equal(new[] { "imported", "failed", "notAttempted" }, response.Results.Select(item => item.Status));
        Assert.True(response.AccessDenied);
        Assert.Equal(1, vault.Writes);
        Assert.Equal(3, response.Results.Count);
        Assert.DoesNotContain("sensitive-marker", JsonSerializer.Serialize(response));
    }

    [Theory]
    [InlineData("value")]
    [InlineData("tags")]
    [InlineData("key")]
    [InlineData("tagValue")]
    [InlineData("count")]
    public async Task GivenExceededFormatLimit_WhenImporting_RejectsBeforeWrites(string limit)
    {
        var store = new CategoryServiceTests.MetadataStore();
        var vault = new TransferVault();
        var item = Item("valid");
        item = limit switch
        {
            "value" => item with { Value = new string('x', 25 * 1024 + 1) },
            "tags" => item with { Tags = Enumerable.Range(0, 16).ToDictionary(index => "key" + index, _ => "value") },
            "key" => item with { Tags = new Dictionary<string, string> { [new string('k', 513)] = "value" } },
            "tagValue" => item with { Tags = new Dictionary<string, string> { ["key"] = new string('v', 257) } },
            _ => item
        };
        var document = limit == "count" ? Document(Enumerable.Repeat(item, 1001).ToArray()) : Document(item);
        await Assert.ThrowsAsync<ArgumentException>(() => new SecretTransferService(vault, store, new CategoryService(store, vault))
            .ImportAsync("destination", document));
        Assert.Equal(0, vault.Writes);
        Assert.Equal(0, store.LeaseAttempts);
    }

    [Fact]
    public async Task GivenConcurrentSecretOperation_WhenImporting_DoesNotWriteAndReportsConflict()
    {
        var store = new CategoryServiceTests.MetadataStore();
        var vault = new TransferVault();
        var categories = new CategoryService(store, vault);
        var destination = await categories.CreateAsync("Destination");
        await using var operation = await store.AcquireSecretOperationAsync("valid");
        var result = await new SecretTransferService(vault, store, categories).ImportAsync(destination.Id, Document(Item("valid")));
        Assert.Equal("failed", Assert.Single(result.Results).Status);
        Assert.Equal(0, vault.Writes);
    }

    [Fact]
    public async Task GivenEndpointRoles_WhenTransferring_RejectsUnauthorizedRequestsAndMalformedJson()
    {
        var builder = WebApplication.CreateBuilder();
        builder.WebHost.UseUrls("http://127.0.0.1:0");
        builder.Logging.ClearProviders();
        builder.Services.AddAuthentication("Test").AddScheme<AuthenticationSchemeOptions, RoleHandler>("Test", _ => { });
        builder.Services.AddAuthorization();
        builder.Services.AddControllers().AddApplicationPart(typeof(SecretTransfersController).Assembly);
        var store = new CategoryServiceTests.MetadataStore();
        var vault = new TransferVault();
        var categories = new CategoryService(store, vault);
        var destination = await categories.CreateAsync("Destination");
        builder.Services.AddSingleton(new SecretTransferService(vault, store, categories));
        await using var app = builder.Build();
        app.UseAuthentication();
        app.UseAuthorization();
        app.MapControllers();
        await app.StartAsync();
        using var client = new HttpClient { BaseAddress = new Uri(app.Urls.Single()) };
        foreach (var role in new[] { "", "Unknown", "User", "Admin" })
        {
            client.DefaultRequestHeaders.Remove("Test-Role");
            if (role.Length > 0) client.DefaultRequestHeaders.Add("Test-Role", role);
            var expectedRead = role == "" ? HttpStatusCode.Unauthorized : role == "Unknown" ? HttpStatusCode.Forbidden : HttpStatusCode.OK;
            using var read = await client.GetAsync($"/api/secret-transfers/export?categoryId={destination.Id}");
            Assert.Equal(expectedRead, read.StatusCode);
            if (read.IsSuccessStatusCode) Assert.True(read.Headers.CacheControl!.NoStore);
            using var body = new StringContent("{\"formatVersion\":1,\"secrets\":[]}", System.Text.Encoding.UTF8, "application/json");
            using var write = await client.PostAsync($"/api/secret-transfers/import?categoryId={destination.Id}", body);
            Assert.Equal(role == "Admin" ? HttpStatusCode.OK : role == "" ? HttpStatusCode.Unauthorized : HttpStatusCode.Forbidden, write.StatusCode);
        }
        using var malformed = new StringContent("{\"sensitive-marker\":", System.Text.Encoding.UTF8, "application/json");
        using var rejected = await client.PostAsync($"/api/secret-transfers/import?categoryId={destination.Id}", malformed);
        Assert.Equal(HttpStatusCode.BadRequest, rejected.StatusCode);
        Assert.DoesNotContain("sensitive-marker", await rejected.Content.ReadAsStringAsync());
        using var oversized = new StringContent(new string(' ', SecretTransferService.MaximumFileBytes + 1), System.Text.Encoding.UTF8, "application/json");
        using var tooLarge = await client.PostAsync($"/api/secret-transfers/import?categoryId={destination.Id}", oversized);
        Assert.Equal(HttpStatusCode.RequestEntityTooLarge, tooLarge.StatusCode);
        Assert.Equal(0, vault.Writes);
        await app.StopAsync();
    }

    private static SecretExportItem Item(string name) => new() { Name = name, Value = "sensitive-marker", Tags = [] };
    private static JsonElement Document(params SecretExportItem[] items) =>
        JsonSerializer.SerializeToElement(new SecretExport { FormatVersion = 1, Secrets = [.. items] }, Json);

    private sealed class RoleHandler(IOptionsMonitor<AuthenticationSchemeOptions> options, ILoggerFactory logger, UrlEncoder encoder)
        : AuthenticationHandler<AuthenticationSchemeOptions>(options, logger, encoder)
    {
        protected override Task<AuthenticateResult> HandleAuthenticateAsync()
        {
            var role = Request.Headers["Test-Role"].ToString();
            return Task.FromResult(role.Length == 0 ? AuthenticateResult.NoResult() : AuthenticateResult.Success(
                new AuthenticationTicket(new ClaimsPrincipal(new ClaimsIdentity([new Claim(ClaimTypes.Role, role)], "Test")), "Test")));
        }
    }

    private sealed class TransferVault() : KeyVaultService(new Config(new ConfigurationBuilder().AddInMemoryCollection(
        new Dictionary<string, string?> { ["KeyVaultUri"] = "https://vault.example.test/", ["StorageUri"] = "https://storage.example.test/", ["StorageContainerName"] = "configs" }).Build()),
        new Azure.Identity.DefaultAzureCredential(), NullLogger<KeyVaultService>.Instance)
    {
        public Dictionary<string, KeyVaultSecret> Secrets { get; } = new(StringComparer.OrdinalIgnoreCase);
        public int Writes { get; private set; }
        public int? FailureStatus { get; init; }
        public override Task<bool> SecretExistsAsync(string name) => Task.FromResult(Secrets.ContainsKey(name));
        public override Task<IEnumerable<SecretItem>> GetSecretsAsync() => Task.FromResult<IEnumerable<SecretItem>>(
            Secrets.Keys.Select(name => new SecretItem { Id = $"https://vault.example.test/secrets/{name}", Enabled = true }).ToArray());
        public override Task<KeyVaultSecret> GetSecretWithTagsAsync(string name) => Task.FromResult(Secrets[name]);
        public override Task SetSecretWithTagsAsync(string name, string value, IReadOnlyDictionary<string, string> tags)
        {
            if (name == "failure" && FailureStatus is int status) throw new RequestFailedException(status, "sensitive-marker");
            var secret = new KeyVaultSecret(name, value);
            foreach (var tag in tags) secret.Properties.Tags.Add(tag.Key, tag.Value);
            Secrets[name] = secret;
            Writes++;
            return Task.CompletedTask;
        }
    }
}