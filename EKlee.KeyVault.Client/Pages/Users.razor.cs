using Microsoft.AspNetCore.Components;
using Radzen;
using Radzen.Blazor;

namespace EKlee.KeyVault.Client.Pages;

public partial class Users : ComponentBase
{
    protected RadzenDataGrid<UserItem>? Grid;
    protected int ItemCount = 0;
    protected IEnumerable<UserItem>? UserItems;
    protected bool IsLoading;
    private readonly List<UserItem> inMemoryUserData = [];

    protected override void OnInitialized()
    {
        // simulate some data as an example.
        for (var i = 0; i < 120; i++)
        {
            inMemoryUserData.Add(new UserItem
            {
                Name = $"User {i}",
                Created = DateTime.Today.AddDays(-i),
            });
        }
    }

    protected async Task LoadData(LoadDataArgs args)
    {
        IsLoading = true;

        await Task.Delay(1000);

        if (args.Skip is not null && args.Top is not null)
        {
            UserItems = inMemoryUserData.Skip(args.Skip.Value).Take(args.Top.Value).ToList();
        }
        else
        {
            UserItems = inMemoryUserData;
        }

        ItemCount = inMemoryUserData.Count;
        IsLoading = false;
    }
}

public class UserItem
{
    public string? Name { get; set; }
    public DateTime? Created { get; set; }
}
