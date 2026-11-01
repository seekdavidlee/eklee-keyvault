using System.Reflection;
using Azure;
using Eklee.KeyVault.Api.Controllers;
using Eklee.KeyVault.Api.Models;
using Eklee.KeyVault.Api.Services;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.Logging.Abstractions;
using Xunit;

namespace Eklee.KeyVault.Api.Tests;

/// <summary>Checks durable category operations and conflict retries using isolated storage doubles.</summary>
public class CategoryServiceTests
{
    [Fact]
    public async Task GivenInterruptedMigration_WhenRetrying_PreservesDefaultIdentityAndWritesOnlyOnce()
    {
        var store = new MetadataStore { ConflictsRemaining = 1 };
        var service = new CategoryService(store, new SecretInventory("legacy"));

        await service.InitializeAsync();
        var initial = store.Read();
        var defaultCategory = Assert.Single(initial.Categories);
        await service.RenameAsync(defaultCategory.Id, "General");
        var writes = store.SuccessfulWrites;
        await service.InitializeAsync();

        Assert.Equal(writes, store.SuccessfulWrites);
        Assert.Equal(defaultCategory.Id, Assert.Single(store.Read().Items!).CategoryId);
        Assert.Equal("General", Assert.Single(store.Read().Categories).Name);
        await Assert.ThrowsAsync<InvalidOperationException>(() => service.DeleteAsync(defaultCategory.Id));
    }

    [Fact]
    public async Task GivenConcurrentAssociation_WhenDeleting_ReloadsAndBlocksDeletion()
    {
        var store = new MetadataStore();
        var service = new CategoryService(store, new SecretInventory());
        var category = await service.CreateAsync("Business");
        store.OnConflict = state => state.Items = [new SecretItemMeta { Id = "other", CategoryId = category.Id }];
        store.ConflictsRemaining = 1;

        await Assert.ThrowsAsync<InvalidOperationException>(() => service.DeleteAsync(category.Id));

        Assert.Equal(category.Id, Assert.Single(store.Read().Categories).Id);
        Assert.Equal(category.Id, Assert.Single(store.Read().Items!).CategoryId);
    }

    [Fact]
    public async Task GivenNewSecret_WhenAssociating_RequiresValidCategoryAndPersistsIt()
    {
        var store = new MetadataStore();
        var service = new CategoryService(store, new SecretInventory());
        var category = await service.CreateAsync("Business");

        await Assert.ThrowsAsync<ArgumentException>(() => service.AssociateSecretAsync("new", null));
        await Assert.ThrowsAsync<KeyNotFoundException>(() => service.AssociateSecretAsync("new", "missing"));
        Assert.Empty(store.Read().Items ?? []);
        await service.AssociateSecretAsync("new", category.Id);

        Assert.Equal(category.Id, Assert.Single(store.Read().Items!).CategoryId);
        await Assert.ThrowsAsync<InvalidOperationException>(() => service.DeleteAsync(category.Id));
        await service.RemoveSecretAsync("new");
        await service.DeleteAsync(category.Id);
        Assert.Empty(store.Read().Categories);
    }

    [Fact]
    public async Task GivenExistingAssociation_WhenSettingSecret_CannotMoveAndDoesNotRewriteMetadata()
    {
        var store = new MetadataStore();
        var service = new CategoryService(store, new SecretInventory());
        var original = await service.CreateAsync("Business");
        var other = await service.CreateAsync("Personal");
        await service.AssociateSecretAsync("secret", original.Id);
        var writes = store.SuccessfulWrites;

        await service.AssociateSecretAsync("SECRET", null);
        await service.AssociateSecretAsync("secret", original.Id);
        await Assert.ThrowsAsync<InvalidOperationException>(() => service.AssociateSecretAsync("secret", other.Id));

        Assert.Equal(writes, store.SuccessfulWrites);
        Assert.Equal(original.Id, Assert.Single(store.Read().Items!).CategoryId);
    }

