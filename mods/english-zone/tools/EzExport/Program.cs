// EzExport: export textures (PNG) + their properties (JSON) from a set of IoStore/pak containers.
// Usage:
//   EzExport --paks <dir> --game <EGame name|int> --usmap <file> --oodle <dll> --out <dir> (--filter <regex> | --paths <file>)
//            [--list] [--json-only] [--mesh [--nanite]] [--names <vanilla paks dir> [--names-game <EGame>] [--alt-roots A,B]]
using System.Text;
using System.Text.RegularExpressions;
using CUE4Parse;
using CUE4Parse.Compression;
using CUE4Parse.Encryption.Aes;
using CUE4Parse.FileProvider;
using CUE4Parse.MappingsProvider.Usmap;
using CUE4Parse.UE4.Assets;
using CUE4Parse.UE4.Assets.Exports.StaticMesh;
using CUE4Parse.UE4.IO;
using CUE4Parse.UE4.IO.Objects;
using CUE4Parse.UE4.Objects.UObject;
using CUE4Parse.Utils;
using CUE4Parse.UE4.Assets.Exports.Texture;
using CUE4Parse.UE4.Objects.Core.Math;
using CUE4Parse.UE4.Objects.Core.Misc;
using CUE4Parse.UE4.Versions;
using CUE4Parse_Conversion;
using CUE4Parse_Conversion.Options;
using CUE4Parse_Conversion.Textures;
using Newtonsoft.Json;
using Newtonsoft.Json.Serialization;
using Serilog;

Log.Logger = new LoggerConfiguration().MinimumLevel.Warning().WriteTo.Console().CreateLogger();

var opts = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
for (var i = 0; i < args.Length; i++)
{
  if (!args[i].StartsWith("--")) continue;
  var key = args[i][2..];
  opts[key] = i + 1 < args.Length && !args[i + 1].StartsWith("--") ? args[++i] : "true";
}

string Req(string k) => opts.TryGetValue(k, out var v) ? v : throw new ArgumentException($"missing --{k}");

var game = int.TryParse(Req("game"), out var gi) ? (EGame)gi : Enum.Parse<EGame>(Req("game"), true);
// --ver borrows another engine's package file version (e.g. GAME_UE5_1 for old cooks) while keeping --game's custom serialization.
var versions = opts.TryGetValue("ver", out var verStr)
    ? new VersionContainer(game, ver: Enum.Parse<EGame>(verStr, true).GetVersion())
    : new VersionContainer(game);
Console.WriteLine($"game = {game} ({(int)game}) ver = {(opts.TryGetValue("ver", out var v2) ? v2 : "default")}");

OodleHelper.Initialize(Req("oodle"));

var provider = new DefaultFileProvider(Req("paks"), SearchOption.AllDirectories, versions, StringComparer.OrdinalIgnoreCase);
provider.ReadNaniteData = opts.ContainsKey("nanite") || opts.ContainsKey("nanite-probe");
provider.MappingsContainer = new FileUsmapTypeMappingsProvider(Req("usmap"));
provider.Initialize();
provider.SubmitKey(new FGuid(), new FAesKey(new byte[32]));
provider.PostMount();
Console.WriteLine($"mounted {provider.MountedVfs.Count} containers, {provider.Files.Count} files");

var outDir = Req("out");
Directory.CreateDirectory(outDir);

Func<string, bool> match;
if (opts.TryGetValue("paths", out var pathsFile))
{
  var set = new HashSet<string>(File.ReadAllLines(pathsFile).Select(l => l.Trim()).Where(l => l.Length > 0), StringComparer.OrdinalIgnoreCase);
  match = set.Contains;
}
else
{
  var filter = new Regex(Req("filter"), RegexOptions.IgnoreCase);
  match = filter.IsMatch;
}

var targets = provider.Files.Keys
    .Where(k => k.EndsWith(".uasset", StringComparison.OrdinalIgnoreCase) && match(k))
    .OrderBy(k => k)
    .ToList();
Console.WriteLine($"matched {targets.Count} packages");

