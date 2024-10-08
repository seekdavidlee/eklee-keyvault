using EKlee.KeyVault.Client.Models;
using EKlee.KeyVault.Client.Services;
using Microsoft.AspNetCore.Components;
using Microsoft.AspNetCore.Components.WebAssembly.Authentication;
using Radzen.Blazor;

namespace EKlee.KeyVault.Client.Pages;

public partial class Index : ComponentBase
{
    [Inject] private IAccessTokenProvider AccessTokenProvider { get; set; } = default!;

    [Inject] private KeyVaultService KeyVaultService { get; set; } = default!;

    private RadzenDataGrid<SecretItemView>? dataGridRef;
    private List<SecretItemView>? secretItems;
    private string? errorMessage;

    protected override async Task OnInitializedAsync()
    {
        errorMessage = null;
        try
        {
            secretItems = (await KeyVaultService.GetSecretsAsync(AccessTokenProvider)).Select(x => new SecretItemView(x)).ToList();
        }
        catch (Exception ex)
        {
            errorMessage = ex.Message;
        }
    }

    private async void ShowSecret(SecretItemView secretItemView)
    {
        errorMessage = null;
        try
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
            StateHasChanged();
        }
        catch (Exception ex)
        {
            errorMessage = ex.Message;
        }
    }
}


