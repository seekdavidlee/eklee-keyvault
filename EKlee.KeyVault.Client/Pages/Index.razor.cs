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

    private RadzenDataGrid<SecretItem>? dataGridRef;
    private List<SecretItem>? secretItems;
    private string? errorMessage;

    protected override async Task OnInitializedAsync()
    {
        errorMessage = null;
        try
        {
            secretItems = (await KeyVaultService.GetSecrets(AccessTokenProvider)).ToList();
        }
        catch (Exception ex)
        {
            errorMessage = ex.Message;
        }
    }
}


