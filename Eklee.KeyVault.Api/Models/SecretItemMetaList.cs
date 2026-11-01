namespace Eklee.KeyVault.Api.Models;

/// <summary>
/// Collection of user-defined display metadata for Key Vault secrets, stored in blob storage.
/// Provides lookup by secret identifier with automatic creation of missing entries.
/// </summary>
public class SecretItemMetaList
{
    public List<SecretItemMeta>? Items { get; set; }

    /// <summary>Gets or sets shared categories in the same concurrency-protected document as associations.</summary>
    public List<CategoryItem> Categories { get; set; } = [];

    /// <summary>Creates the default category and fills only missing secret associations.</summary>
    /// <param name="secretNames">Names present in Key Vault, including secrets without metadata.</param>
    /// <returns>Whether the document needs to be persisted.</returns>
    public bool InitializeCategories(IEnumerable<string> secretNames)
    {
        var changed = false;
        var defaultCategory = Categories.SingleOrDefault(category => category.IsDefault);
        if (defaultCategory is null)
        {
            defaultCategory = Categories.SingleOrDefault(category =>
                string.Equals(category.Name, "Default", StringComparison.OrdinalIgnoreCase));
            if (defaultCategory is null)
            {
                defaultCategory = new CategoryItem(Guid.NewGuid().ToString("N"), "Default", true);
                Categories.Add(defaultCategory);
            }
            else
            {
                Categories[Categories.IndexOf(defaultCategory)] = defaultCategory with { IsDefault = true };
            }

            changed = true;
        }

        var knownNames = (Items ?? []).Select(item => item.Id).ToHashSet(StringComparer.OrdinalIgnoreCase);
        foreach (var name in secretNames)
        {
            if (knownNames.Add(name))
            {
                (Items ??= []).Add(new SecretItemMeta { Id = name, DisplayName = name });
                changed = true;
            }
        }

        foreach (var item in Items ?? [])
        {
            if (string.IsNullOrWhiteSpace(item.CategoryId))
            {
                item.CategoryId = defaultCategory.Id;
                changed = true;
            }
        }

        return changed;
    }

    /// <summary>Creates a category after validating its shared name.</summary>
    /// <param name="name">Requested display name.</param>
    /// <returns>The new category.</returns>
    public CategoryItem CreateCategory(string? name)
    {
        var validName = ValidateCategoryName(name, null);
        var category = new CategoryItem(Guid.NewGuid().ToString("N"), validName, false);
        Categories.Add(category);
        return category;
    }

    /// <summary>Renames a category without changing its default role or associations.</summary>
    /// <param name="id">Stable identifier.</param>
    /// <param name="name">Requested display name.</param>
    /// <returns>The renamed category.</returns>
    public CategoryItem RenameCategory(string id, string? name)
    {
        var category = GetCategory(id);
        var renamed = category with { Name = ValidateCategoryName(name, id) };
        Categories[Categories.IndexOf(category)] = renamed;
        return renamed;
    }

    /// <summary>Deletes only an empty, non-default category; never mutates secret metadata.</summary>
    /// <param name="id">Stable identifier.</param>
    public void DeleteCategory(string id)
    {
        var category = GetCategory(id);
        if (category.IsDefault)
        {
            throw new InvalidOperationException("The default category cannot be deleted, even after renaming it.");
        }

        if ((Items ?? []).Any(item => item.CategoryId == id))
        {
            throw new InvalidOperationException("This category contains secrets and cannot be deleted. Delete its secrets first.");
        }

        Categories.Remove(category);
    }

    /// <summary>Finds a category or rejects an invalid association.</summary>
    /// <param name="id">Stable identifier.</param>
    /// <returns>The matching category.</returns>
    public CategoryItem GetCategory(string id)
    {
        return Categories.SingleOrDefault(category => category.Id == id)
            ?? throw new KeyNotFoundException("The selected category no longer exists. Choose another category.");
    }

    /// <summary>Applies display-name edits without accepting category, association or inventory changes.</summary>
    /// <param name="incoming">Client metadata based on the current ETag.</param>
    public void UpdateDisplayNames(SecretItemMetaList incoming)
    {
        var currentItems = Items ?? [];
        var incomingItems = incoming.Items ?? [];
        if (incoming.Categories is null ||
            (incoming.Categories.Count > 0 && !incoming.Categories.SequenceEqual(Categories)) ||
            incomingItems.Count != currentItems.Count ||
            incomingItems.Any(item => string.IsNullOrEmpty(item.Id)) ||
            incomingItems.Select(item => item.Id).Distinct(StringComparer.OrdinalIgnoreCase).Count() != incomingItems.Count)
        {
            throw new ArgumentException("Only display names may be edited here. Reload metadata; use category and secret endpoints for other changes.");
        }

        var incomingById = incomingItems.ToDictionary(item => item.Id!, StringComparer.OrdinalIgnoreCase);
        foreach (var current in currentItems)
        {
            if (current.Id is null || !incomingById.TryGetValue(current.Id, out var proposed) ||
                (proposed.CategoryId is not null && proposed.CategoryId != current.CategoryId))
            {
                throw new ArgumentException("Secret categories and associations cannot be changed through display metadata. Reload and try again.");
            }
        }

        foreach (var current in currentItems)
        {
            current.DisplayName = incomingById[current.Id!].DisplayName;
        }
    }

    /// <summary>Validates trimmed names while permitting a category's own case-only rename.</summary>
    private string ValidateCategoryName(string? name, string? excludedId)
    {
        var trimmed = name?.Trim();
        if (string.IsNullOrEmpty(trimmed) || trimmed.Length > 30)
        {
            throw new ArgumentException("Category name must contain between 1 and 30 characters.", nameof(name));
        }

        if (Categories.Any(category => category.Id != excludedId &&
            string.Equals(category.Name, trimmed, StringComparison.OrdinalIgnoreCase)))
        {
            throw new InvalidOperationException("A category with this name already exists. Choose a different name.");
        }

        return trimmed;
    }

    /// <summary>
    /// Finds metadata by secret identifier, creating a new entry with the default display name if not found.
    /// </summary>
    /// <param name="id">The secret identifier (last segment of the Key Vault URL).</param>
    /// <param name="defaultDisplayName">The fallback display name if no metadata exists.</param>
    /// <returns>The existing or newly created <see cref="SecretItemMeta"/>.</returns>
    public SecretItemMeta GetById(string id, string defaultDisplayName)
    {
        if (Items is null)
        {
            Items = [];
            var firstItem = new SecretItemMeta { Id = id, DisplayName = defaultDisplayName };
            Items.Add(firstItem);
            return firstItem;
        }

        var item = Items.SingleOrDefault(entry => string.Equals(entry.Id, id, StringComparison.OrdinalIgnoreCase));
        if (item is null)
        {
            item = new SecretItemMeta { Id = id, DisplayName = defaultDisplayName };
            Items.Add(item);
        }

        return item;
    }
}
