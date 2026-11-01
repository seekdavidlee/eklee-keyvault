using Eklee.KeyVault.Api.Models;
using Xunit;

namespace Eklee.KeyVault.Api.Tests;

/// <summary>Checks category rules and legacy migration without contacting Azure.</summary>
public class CategoryMetadataTests
{
    [Theory]
    [InlineData(null)]
    [InlineData("")]
    [InlineData("   ")]
    [InlineData("1234567890123456789012345678901")]
    public void GivenInvalidName_WhenCreatingOrRenaming_RejectsName(string? name)
    {
        var metadata = new SecretItemMetaList();
        var category = metadata.CreateCategory("Business");

        Assert.Throws<ArgumentException>(() => metadata.CreateCategory(name));
        Assert.Throws<ArgumentException>(() => metadata.RenameCategory(category.Id, name));
        Assert.Equal(category, Assert.Single(metadata.Categories));
    }

    [Fact]
    public void GivenBoundaryName_WhenCreating_AcceptsThirtyCharacters()
    {
        var metadata = new SecretItemMetaList();
        Assert.Equal(30, metadata.CreateCategory(new string('a', 30)).Name.Length);
    }

    [Fact]
    public void GivenSharedNames_WhenCreatingOrRenaming_RejectsDuplicatesButAllowsOwnCaseChange()
    {
        var metadata = new SecretItemMetaList();
        var category = metadata.CreateCategory("Business");
        var other = metadata.CreateCategory("Personal");

        Assert.Throws<InvalidOperationException>(() => metadata.CreateCategory(" business "));
        Assert.Throws<InvalidOperationException>(() => metadata.RenameCategory(other.Id, "BUSINESS"));
        Assert.Equal("BUSINESS", metadata.RenameCategory(category.Id, "BUSINESS").Name);
    }

    [Fact]
    public void GivenLegacyAndCategorizedSecrets_WhenStartingTwice_PreservesMetadataAndDefaultIdentity()
    {
        var metadata = new SecretItemMetaList();
        var business = metadata.CreateCategory("Business");
        var legacy = new SecretItemMeta { Id = "legacy", DisplayName = "Legacy display" };
        var existing = new SecretItemMeta { Id = "existing", DisplayName = "Existing display", CategoryId = business.Id };
        metadata.Items = [legacy, existing];

        Assert.True(metadata.InitializeCategories(["legacy", "existing", "missing"]));
        var defaultCategory = Assert.Single(metadata.Categories, category => category.IsDefault);
        metadata.RenameCategory(defaultCategory.Id, "General");
        Assert.False(metadata.InitializeCategories(["legacy", "existing", "missing"]));

        Assert.Equal(defaultCategory.Id, legacy.CategoryId);
        Assert.Equal("Legacy display", legacy.DisplayName);
        Assert.Equal(business.Id, existing.CategoryId);
        Assert.Equal("Existing display", existing.DisplayName);
        Assert.Equal(defaultCategory.Id, metadata.GetById("missing", "unused").CategoryId);
        Assert.Equal("General", Assert.Single(metadata.Categories, category => category.IsDefault).Name);
        Assert.DoesNotContain(metadata.Categories, category => category.Name == "Default");
        Assert.Throws<InvalidOperationException>(() => metadata.DeleteCategory(defaultCategory.Id));
    }

    [Fact]
    public void GivenCategories_WhenDeleting_OnlyRemovesEmptyNonDefaultCategory()
    {
        var metadata = new SecretItemMetaList();
        var occupied = metadata.CreateCategory("Business");
        var empty = metadata.CreateCategory("Personal");
        var secret = new SecretItemMeta { Id = "secret", DisplayName = "Display", CategoryId = occupied.Id };
        metadata.Items = [secret];

        Assert.Throws<InvalidOperationException>(() => metadata.DeleteCategory(occupied.Id));
        metadata.DeleteCategory(empty.Id);

        Assert.Equal(occupied, Assert.Single(metadata.Categories));
        Assert.Same(secret, Assert.Single(metadata.Items));
        Assert.Equal(occupied.Id, secret.CategoryId);
        Assert.Throws<KeyNotFoundException>(() => metadata.GetCategory(empty.Id));
    }
}