    [Fact]
    public async Task GivenPersistentConflict_WhenCreating_StopsAfterFiveAttemptsWithoutPartialWrites()
    {
        var store = new MetadataStore { ConflictsRemaining = 10 };
        var service = new CategoryService(store, new SecretInventory());

        await Assert.ThrowsAsync<RequestFailedException>(() => service.CreateAsync("Business"));

        Assert.Equal(5, store.Attempts);
        Assert.Empty(store.Read().Categories);
    }

    [Fact]
    public void GivenMetadataReplacement_WhenEditing_OnlyChangesDisplayNames()
    {
        var state = new SecretItemMetaList();
        state.InitializeCategories(["legacy"]);
        var original = BinaryData.FromObjectAsJson(state).ToString();
        var proposed = BinaryData.FromString(original).ToObjectFromJson<SecretItemMetaList>()!;
        proposed.Items![0].CategoryId = "other";
        Assert.Throws<ArgumentException>(() => state.UpdateDisplayNames(proposed));
        Assert.Equal(original, BinaryData.FromObjectAsJson(state).ToString());

        proposed.Items[0].CategoryId = null;
        proposed.Items[0].DisplayName = "Updated";
        state.UpdateDisplayNames(proposed);
        Assert.Equal("Updated", state.Items![0].DisplayName);
        Assert.Equal(state.Categories[0].Id, state.Items[0].CategoryId);

        proposed.Categories.Clear();
        proposed.Items.Clear();
        Assert.Throws<ArgumentException>(() => state.UpdateDisplayNames(proposed));
    }

    [Fact]
    public void GivenCategoryEndpoints_WhenInspectingAuthorization_ReadRequiresUserAndMutationsRequireAdmin()
    {
        Assert.Equal("Admin,User", typeof(CategoriesController).GetCustomAttribute<AuthorizeAttribute>()?.Roles);
        foreach (var name in new[] { "CreateCategory", "RenameCategory", "DeleteCategory" })
        {
            Assert.Equal("Admin", typeof(CategoriesController).GetMethod(name)!.GetCustomAttribute<AuthorizeAttribute>()?.Roles);
        }
    }

    [Fact]
    public async Task GivenInvalidCategory_WhenCallingEndpoint_ReturnsActionableProblemDetails()
    {
        var service = new CategoryService(new MetadataStore(), new SecretInventory());
        var controller = new CategoriesController(service);

        var result = await controller.CreateCategory(new CategoryNameRequest { Name = " " });

        var problem = Assert.IsType<ProblemDetails>(Assert.IsType<ObjectResult>(result).Value);
        Assert.Equal(400, problem.Status);
        Assert.Contains("1 and 30", problem.Detail);
    }

    [Fact]
    public async Task GivenCategoryFilter_WhenListing_ReturnsOnlyAssociatedSecretsAndRejectsMissingCategory()
    {
        var store = new MetadataStore();
        var inventory = new SecretInventory("budget", "shared");
        var service = new CategoryService(store, inventory);
        await service.InitializeAsync();
        var finance = await service.CreateAsync("Finance");
        await service.RemoveSecretAsync("budget");
        await service.AssociateSecretAsync("budget", finance.Id);
        var controller = new SecretsController(inventory, store, null!, NullLogger<SecretsController>.Instance, service);

        var filtered = Assert.IsType<OkObjectResult>(await controller.GetSecrets(finance.Id));
        var secret = Assert.Single(Assert.IsType<List<SecretItemView>>(filtered.Value));
        Assert.Equal("budget", secret.Name);
        Assert.Equal(finance.Id, secret.Meta.CategoryId);
        var missing = Assert.IsType<ProblemDetails>(Assert.IsType<ObjectResult>(await controller.GetSecrets("missing")).Value);
        Assert.Equal(404, missing.Status);
        var all = Assert.IsType<OkObjectResult>(await controller.GetSecrets());
        Assert.Equal(2, Assert.IsType<List<SecretItemView>>(all.Value).Count);
    }

