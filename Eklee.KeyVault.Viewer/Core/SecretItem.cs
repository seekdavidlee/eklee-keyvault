using System.Collections.Generic;

namespace Eklee.KeyVault.Viewer.Core
{
	public class SecretItemList
	{
		public List<SecretItem> Value { get; set; }

		public string NextLink { get; set; }
	}

	public class SecretValue
	{
		public string Value { get; set; }
	}

	public class SecretItem
	{
		public string Id { get; set; }
		public bool Enabled { get; set; }

		public string Name
		{
			get
			{
				var parts = Id.Split('/');
				return parts[parts.Length - 1];
			}
		}
	}
}
