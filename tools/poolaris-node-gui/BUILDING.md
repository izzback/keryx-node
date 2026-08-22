# Building Poolaris Node GUI

Requirements:

- Windows 10/11 x64
- .NET 8 SDK

Build:

```powershell
cd tools\poolaris-node-gui
dotnet restore
dotnet build -c Release
```

Run:

```powershell
dotnet run -c Release
```

Publish a self-contained Windows executable folder:

```powershell
dotnet publish -c Release -r win-x64 --self-contained true -p:PublishSingleFile=false
```

The GUI is intentionally separate from Keryx consensus code. It launches and monitors `keryxd.exe` as an external process.
