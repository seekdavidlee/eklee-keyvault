using Microsoft.Extensions.Configuration;
using Microsoft.Identity.Web;
using Newtonsoft.Json;
using System;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Threading.Tasks;

namespace Eklee.KeyVault.Viewer.Core
{
	public class KeyVaultClient : IKeyVaultClient, IDisposable
	{
		private readonly ITokenAcquisition _tokenAcquisition;
		private readonly string _keyVaultUrl;
		private const string _version = "api-version=7.1";
		public KeyVaultClient(
			ITokenAcquisition tokenAcquisition,
			IConfiguration configuration)
		{
			_tokenAcquisition = tokenAcquisition;

			var keyVaultName = configuration["KeyVaultName"];
			_keyVaultUrl = $"https://{keyVaultName}.vault.azure.net";
		}
		public async Task<SecretItemList> ListSecrets()
		{
			var client = await GetAuthenticatedHttpClient();
			var json = await client.GetStringAsync($"{_keyVaultUrl}/secrets?maxresults=1000&{_version}");
			var result = JsonConvert.DeserializeObject<SecretItemList>(json);
			return result;
		}

		private HttpClient _httpClient;
		private HttpClient GetHttpClient()
		{
			if (_httpClient == null) _httpClient = new HttpClient();

			return _httpClient;
		}

		private async Task<string> GetAccessToken()
		{
			string[] scopes = new string[] { MyConstants.UserImpersonationScope };
			return await _tokenAcquisition.GetAccessTokenForUserAsync(scopes);
		}

		private async Task<HttpClient> GetAuthenticatedHttpClient()
		{
			var client = GetHttpClient();
			client.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", await GetAccessToken());
			return client;
		}

		public async Task<SecretValue> GetSecretValue(string id)
		{
			var client = await GetAuthenticatedHttpClient();
			var json = await client.GetStringAsync($"{id}?{_version}");
			var result = JsonConvert.DeserializeObject<SecretValue>(json);
			return result;
		}

		public void Dispose()
		{
			if (_httpClient != null) _httpClient.Dispose();
		}
	}
}
