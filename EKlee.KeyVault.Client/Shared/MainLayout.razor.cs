using Microsoft.AspNetCore.Components.WebAssembly.Authentication;
using Microsoft.AspNetCore.Components;

namespace EKlee.KeyVault.Client.Shared;

public partial class MainLayout
{
    bool sidebarIsExpanded = true;
    bool isAuthenticated = false;

    [Inject] NavigationManager Navigation { get; set; } = default!;

    protected override async Task OnInitializedAsync()
    {
        var state = await this.AuthenticationStateProvider.GetAuthenticationStateAsync();

        isAuthenticated = state.User is not null && state.User.Identity is not null && state.User.Identity.IsAuthenticated;

        if (isAuthenticated)
        {
            SystemConfig.Update(state.User!);
        }
        else
        {
            this.AuthenticationStateProvider.AuthenticationStateChanged += async (authState) =>
            {
                var result = await authState;
                if (result is not null && result.User is not null && result.User.Identity is not null && result.User.Identity.IsAuthenticated)
                {
                    isAuthenticated = true;
                    SystemConfig.Update(result.User);

                }
            };
        }
    }

    private void SignOut()
    {
        Navigation.NavigateToLogout("authentication/logout");
    }

    private void SignIn()
    {
        Navigation.NavigateToLogin("/");
    }
}