if (opts.ContainsKey("list"))
{
  foreach (var t in targets) Console.WriteLine("  " + t);
  return 0;
}

// Old (UE5.1) zen packages store imports as package-ID hashes; unmounted (vanilla) targets serialize
// as null. --names maps IDs from another container set back to package names so JSON keeps the refs.
var jsonSettings = new JsonSerializerSettings { Formatting = Formatting.Indented };
if (opts.TryGetValue("names", out var namesDir))
{
  var altRoots = (opts.TryGetValue("alt-roots", out var ar) ? ar : "EnglishZone").Split(',', StringSplitOptions.RemoveEmptyEntries);
  var pkgNames = new Dictionary<ulong, string>();
  var badNames = 0;
  void AddReaders(IEnumerable<IoStoreReader> readers)
  {
    foreach (var r in readers)
      foreach (var (id, file) in r.PackageIdIndex)
      {
        var name = PackageNames.Candidates(file.Path, altRoots).FirstOrDefault(n => FPackageId.FromName(n).id == id.id);
        if (name is null) badNames++; else pkgNames[id.id] = name;
      }
  }
  var namesGame = opts.TryGetValue("names-game", out var ng) ? ng : "84213760";
  var namesVer = new VersionContainer(int.TryParse(namesGame, out var ngi) ? (EGame)ngi : Enum.Parse<EGame>(namesGame, true));
  using (var np = new DefaultFileProvider(namesDir, SearchOption.TopDirectoryOnly, namesVer, StringComparer.OrdinalIgnoreCase))
  {
    np.Initialize();
    np.SubmitKey(new FGuid(), new FAesKey(new byte[32]));
    AddReaders(np.MountedVfs.OfType<IoStoreReader>());
  }
  AddReaders(provider.MountedVfs.OfType<IoStoreReader>());

  var storeImports = new Dictionary<ulong, FPackageId[]>();
  foreach (var r in provider.MountedVfs.OfType<IoStoreReader>())
  {
    var h = r.ContainerHeader;
    if (h?.PackageIds is null) continue;
    for (var i = 0; i < h.PackageIds.Length; i++)
      storeImports[h.PackageIds[i].id] = h.StoreEntries[i].ImportedPackages ?? [];
  }
  Console.WriteLine($"names: {pkgNames.Count} package ids mapped ({badNames} unmatched), {storeImports.Count} store entries");
  File.WriteAllLines(Path.Combine(outDir, "_package-names.txt"), pkgNames.Values.Order(StringComparer.OrdinalIgnoreCase));

  string? ResolveImport(FPackageIndex idx)
  {
    if (idx.Owner is not IoPackage pkg) return null;
    var i = -idx.Index - 1;
    if (i < 0 || i >= pkg.ImportMap.Length || !pkg.ImportMap[i].IsPackageImport) return null;
    if (!storeImports.TryGetValue(FPackageId.FromName(pkg.Name).id, out var imported)) return null;
    var r = pkg.ImportMap[i].AsPackageImportRef;
    if (r.ImportedPackageIndex >= imported.Length) return null;
    var pid = imported[r.ImportedPackageIndex].id;
    if (!pkgNames.TryGetValue(pid, out var name)) return $"UNRESOLVED:{pid:x16}";
    // Assume the asset object (leaf) and prove it against the import's public export hash.
    var leaf = name[(name.LastIndexOf('/') + 1)..];
    var hash = CityHash.CityHash64(Encoding.Unicode.GetBytes(leaf.ToLowerInvariant()));
    var ok = r.ImportedPublicExportHashIndex < pkg.ImportedPublicExportHashes.Length && pkg.ImportedPublicExportHashes[r.ImportedPublicExportHashIndex] == hash;
    return ok ? $"{name}.{leaf}" : $"UNRESOLVED-EXPORT:{name}";
  }
  jsonSettings.ContractResolver = new ImportResolvingContractResolver(new ImportResolvingConverter(ResolveImport));
}

