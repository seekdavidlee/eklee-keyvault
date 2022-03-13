using System.Collections.Generic;
using System.Threading.Tasks;

namespace Eklee.KeyVault.Viewer.Core
{
	public interface IKeyVaultClient
	{
		Task<IEnumerable<SecretItem>> ListSecrets();
		Task<SecretValue> GetSecretValue(string id);
	}
}
