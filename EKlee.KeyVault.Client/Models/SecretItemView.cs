﻿namespace EKlee.KeyVault.Client.Models;

public class SecretItemView
{
    public const string PlaceHolderValue = "***";
    public SecretItemView(SecretItem secretItem)
    {
        var parts = secretItem.Id!.Split('/');
        Id = parts[parts.Length - 1];
        Name = secretItem.Name;
        Value = PlaceHolderValue;
    }
    public string? Id { get; set; }
    public string? Name { get; set; }

    public string? Value { get; set; }
}
