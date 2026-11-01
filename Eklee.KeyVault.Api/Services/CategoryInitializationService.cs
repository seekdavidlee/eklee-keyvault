namespace Eklee.KeyVault.Api.Services;

/// <summary>Completes category migration before the application accepts requests.</summary>
public sealed class CategoryInitializationService(IServiceScopeFactory scopeFactory) : IHostedService
{
    /// <inheritdoc/>
    public async Task StartAsync(CancellationToken cancellationToken)
    {
        using var scope = scopeFactory.CreateScope();
        await scope.ServiceProvider.GetRequiredService<CategoryService>().InitializeAsync(cancellationToken);
    }

    /// <inheritdoc/>
    public Task StopAsync(CancellationToken cancellationToken) => Task.CompletedTask;
}