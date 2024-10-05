using EKlee.KeyVault.Client.Services;
using Microsoft.AspNetCore.Components;
using Microsoft.AspNetCore.Components.WebAssembly.Authentication;

namespace EKlee.KeyVault.Client.Pages;

public partial class Index : ComponentBase
{
    protected DataItem[]? Items { get; private set; }

    public string? SomeText { get; set; }

    [Inject] private IAccessTokenProvider AccessTokenProvider { get; set; } = default!;

    [Inject] private BlobService BlobService { get; set; } = default!;

    [Inject] private KeyVaultService KeyVaultService { get; set; } = default!;

    protected override async Task OnInitializedAsync()
    {
        var items = new List<DataItem>();
        foreach (string item in await BlobService.ListAsync(AccessTokenProvider))
        {
            items.Add(new DataItem
            {
                Display = item,
                Value = 10
            });
        }

        Items = items.ToArray();

        var s = await KeyVaultService.GetSecrets(AccessTokenProvider);

        SomeText = s.Any() ? s.First() : "none";

        //Items =
        //[
        //    new DataItem
        //    {
        //        Display = "Q1",
        //        Value = 100
        //    },
        //    new DataItem
        //    {
        //        Display = "Q2",
        //        Value = 110
        //    },
        //    new DataItem
        //    {
        //        Display = "Q3",
        //        Value = 200
        //    },
        //    new DataItem
        //    {
        //        Display = "Q4",
        //        Value = 80
        //    },
        //];
    }
}

public class DataItem
{
    public string? Display { get; set; }
    public double Value { get; set; }
}