    [Fact]
    public async Task GivenAbsentSecretAndCleanupConflict_WhenDeleting_ReturnsRetryGuidanceAndAllowsRetry()
    {
        var store = new MetadataStore();
        var inventory = new SecretInventory { DeleteFailureStatus = 404 };
        var service = new CategoryService(store, inventory);
        var category = await service.CreateAsync("Finance");
        await service.AssociateSecretAsync("absent", category.Id);
        store.ConflictsRemaining = 5;
        var controller = new SecretsController(inventory, store, null!, NullLogger<SecretsController>.Instance, service);

        var conflict = Assert.IsType<ProblemDetails>(Assert.IsType<ObjectResult>(await controller.DeleteSecret("absent")).Value);
        Assert.Equal(409, conflict.Status);
        Assert.Contains("retry deleting the same secret", conflict.Detail);
        Assert.Single(store.Read().Items!);

        var notFound = Assert.IsType<ProblemDetails>(Assert.IsType<ObjectResult>(await controller.DeleteSecret("absent")).Value);
        Assert.Equal(404, notFound.Status);
        Assert.Empty(store.Read().Items!);
        await service.DeleteAsync(category.Id);
    }

    [Fact]
    public async Task GivenMixedCaseMetadata_WhenMigratingAndFiltering_PreservesExistingAssociationAndDisplayName()
    {
        var state = new SecretItemMetaList
        {
            Categories = [new CategoryItem("finance", "Finance", false)],
            Items = [new SecretItemMeta { Id = "BUDGET", DisplayName = "Existing display", CategoryId = "finance" }]
        };
        var store = new MetadataStore(state);
        var inventory = new SecretInventory("budget");
        var service = new CategoryService(store, inventory);
        await service.InitializeAsync();
        var writes = store.SuccessfulWrites;
        await service.InitializeAsync();
        var controller = new SecretsController(inventory, store, null!, NullLogger<SecretsController>.Instance, service);

        var response = Assert.IsType<OkObjectResult>(await controller.GetSecrets("finance"));
        var secret = Assert.Single(Assert.IsType<List<SecretItemView>>(response.Value));
        Assert.Equal("BUDGET", secret.Meta.Id);
        Assert.Equal("Existing display", secret.Meta.DisplayName);
        Assert.Equal("finance", secret.Meta.CategoryId);
        Assert.Single(store.Read().Items!);
        Assert.Equal(writes, store.SuccessfulWrites);
    }

