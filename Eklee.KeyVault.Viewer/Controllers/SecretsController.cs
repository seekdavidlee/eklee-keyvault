using Eklee.KeyVault.Viewer.Core;
using Microsoft.AspNetCore.Mvc;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.Logging;
using Microsoft.Identity.Web;
using System;
using System.Net.Http;
using System.Threading.Tasks;

namespace Eklee.KeyVault.Viewer.Controllers
{
	public class SecretsController : Controller
	{
		private readonly ILogger<SecretsController> _logger;
		private readonly IKeyVaultClient _keyVaultClient;
		private readonly IConfiguration _configuration;

		public SecretsController(
			ILogger<SecretsController> logger,
			IKeyVaultClient keyVaultClient,
			IConfiguration configuration)
		{
			_logger = logger;
			_keyVaultClient = keyVaultClient;
			_configuration = configuration;
		}

		[AuthorizeForScopes(Scopes = new[] { MyConstants.UserImpersonationScope })]
		public async Task<IActionResult> Index()
		{
			ViewData["Title"] = _configuration["KeyVaultName"];

			try
			{
				ViewData["secrets"] = (await _keyVaultClient.ListSecrets()).Value;
			}
			catch (HttpRequestException e)
			{
				_logger.LogError(e, "Http error listing secrets!");

				if (e.StatusCode == System.Net.HttpStatusCode.Forbidden)
				{
					ViewData["Error"] = "You do NOT have access to this Azure Key Vault. Please consult the Key Vault Administrator for access.";
				}
			}

			return View();
		}

		public async Task<IActionResult> Value(string id)
		{
			try
			{
				return Ok((await _keyVaultClient.GetSecretValue(id)).Value);
			}
			catch (HttpRequestException e)
			{
				_logger.LogError(e, "Error getting secret!");

				if (e.StatusCode == System.Net.HttpStatusCode.Forbidden)
				{
					return Forbid();
				}

				return Problem(e.Message);
			}
		}
	}
}
