using System.Threading.Tasks;

namespace Eklee.KeyVault.Viewer.Core
{
	public interface IKeyVaultClient
	{
		Task<SecretItemList> ListSecrets();
		Task<SecretValue> GetSecretValue(string id);
	}
}
