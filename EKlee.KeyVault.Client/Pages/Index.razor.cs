using EKlee.KeyVault.Client.Models;
using EKlee.KeyVault.Client.Services;
using Microsoft.AspNetCore.Components;
using Microsoft.AspNetCore.Components.WebAssembly.Authentication;
using Microsoft.JSInterop;
using Radzen.Blazor;

namespace EKlee.KeyVault.Client.Pages;

public partial class Index : ComponentBase
{
    [Inject] private IAccessTokenProvider AccessTokenProvider { get; set; } = default!;

    [Inject] private KeyVaultService KeyVaultService { get; set; } = default!;

    [Inject] private IJSRuntime JS { get; set; } = default!;

    [Inject] private ILogger<Index> Logger { get; set; } = default!;

    private RadzenDataGrid<SecretItemView>? dataGridRef;
    private List<SecretItemView>? cachedSecretItems;
    private readonly List<SecretItemView> dataGridSecretItems = [];
    private string? errorMessage;
    private string? successMessage;
    private string? searchText;
    private bool loadingData;

    protected override async Task OnInitializedAsync()
    {
        loadingData = true;
        successMessage = null;
        errorMessage = null;
        try
        {
            cachedSecretItems = (await KeyVaultService.GetSecretsAsync(AccessTokenProvider)).Select(x => new SecretItemView(x)).ToList();
            dataGridSecretItems.AddRange(cachedSecretItems);
            await dataGridRef!.Reload();
        }
        catch (Exception ex)
        {
            errorMessage = ex.Message;
        }
        loadingData = false;
    }

    private async void CopyToClipboard(SecretItemView secretItemView)
    {
        successMessage = null;
        errorMessage = null;

        try
        {
            if (secretItemView.Value == SecretItemView.PlaceHolderValue)
            {
                await UpdateSecretValueAsync(secretItemView);
            }

            Logger.LogInformation("invoking clipboardCopy.copyText");
            await JS.InvokeVoidAsync("clipboardCopy.copyText", secretItemView.Value);

            Logger.LogInformation("clipboardCopy.copyText invoked");
            successMessage = $"Copied secret for {secretItemView.Name} to clipboard";
            StateHasChanged();
        }
        catch (Exception ex)
        {
            errorMessage = ex.Message;
        }
    }

    private async Task UpdateSecretValueAsync(SecretItemView secretItemView)
    {
        string? value = await KeyVaultService.GetSecretAsync(AccessTokenProvider, secretItemView.Id!);
        if (value is null)
        {
            errorMessage = "Unable to get secret!";
        }
        else
        {
            secretItemView.Value = value;
        }
    }

    private async void ShowSecret(SecretItemView secretItemView)
    {
        successMessage = null;
        errorMessage = null;
        try
        {
            await UpdateSecretValueAsync(secretItemView);
            StateHasChanged();
        }
        catch (Exception ex)
        {
            errorMessage = ex.Message;
        }
    }

    private async Task HandleOnInput(ChangeEventArgs args)
    {
        if (args.Value is null)
        {
            return;
        }

        searchText = args.Value.ToString();
        Logger.LogInformation("searchtext: {searchText}", searchText);

        if (searchText is not null && searchText.Length > 2)
        {
            dataGridSecretItems.Clear();
            dataGridSecretItems.AddRange(cachedSecretItems!.Where(x => x.Name!.Contains(searchText)));
            await dataGridRef!.Reload();
        }
    }
}