var failed = 0;
foreach (var path in targets)
{
  var rel = Path.ChangeExtension(path, null);
  try
  {
    var pkg = provider.LoadPackage(path);
    var exports = pkg.GetExports().ToList();
    var jsonPath = Path.Combine(outDir, rel + ".json");
    Directory.CreateDirectory(Path.GetDirectoryName(jsonPath)!);
    File.WriteAllText(jsonPath, JsonConvert.SerializeObject(exports, jsonSettings));

    foreach (var tex in exports.OfType<UTexture2D>())
    {
      if (opts.ContainsKey("json-only")) continue;
      var bitmap = tex.Decode();
      if (bitmap is null) { Console.WriteLine($"  NODECODE {rel}"); failed++; continue; }
      var data = bitmap.Encode(ETextureFormat.Png, false, out var ext);
      var pngPath = Path.Combine(outDir, rel + "." + ext);
      File.WriteAllBytes(pngPath, data);
      Console.WriteLine($"  OK {rel} {tex.PlatformData.SizeX}x{tex.PlatformData.SizeY} {tex.Format} sRGB={tex.SRGB}");
    }

    if (opts.ContainsKey("nanite-probe"))
    {
      foreach (var mesh in exports.OfType<UStaticMesh>())
      {
        var res = mesh.RenderData?.NaniteResources;
        if (res is null) { Console.WriteLine($"  NANITE {rel}: none"); continue; }
        Console.WriteLine($"  NANITE {rel}: rootPages={res.NumRootPages} pages={res.PageStreamingStates.Length} clusters={res.NumClusters} inputTris={res.NumInputTriangles} inputVerts={res.NumInputVertices} uvs={res.NumInputTexCoords} posPrec={res.PositionPrecision} flags={res.ResourceFlags}");
        res.LoadAllPages();
        for (var p = 0; p < res.LoadedPages.Length; p++)
        {
          var page = res.LoadedPages[p];
          if (page is null) { Console.WriteLine($"    page {p}: LOAD FAILED"); continue; }
          var leaf = page.Clusters.Count(c => c.EdgeLength < 0f);
          Console.WriteLine($"    page {p}: clusters={page.Clusters.Length} tris={page.Clusters.Sum(c => c.NumTris)} verts={page.Clusters.Sum(c => c.NumVerts)} edgeNeg={leaf}");
          foreach (var c in page.Clusters)
            Console.WriteLine($"      tris={c.NumTris} verts={c.NumVerts} edge={c.EdgeLength:G6} lodErr={c.LODError:G6} flags={c.Flags} uvs={c.NumUVs} matTable={c.ShouldUseMaterialTable()} m0={c.Material0Index}x{c.Material0Length} m1={c.Material1Index}x{c.Material1Length}");
        }

        Console.WriteLine($"  DTO probe: StaticMaterials={mesh.StaticMaterials.Length}");
        using var dto = new CUE4Parse_Conversion.Dto.StaticMeshDto(mesh,
            new ExportOptions(meshFormat: EMeshFormat.Gltf2, naniteMeshFormat: ENaniteMeshFormat.NaniteOnly, exportMaterials: false, exportMorphTargets: false));
        Console.WriteLine($"  DTO: LODs={dto.LODs.Count}");
        foreach (var lod in dto.LODs)
        {
          Console.WriteLine($"    LOD nanite={lod.IsNanite} verts={lod.Vertices.Length} indices={lod.Indices.Length} sections={lod.Sections.Length}");
          foreach (var s in lod.Sections)
            Console.WriteLine($"      section mat={s.MaterialIndex} firstIndex={s.FirstIndex} numFaces={s.NumFaces}");
          var nan = lod.Vertices.Count(vt => float.IsNaN(vt.Position.X) || float.IsNaN(vt.Position.Y) || float.IsNaN(vt.Position.Z));
          var zero = lod.Vertices.Count(vt => vt.Position.X == 0 && vt.Position.Y == 0 && vt.Position.Z == 0);
          var minX = lod.Vertices.Min(vt => vt.Position.X); var maxX = lod.Vertices.Max(vt => vt.Position.X);
          var minY = lod.Vertices.Min(vt => vt.Position.Y); var maxY = lod.Vertices.Max(vt => vt.Position.Y);
          var minZ = lod.Vertices.Min(vt => vt.Position.Z); var maxZ = lod.Vertices.Max(vt => vt.Position.Z);
          Console.WriteLine($"      verts: nan={nan} zero={zero} bounds=({minX:G5},{minY:G5},{minZ:G5})..({maxX:G5},{maxY:G5},{maxZ:G5})");
          for (var i = 0; i < Math.Min(5, lod.Vertices.Length); i++)
          {
            var vt = lod.Vertices[i];
            Console.WriteLine($"      v[{i}] pos=({vt.Position.X:G5},{vt.Position.Y:G5},{vt.Position.Z:G5}) nrm=({vt.Normal.X:G4},{vt.Normal.Y:G4},{vt.Normal.Z:G4})");
          }
          var maxIdx = lod.Indices.Length > 0 ? lod.Indices.Max() : 0;
          Console.WriteLine($"      indices: max={maxIdx} (verts={lod.Vertices.Length}) first12=[{string.Join(",", lod.Indices.Take(12))}]");
        }
      }
    }

    if (opts.ContainsKey("mesh"))
    {
      foreach (var mesh in exports.OfType<UStaticMesh>())
      {
        var naniteRes = mesh.RenderData?.NaniteResources;
        var hasNanite = naniteRes is { PageStreamingStates.Length: > 0 };
        var nanite = opts.ContainsKey("nanite") && hasNanite ? ENaniteMeshFormat.NaniteOnly : ENaniteMeshFormat.NoNanite;
        var exportOptions = new ExportOptions(meshFormat: EMeshFormat.Gltf2, naniteMeshFormat: nanite, exportMaterials: false, exportMorphTargets: false);
        using var dto = new CUE4Parse_Conversion.Dto.StaticMeshDto(mesh, exportOptions);
        if (dto.LODs.Count == 0) { Console.WriteLine($"  MESHFAIL {rel}: no LODs"); failed++; continue; }

        // Unresolved material imports yield slot name "None" for every slot, which collapses
        // the GLB primitives into one material. Restore the real slot names from the asset.
        for (var i = 0; i < dto.Materials.Length && i < mesh.StaticMaterials.Length; i++)
        {
          var sm = mesh.StaticMaterials[i];
          dto.Materials[i] = new CUE4Parse_Conversion.Dto.MeshMaterialDto(sm.ImportedMaterialSlotName?.Text ?? sm.MaterialSlotName.Text);
        }

        var uvs = nanite == ENaniteMeshFormat.NaniteOnly ? naniteRes!.NumInputTexCoords : mesh.RenderData?.LODs?.FirstOrDefault()?.VertexBuffer?.NumTexCoords ?? 0;
        var infoPath = Path.Combine(outDir, rel + ".meshinfo.json");
        Directory.CreateDirectory(Path.GetDirectoryName(infoPath)!);
        File.WriteAllText(infoPath, JsonConvert.SerializeObject(new
        {
          nanite = hasNanite,
          uvs,
          lods = dto.LODs.Count,
          slots = mesh.StaticMaterials.Select(s => s.ImportedMaterialSlotName?.Text ?? s.MaterialSlotName.Text).ToArray(),
          slotRefs = mesh.StaticMaterials.Select(s => s.MaterialInterface?.Index ?? 0).ToArray(),
          // Empty sections are dropped from the GLB, so their slots won't exist after import.
          usedSlots = dto.LODs[0].Sections.Where(s => s.NumFaces > 0).Select(s => s.MaterialIndex).Distinct().OrderBy(x => x).ToArray(),
          sections = dto.LODs[0].Sections.Select(s => new { s.MaterialIndex, s.FirstIndex, s.NumFaces }).ToArray(),
        }, Formatting.Indented));

        foreach (var lod in dto.LODs)
        {
          // UE <5.3 Nanite clusters carry no tangents; FromNanite leaves tangent XYZ = 0 and
          // SharpGLTF's sanitizer silently rejects such vertices (empty GLB). Synthesize a
          // tangent orthogonal to the normal for any zero-tangent vertex.
          var patched = 0;
          for (var i = 0; i < lod.Vertices.Length; i++)
          {
            var vt = lod.Vertices[i];
            var t = vt.Tangent;
            if (t.X != 0 || t.Y != 0 || t.Z != 0) continue;
            var n = new FVector(vt.Normal.X, vt.Normal.Y, vt.Normal.Z);
            var helper = Math.Abs(n.Z) < 0.999f ? new FVector(0, 0, 1) : new FVector(1, 0, 0);
            var tan = helper ^ n; // cross product
            tan.Normalize();
            lod.Vertices[i] = new CUE4Parse_Conversion.Dto.MeshVertex(vt.Position, vt.Normal, new FVector4(tan.X, tan.Y, tan.Z, 1f), vt.Uv);
            patched++;
          }

          var glb = new CUE4Parse_Conversion.Writers.Gltf.Gltf(mesh.Name, lod, exportOptions).Model.WriteGLB().ToArray();
          var glbPath = Path.Combine(outDir, rel + (dto.LODs.Count > 1 && lod != dto.LODs[0] ? $"_LOD{lod.SourceLodIndex}" : "") + ".glb");
          Directory.CreateDirectory(Path.GetDirectoryName(glbPath)!);
          File.WriteAllBytes(glbPath, glb);
          Console.WriteLine($"  MESH {rel} nanite={lod.IsNanite} verts={lod.Vertices.Length} tris={lod.Indices.Length / 3} tangentsPatched={patched} -> {glbPath} ({glb.Length} bytes)");
        }
      }
    }
  }
  catch (Exception ex)
  {
    failed++;
    Console.WriteLine($"  FAIL {rel}: {ex.GetType().Name}: {ex.Message}");
  }
}

