﻿using EKlee.KeyVault.Client.Models;
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

    [Inject] private BlobService BlobService { get; set; } = default!;

    [Inject] private IJSRuntime JS { get; set; } = default!;

    [Inject] private ILogger<Index> Logger { get; set; } = default!;

    private RadzenDataGrid<SecretItemView>? dataGridRef;
    private List<SecretItemView>? cachedSecretItems;
    private readonly List<SecretItemView> dataGridSecretItems = [];
    private SecretItemMetaList? metaList;
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
            metaList = await BlobService.GetMetaAsync(AccessTokenProvider);
            cachedSecretItems = (await KeyVaultService.GetSecretsAsync(AccessTokenProvider)).Select(x => new SecretItemView(x, metaList)).ToList();
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

    private string? previousDisplayName;
    private void ShowEditDisplayName(SecretItemView secretItemView)
    {
        previousDisplayName = secretItemView.Meta.DisplayName;
        secretItemView.IsEditDisplayName = true;
    }

    private async Task SaveDisplayName(SecretItemView secretItemView)
    {
        await BlobService.UpdateMetaAsync(AccessTokenProvider, metaList!);
        secretItemView.IsEditDisplayName = false;
    }

    private void CancelSaveDisplayName(SecretItemView secretItemView)
    {
        secretItemView.Meta.DisplayName = previousDisplayName;
        secretItemView.IsEditDisplayName = false;
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
            dataGridSecretItems.AddRange(cachedSecretItems!.Where(x => x.Meta.DisplayName!.Contains(searchText)));
            await dataGridRef!.Reload();
        }
        else
        {
            if (dataGridSecretItems.Count != cachedSecretItems!.Count)
            {
                dataGridSecretItems.Clear();
                dataGridSecretItems.AddRange(cachedSecretItems!);
                await dataGridRef!.Reload();
            }
        }
    }
}


