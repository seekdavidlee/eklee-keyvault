using Microsoft.AspNetCore.Components.Web;
using Microsoft.AspNetCore.Components.WebAssembly.Hosting;
using EKlee.KeyVault.Client;
using EKlee.KeyVault.Client.Services;
using EKlee.KeyVault.Client.Modules;

var builder = WebAssemblyHostBuilder.CreateDefault(args);
builder.RootComponents.Add<App>("#app");
builder.RootComponents.Add<HeadOutlet>("head::after");

builder.Services.AddSingleton<IAppModule, Dashboard>();

builder.Services.AddSingleton<Config>();

// Create a httpClient that will be used to access the KeyVault
builder.Services.AddHttpClient();

// Work around for an issue related to appsettings not being downloaded when hosted on azure storage website.
using var http = new HttpClient()
{
    BaseAddress = new Uri(builder.HostEnvironment.BaseAddress)
};

using var response = await http.GetAsync("appsettings.json");
using var stream = await response.Content.ReadAsStreamAsync();

builder.Configuration.AddJsonStream(stream);
builder.Services.AddSingleton<BlobService>();
builder.Services.AddSingleton<KeyVaultService>();
builder.Services.AddMsalAuthentication(options =>
{
    builder.Configuration.Bind("AzureAd", options.ProviderOptions.Authentication);
    var additionalScopes = (builder.Configuration.GetSection("AdditionalScopes") ?? throw new Exception("AdditionalScopes is not configured.")).Get<string[]>()!;
    foreach (var scope in additionalScopes)
    {
        options.ProviderOptions.AdditionalScopesToConsent.Add(scope);
    }
});

await builder.Build().RunAsync();
