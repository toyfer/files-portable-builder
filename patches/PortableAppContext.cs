// Copyright (c) Files Community
// Licensed under the MIT License.
// Portable / unpackaged support (folder-local data + no package registration).

using System.Collections.Concurrent;
using System.Reflection;
using System.Text.Json;
using Windows.ApplicationModel;

namespace Files.App.Helpers;

/// <summary>
/// Paths and lightweight settings for unpackaged (portable) builds.
/// When packaged, defers to Windows.Storage.ApplicationData / Package.Current.
/// When unpackaged, keeps everything under &lt;exe-dir&gt;\Data\ (or FILES_PORTABLE_DATA).
/// </summary>
internal static class PortableAppContext
{
	private static readonly Lazy<bool> _isPackaged = new(DetectPackaged);
	private static readonly Lazy<string> _installRoot = new(ResolveInstallRoot);
	private static readonly Lazy<string> _dataRoot = new(ResolveDataRoot);
	private static readonly Lazy<PortableLocalSettings> _settings = new(() => new PortableLocalSettings(Path.Combine(DataRoot, "LocalSettings.json")));

	public static bool IsPackaged => _isPackaged.Value;

	public static bool IsPortable => !IsPackaged;

	public static string InstallRoot => _installRoot.Value;

	public static string DataRoot => _dataRoot.Value;

	public static string LocalFolderPath
	{
		get
		{
			if (IsPackaged)
				return Windows.Storage.ApplicationData.Current.LocalFolder.Path;
			EnsureDir(Path.Combine(DataRoot, "LocalState"));
			return Path.Combine(DataRoot, "LocalState");
		}
	}

	public static string TemporaryFolderPath
	{
		get
		{
			if (IsPackaged)
				return Windows.Storage.ApplicationData.Current.TemporaryFolder.Path;
			EnsureDir(Path.Combine(DataRoot, "TempState"));
			return Path.Combine(DataRoot, "TempState");
		}
	}

	public static string RoamingFolderPath
	{
		get
		{
			if (IsPackaged)
				return Windows.Storage.ApplicationData.Current.RoamingFolder.Path;
			EnsureDir(Path.Combine(DataRoot, "RoamingState"));
			return Path.Combine(DataRoot, "RoamingState");
		}
	}

	public static string LocalCacheFolderPath
	{
		get
		{
			if (IsPackaged)
				return Windows.Storage.ApplicationData.Current.LocalCacheFolder.Path;
			EnsureDir(Path.Combine(DataRoot, "LocalCache"));
			return Path.Combine(DataRoot, "LocalCache");
		}
	}

	/// <summary>Mutable settings bag (packaged: ApplicationData LocalSettings; portable: JSON file).</summary>
	public static IDictionary<string, object> LocalSettingsValues
	{
		get
		{
			if (IsPackaged)
				return Windows.Storage.ApplicationData.Current.LocalSettings.Values;
			return _settings.Value;
		}
	}

	public static string PackageName => IsPackaged ? Package.Current.Id.Name : "FilesPortable";

	public static string PackageFamilyName => IsPackaged ? Package.Current.Id.FamilyName : "FilesPortable_local";

	public static string PackageDisplayName => IsPackaged ? Package.Current.DisplayName : "Files Portable";

	public static PackageVersion PackageVersion
	{
		get
		{
			if (IsPackaged)
				return Package.Current.Id.Version;

			var v = Assembly.GetExecutingAssembly().GetName().Version ?? new Version(4, 2, 0, 0);
			return new PackageVersion
			{
				Major = (ushort)Math.Clamp(v.Major, 0, ushort.MaxValue),
				Minor = (ushort)Math.Clamp(v.Minor, 0, ushort.MaxValue),
				Build = (ushort)Math.Clamp(v.Build < 0 ? 0 : v.Build, 0, ushort.MaxValue),
				Revision = (ushort)Math.Clamp(v.Revision < 0 ? 0 : v.Revision, 0, ushort.MaxValue),
			};
		}
	}

	public static Version AppVersion
	{
		get
		{
			var pv = PackageVersion;
			return new Version(pv.Major, pv.Minor, pv.Build, pv.Revision);
		}
	}

