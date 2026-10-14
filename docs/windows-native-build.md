# Portable balík pro Windows

Skript `scripts/build_windows_portable.ps1` na **Windows x64** sestaví release
a vytvoří přenosný ZIP. Kolega pak rozbalí celý archiv a spustí `open_ecad.exe`;
nepotřebuje Flutter, Visual Studio, Python ani instalátor. Nastavení a malá
automatická pracovní kopie se ukládají do uživatelského profilu Windows, takže
„přenosný“ neznamená, že se nastavení ukládá vedle EXE.

GitHub Actions sestaví aplikaci na Windows, ověří obsah archivu a spustí EXE
z nově rozbalené složky. Pro ruční průchod na cílovém počítači použijte
[ověřovací scénář](testing.md). Flutter vyžaduje pro nativní Windows sestavení
Windows hostitele; viz [platformy Flutteru](https://docs.flutter.dev/platform-integration).

V Actions lze ručně spustit workflow **Verify and build Windows** a zapnout
**publish_preview**. Po úspěšných kontrolách vytvoří testovací vydání v
[GitHub Releases](https://github.com/jiri-one/open-ecad/releases) s přímým
odkazem na ZIP a kontrolní součet. Bez této volby zůstává archiv po sedm dní
mezi artefakty daného běhu. Žádný balík se neukládá do historie zdrojů.

Stejný skript lze spustit na vlastním Windows počítači/VM i na Windows runneru
GitHub Actions. Sám nic neodesílá ani nezakládá repozitář; případné nahrání
hotových artefaktů řídí workflow. V Actions přidá do balíku Git commit a odkaz
na odpovídající zdroje z `GITHUB_SERVER_URL`, `GITHUB_REPOSITORY` a `GITHUB_SHA`.
Při místním balení uvádí původ v místních zdrojích a dostupný výchozí commit,
který může obsahovat další nezapsané změny.

## Příprava počítače pro sestavení

- Windows x64, PowerShell 5.1 nebo novější.
- Flutter **3.47.7** / Dart **3.13.5**, Git a `flutter` dostupný v `PATH`.
  Alternativně nastavte `ECAD_FLUTTER_BIN` na úplnou cestu k `flutter.bat`.
- Visual Studio s workloadem **Desktop development with C++**, nástroji MSVC
  pro x64, CMake a Windows SDK. Podrobnosti uvádí
  [příprava Windows pro Flutter](https://docs.flutter.dev/platform-integration/windows/setup).
- Kompletní distribuovatelné knihovny x64 CRT v instalaci Visual Studia,
  obvykle `VC\Redist\MSVC\<verze>\x64\Microsoft.VC143.CRT`. Použijte aktualizovaný
  runtime alespoň tak nový, jako nástroje použité k sestavení. Skript vyhledá
  nainstalované Visual Studio pomocí `vswhere.exe` nebo proměnných prostředí
  Developer PowerShellu a zvolí nejnovější nalezený úplný runtime.

Pro kontrolu vývojového prostředí spusťte `flutter doctor -v`. Skript sám
Visual Studio, runtime instalátor ani Python neinstaluje. `flutter pub get`
a samotný Flutter mohou podle obsahu cache stáhnout své běžné závislosti;
zdrojový projekt se nikam neposílá.

## Sestavení a zabalení

Z kořene projektu v PowerShellu:

```powershell
powershell -NoProfile -File .\scripts\build_windows_portable.ps1
```

Pokud místní zásady blokují spuštění tohoto zkontrolovaného skriptu, lze pro
jediný proces použít `powershell -NoProfile -ExecutionPolicy Bypass -File
.\scripts\build_windows_portable.ps1`; neměňte trvale systémové zásady.

Výstup pro aktuální verzi:

```text
artifacts/open-ecad-windows-native-0.1.0-x64.zip
artifacts/open-ecad-windows-native-0.1.0-x64.zip.sha256
```

Verze se čte z `pubspec.yaml`. ZIP obsahuje jednu stejně pojmenovanou složku.
Existující ZIP ani kontrolní součet se nepřepisují; pro další pokus použijte
například `-OutputDirectory .\artifacts\druhy-pokus`. Originály v `build` ani
uživatelské dokumenty se nemažou. Dočasné soubory vznikají v jedinečné pracovní
složce uvnitř výstupního adresáře a skript odstraní pouze tuto vlastní složku.

Pro zabalení již existujícího release, bez spuštění Flutteru:

```powershell
.\scripts\build_windows_portable.ps1 -SkipBuild
```

Výchozí složka je `build\windows\x64\runner\Release`; jinou zadejte pomocí
`-ReleaseDirectory C:\lokalni-build\Release` společně s `-SkipBuild`.
Skript ověří, že verze EXE odpovídá `pubspec.yaml`; stejná verze ale sama o sobě
nedokazuje aktuálnost zdrojů. Při změně kódu použijte běžné sestavení.
Při ručním sestavování nepřepisujte `--build-name`, jinak kontrola verze selže.

Při nestandardní instalaci Visual Studia lze určit přesnou složku CRT:

```powershell
.\scripts\build_windows_portable.ps1 -SkipBuild -VisualCppRuntimeDirectory 'C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Redist\MSVC\14.44.35211\x64\Microsoft.VC143.CRT'
```

Cesta je příklad; dosaďte existující složku vlastní instalace. Knihovny se
nekopírují ze `System32`, z internetu ani z jiného náhodného programu.
Pokud chybí `msvcp140.dll`, `vcruntime140.dll` nebo `vcruntime140_1.dll`, skript
skončí chybou bez vytvoření ZIPu. Z vybrané složky CRT přibalí všechny DLL,
včetně doplňkových knihoven novějšího runtime. Knihovny leží přímo vedle EXE,
jak popisuje [balení Flutteru do ZIPu](https://docs.flutter.dev/platform-integration/windows/building)
a [lokální nasazení MSVC](https://learn.microsoft.com/en-us/cpp/windows/walkthrough-deploying-a-visual-cpp-application-to-an-application-local-folder).
Aktualizace takto přibaleného runtime se provádí novým balíkem aplikace.
Redistribuce knihoven se řídí [licencí instalovaného Visual Studia a seznamem
distribuovatelných souborů](https://learn.microsoft.com/en-us/cpp/windows/redistributing-visual-cpp-files).

## Obsah a kontrola

Do ZIPu se přidává EXE, všechny release DLL včetně pluginů, celý adresář `data`,
MSVC runtime, `LICENSE`, `THIRD_PARTY_NOTICES.md`, licence Noto Sans a české
`CTETE-NEJDRIV.txt`. Licenční asset Flutteru `NOTICES`/`NOTICES.Z` zůstává v
`data/flutter_assets`. Ukázkový projekt se vytváří přímo v aplikaci přes
**Soubor → Otevřít ukázkový projekt**; žádný externí ukázkový soubor se nebalí
ani není potřeba pro sestavení. Vstupní PDF a projekty, poznámky, analýzy,
uživatelská nastavení a zdrojový strom se nepřidávají.
Případné poskytnutí odpovídajících zdrojů při distribuci řešte v souladu s GPL;
tento skript zdrojový archiv nevytváří ani nikam nic neposílá.

Kontrola vyžaduje x64 PE hlavičky u EXE a DLL, release `app.so`, ICU data,
vygenerované plugin DLL, licenční assety a úplný MSVC runtime. Odmítá odkazy
a neočekávané soubory/složky v release, aby se nové pluginové prostředky tiše
nevynechaly a do balíku omylem nepřibyly dokumenty. Známé vývojové soubory
`.pdb`, `.lib`, `.exp` a `.ilk` se nebalí. Nové uspořádání výstupu Flutteru je
nutné nejprve promítnout do skriptu. Po kompresi se ověří seznam a velikosti
souborů; ZIP se zveřejní v lokálním výstupním adresáři až jako poslední krok.

Kontrolní součet na Windows:

```powershell
Get-FileHash .\artifacts\open-ecad-windows-native-0.1.0-x64.zip -Algorithm SHA256
Get-Content .\artifacts\open-ecad-windows-native-0.1.0-x64.zip.sha256
```

Balík není podepsaný. Kontrolní součet ověřuje shodu přenesených dat, nikoli
digitální podpis autora. Případné hlášení Windows při prvním spuštění je
součástí potřebného ověření na cílovém počítači.

## PDF a první spuštění

Python, PyMuPDF ani `scripts/import_pdf.py` nejsou součástí balíku. Nabídka
**Importovat PDF jako grafiku…** proto bez samostatné instalace převodníku
oznámí, že převodník chybí. Import není skrytou podmínkou spuštění aplikace;
otevření `.oecad`, editace a export PDF/SVG jej nepotřebují.

Pokud je místní převodník připraven zvlášť, před spuštěním EXE lze nastavit
`ECAD_PDF_IMPORTER` na úplnou cestu k `import_pdf.py` a `ECAD_PDF_PYTHON` na
Python s nainstalovaným PyMuPDF. Podrobnosti a samostatná licence převodníku
jsou v [návodu PDF importu](pdf-import.md).

První kontrola skutečného balíku musí proběhnout po rozbalení do nové složky
na Windows, ideálně bez vývojového prostředí a bez předinstalovaného MSVC
runtime: spuštění, otevření ukázky, úprava přístroje a vodiče, zpět/vpřed,
uložení a opětovné otevření `.oecad`, export PDF/SVG a čitelnost při běžném
škálování monitoru. Samotné úspěšné zabalení tyto funkce neověřuje.