    [Fact]
    public async Task GivenInFlightCreation_WhenAnotherReplicaDeletes_CannotRemoveReservationOrDeleteCategory()
    {
        var store = new MetadataStore();
        var inventory = new SecretInventory
        {
            DeleteFailureStatus = 404,
            SetStarted = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously),
            CompleteSet = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously)
        };
        var firstService = new CategoryService(store, inventory);
        var secondService = new CategoryService(store, inventory);
        var category = await firstService.CreateAsync("Finance");
        var firstReplica = new SecretsController(inventory, store, null!, NullLogger<SecretsController>.Instance, firstService);
        var secondReplica = new SecretsController(inventory, store, null!, NullLogger<SecretsController>.Instance, secondService);
        var creation = firstReplica.SetSecret("pending", new SecretSetRequest { Value = "test-value", CategoryId = category.Id });
        await inventory.SetStarted.Task;

        try
        {
            var conflict = Assert.IsType<ProblemDetails>(Assert.IsType<ObjectResult>(await secondReplica.DeleteSecret("PENDING")).Value);
            Assert.Equal(409, conflict.Status);
            Assert.Equal(0, inventory.DeleteAttempts);
            Assert.Equal(category.Id, Assert.Single(store.Read().Items!).CategoryId);
            await Assert.ThrowsAsync<InvalidOperationException>(() => secondService.DeleteAsync(category.Id));
        }
        finally
        {
            inventory.CompleteSet.TrySetResult();
        }

        Assert.IsType<OkObjectResult>(await creation);
        Assert.Equal(category.Id, Assert.Single(store.Read().Items!).CategoryId);
        await Assert.ThrowsAsync<InvalidOperationException>(() => secondService.DeleteAsync(category.Id));
        inventory.DeleteFailureStatus = null;
        Assert.IsType<NoContentResult>(await secondReplica.DeleteSecret("PENDING"));
        Assert.Empty(store.Read().Items!);
    }

    private sealed class MetadataStore(SecretItemMetaList? initial = null) : BlobService(null!, null!)
    {
        private string serialized = BinaryData.FromObjectAsJson(initial ?? new SecretItemMetaList()).ToString();
        private int version;
        private readonly HashSet<string> operations = new(StringComparer.OrdinalIgnoreCase);

        public int Attempts { get; private set; }
        public int ConflictsRemaining { get; set; }
        public Action<SecretItemMetaList>? OnConflict { get; set; }
        public int SuccessfulWrites { get; private set; }

        public override Task<IAsyncDisposable> AcquireSecretOperationAsync(string name)
        {
            lock (operations)
            {
                if (!operations.Add(name)) throw new RequestFailedException(409, "Test operation already leased");
            }

            return Task.FromResult<IAsyncDisposable>(new OperationScope(() =>
            {
                lock (operations) operations.Remove(name);
            }));
        }

        private sealed class OperationScope(Action release) : IAsyncDisposable
        {
            public ValueTask DisposeAsync()
            {
                release();
                return ValueTask.CompletedTask;
            }
        }

        public SecretItemMetaList Read() => BinaryData.FromString(serialized).ToObjectFromJson<SecretItemMetaList>()!;

        public override Task<(SecretItemMetaList MetaList, string? ETag)> GetMetaAsync() =>
            Task.FromResult<(SecretItemMetaList, string?)>((Read(), version.ToString()));

        public override Task<string> UpdateMetaAsync(SecretItemMetaList state, string? ifMatchEtag)
        {
            Attempts++;
            if (ConflictsRemaining-- > 0)
            {
                var concurrent = Read();
                OnConflict?.Invoke(concurrent);
                serialized = BinaryData.FromObjectAsJson(concurrent).ToString();
                version++;
                throw new RequestFailedException(412, "Concurrent update");
            }

            Assert.Equal(version.ToString(), ifMatchEtag);
            serialized = BinaryData.FromObjectAsJson(state).ToString();
            SuccessfulWrites++;
            return Task.FromResult((++version).ToString());
        }
    }

    private sealed class SecretInventory(params string[] names) : KeyVaultService(
        new Config(new Microsoft.Extensions.Configuration.ConfigurationBuilder()
            .AddInMemoryCollection(new Dictionary<string, string?>
            {
                ["KeyVaultUri"] = "https://vault.example.test/",
                ["StorageUri"] = "https://storage.example.test/",
                ["StorageContainerName"] = "configs"
            })
            .Build()),
        new Azure.Identity.DefaultAzureCredential(),
        NullLogger<KeyVaultService>.Instance)
    {
        public int? DeleteFailureStatus { get; set; }
        public int DeleteAttempts { get; private set; }
        public TaskCompletionSource? SetStarted { get; init; }
        public TaskCompletionSource? CompleteSet { get; init; }

        public override Task<IEnumerable<SecretItem>> GetSecretsAsync() => Task.FromResult<IEnumerable<SecretItem>>(
            names.Select(name => new SecretItem { Id = $"https://vault.example.test/secrets/{name}", Enabled = true }));

        public override Task DeleteSecretAsync(string name)
        {
            DeleteAttempts++;
            return DeleteFailureStatus is int status
                ? Task.FromException(new RequestFailedException(status, "Test deletion failure")) : Task.CompletedTask;
        }

        public override async Task<string> SetSecretAsync(string name, string value)
        {
            SetStarted?.TrySetResult();
            if (CompleteSet is not null) await CompleteSet.Task;
            return name;
        }
    }
}