Console.WriteLine($"done: {targets.Count - failed} ok, {failed} failed");
return failed == 0 ? 0 : 1;

static class PackageNames
{
  // "Stalker2/Content/X.uasset" -> "/Game/X" (or an alt root such as a mod's plugin name),
  // "Engine/Content/X" -> "/Engine/X", "<...>/<Plugin>/Content/X" -> "/<Plugin>/X".
  public static IEnumerable<string> Candidates(string path, string[] altRoots)
  {
    var p = Path.ChangeExtension(path, null).Replace('\\', '/').TrimStart('/');
    var i = p.IndexOf("/Content/", StringComparison.OrdinalIgnoreCase);
    if (i < 0) yield break;
    var head = p[..i];
    var tail = p[(i + "/Content/".Length)..];
    if (!head.Contains('/') && head != "Engine")
    {
      yield return "/Game/" + tail;
      foreach (var r in altRoots) yield return $"/{r}/{tail}";
    }
    yield return $"/{head[(head.LastIndexOf('/') + 1)..]}/{tail}";
  }
}

sealed class ImportResolvingConverter(Func<FPackageIndex, string?> resolve) : JsonConverter<FPackageIndex>
{
  static readonly FPackageIndexConverter Inner = new();
  public override void WriteJson(JsonWriter writer, FPackageIndex? value, JsonSerializer serializer)
  {
    var r = value is { IsImport: true } ? resolve(value) : null;
    if (r is not null) writer.WriteValue(r);
    else Inner.WriteJson(writer, value!, serializer);
  }
  public override FPackageIndex ReadJson(JsonReader reader, Type objectType, FPackageIndex? existingValue, bool hasExistingValue, JsonSerializer serializer) =>
    throw new NotSupportedException();
}

// FPackageIndex carries a type-level [JsonConverter], which outranks settings.Converters; override the contract instead.
sealed class ImportResolvingContractResolver(JsonConverter converter) : DefaultContractResolver
{
  protected override JsonContract CreateContract(Type objectType)
  {
    var c = base.CreateContract(objectType);
    if (objectType == typeof(FPackageIndex)) c.Converter = converter;
    return c;
  }
}
