// Renames the package root in cooked legacy uassets (e.g. /EnglishZone/... -> /Game/...)
// so retoc to-zen derives vanilla package IDs (identity-collision override, no redirects).
// Usage: EzRename --in <dir> --usmap <file> --from /EnglishZone --to /Game
using System.Text.Json;
using UAssetAPI;
using UAssetAPI.UnrealTypes;
using UAssetAPI.Unversioned;

string? inDir = null, usmapPath = null, from = "/EnglishZone", to = "/Game";
string? importMapPath = null;
var engineVersion = EngineVersion.VER_UE5_5;
for (int i = 0; i < args.Length - 1; i++)
{
  switch (args[i])
  {
    case "--in": inDir = args[++i]; break;
    case "--usmap": usmapPath = args[++i]; break;
    case "--from": from = args[++i]; break;
    case "--to": to = args[++i]; break;
    case "--version": engineVersion = Enum.Parse<EngineVersion>(args[++i], true); break;
    case "--restore-imports": importMapPath = args[++i]; break;
  }
}
if (inDir is null || usmapPath is null)
{
  Console.Error.WriteLine("usage: EzRename --in <dir> --usmap <file> [--from /EnglishZone] [--to /Game] [--version VER_UE5_5] [--restore-imports <json>]");
  return 1;
}

var usmap = new Usmap(usmapPath);
var files = Directory.GetFiles(inDir, "*.uasset", SearchOption.AllDirectories);
var importRepairs = importMapPath is null ? [] : JsonSerializer.Deserialize<ImportRepair[]>(File.ReadAllText(importMapPath))
    ?? throw new InvalidDataException("Empty import repair map");
if (importMapPath is not null && (files.Length != 1 || importRepairs.Length == 0))
  throw new InvalidDataException("Import repair requires one asset and a nonempty repair map");
int okCount = 0, failCount = 0;
foreach (var file in files)
{
  try
  {
    var asset = new UAsset(file, engineVersion, usmap);
    foreach (var repair in importRepairs)
    {
      var import = asset.Imports[repair.Index];
      var outerIndex = -import.OuterIndex.Index - 1;
      if (import.ObjectName.ToString() != "UnknownExport" || outerIndex < 0 || outerIndex >= asset.Imports.Count)
        throw new InvalidDataException($"Import {repair.Index} is not an unresolved external object");
      var outer = asset.Imports[outerIndex];
      if (outer.ObjectName.ToString() != "/Engine/UnknownPackage" || outer.ClassName.ToString() != "Package")
        throw new InvalidDataException($"Import {repair.Index} does not have the expected unresolved package outer");
      if (asset.Imports.Count(other => other.OuterIndex.Index == import.OuterIndex.Index) != 1)
        throw new InvalidDataException($"Import {repair.Index} shares its unresolved package outer");
      import.ClassPackage = new FName(asset, repair.ClassPackage);
      import.ClassName = new FName(asset, repair.ClassName);
      import.ObjectName = new FName(asset, repair.ObjectName);
      outer.ObjectName = new FName(asset, repair.PackageName);
      Console.WriteLine($"RESTORED import {repair.Index}: {repair.PackageName}.{repair.ObjectName}");
    }
    int renamed = 0;
    var nameMap = asset.GetNameMapIndexList();
    for (int i = 0; i < nameMap.Count; i++)
    {
      var v = nameMap[i].Value;
      if (v != null && v.StartsWith(from + "/", StringComparison.Ordinal))
      {
        var nv = to + v.Substring(from.Length);
        asset.SetNameReference(i, new FString(nv));
        renamed++;
      }
    }
    if (asset.FolderName?.Value is string fn && fn.StartsWith(from + "/", StringComparison.Ordinal))
      asset.FolderName = new FString(to + fn.Substring(from.Length));
    asset.Write(file);
    Console.WriteLine($"OK {Path.GetFileName(file)}: {renamed} name(s) renamed");
    okCount++;
  }
  catch (Exception ex)
  {
    Console.Error.WriteLine($"FAIL {Path.GetFileName(file)}: {ex.Message}");
    failCount++;
  }
}
Console.WriteLine($"done: {okCount} ok, {failCount} failed");
return failCount == 0 ? 0 : 1;

record ImportRepair(int Index, string PackageName, string ObjectName, string ClassPackage, string ClassName);