	public static string EffectivePath => IsPackaged ? Package.Current.EffectivePath : InstallRoot;

	public static string InstalledLocationPath => IsPackaged ? Package.Current.InstalledLocation.Path : InstallRoot;

	public static void EnsureDataLayout()
	{
		if (IsPackaged)
			return;

		EnsureDir(DataRoot);
		EnsureDir(LocalFolderPath);
		EnsureDir(TemporaryFolderPath);
		EnsureDir(RoamingFolderPath);
		EnsureDir(LocalCacheFolderPath);
		EnsureDir(Path.Combine(LocalFolderPath, "settings"));
	}

	private static bool DetectPackaged()
	{
		try
		{
			_ = Package.Current.Id.Name;
			return true;
		}
		catch
		{
			return false;
		}
	}

	private static string ResolveInstallRoot()
	{
		var baseDir = AppContext.BaseDirectory.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
		return string.IsNullOrEmpty(baseDir)
			? Path.GetDirectoryName(Environment.ProcessPath) ?? Environment.CurrentDirectory
			: baseDir;
	}

	private static string ResolveDataRoot()
	{
		var env = Environment.GetEnvironmentVariable("FILES_PORTABLE_DATA");
		if (!string.IsNullOrWhiteSpace(env))
			return Path.GetFullPath(env);

		return Path.Combine(InstallRoot, "Data");
	}

	private static void EnsureDir(string path) => Directory.CreateDirectory(path);

	private sealed class PortableLocalSettings : ConcurrentDictionary<string, object>, IDictionary<string, object>
	{
		private readonly string _path;
		private readonly object _ioLock = new();

		public PortableLocalSettings(string path)
		{
			_path = path;
			Load();
		}

		private void Load()
		{
			try
			{
				if (!File.Exists(_path))
					return;

				var json = File.ReadAllText(_path);
				var dict = JsonSerializer.Deserialize<Dictionary<string, JsonElement>>(json);
				if (dict is null)
					return;

				foreach (var kv in dict)
					base[kv.Key] = Unwrap(kv.Value)!;
			}
			catch
			{
			}
		}

		private void Save()
		{
			lock (_ioLock)
			{
				try
				{
					var dir = Path.GetDirectoryName(_path);
					if (!string.IsNullOrEmpty(dir))
						Directory.CreateDirectory(dir);

					var plain = new Dictionary<string, object?>();
					foreach (var kv in this)
						plain[kv.Key] = kv.Value;

					var json = JsonSerializer.Serialize(plain, new JsonSerializerOptions { WriteIndented = true });
					File.WriteAllText(_path, json);
				}
				catch
				{
				}
			}
		}

		private static object? Unwrap(JsonElement el) => el.ValueKind switch
		{
			JsonValueKind.String => el.GetString(),
			JsonValueKind.Number when el.TryGetInt32(out var i) => i,
			JsonValueKind.Number when el.TryGetInt64(out var l) => l,
			JsonValueKind.Number => el.GetDouble(),
			JsonValueKind.True => true,
			JsonValueKind.False => false,
			JsonValueKind.Null => null,
			_ => el.GetRawText(),
		};

		public new object this[string key]
		{
			get => base[key];
			set
			{
				base[key] = value;
				Save();
			}
		}

		bool IDictionary<string, object>.Remove(string key)
		{
			if (base.TryRemove(key, out _))
			{
				Save();
				return true;
			}
			return false;
		}

		void IDictionary<string, object>.Add(string key, object value)
		{
			base[key] = value;
			Save();
		}

		public bool ContainsKey(string key) => base.ContainsKey(key);
	}
}

internal static class PortableSettingsExtensions
{
	public static T Get<T>(this IDictionary<string, object> values, string key, T defaultValue)
	{
		if (!values.TryGetValue(key, out var raw) || raw is null)
			return defaultValue;

		try
		{
			if (raw is T t)
				return t;
			if (raw is JsonElement je)
				return je.Deserialize<T>() ?? defaultValue;
			return (T)Convert.ChangeType(raw, typeof(T));
		}
		catch
		{
			return defaultValue;
		}
	}
}
