# Import PDF do Open ECAD

První verze importu převádí PDF na editovatelnou **grafiku**: samostatné vektorové
cesty, texty a vložené obrázky. Každá stránka vytvoří list se svými rozměry.
Výsledkem je běžný přenositelný `.oecad` ve formátu v2, nikoli odkaz na původní
PDF nebo celostránkový snímek. Soubor lze otevřít i ve webové aplikaci.

Import zatím neobnovuje přístroje, vývody ani elektrické spoje. Nakreslená čára
proto není vodič v elektrickém modelu; kontrola projektu z ní nesestaví síť.
Grafiku lze vybrat, přesunout, otočit, duplikovat, smazat a měnit její vlastnosti.
Texty lze přepsat. Nové čáry, obdélníky a texty se vkládají přes **Kreslit grafiku**
nebo klávesami **L**, **B**, **T**. Existující nástroje přístrojů a vodičů fungují
na stejném listu. Editor jednotlivých uzlů křivek a tvorba vlastních elektrických
symbolů jsou další etapa.

## Instalace místního převodníku

Převod běží na zařízení uživatele pomocí Pythonu a samostatného volitelného
balíčku PyMuPDF. Nepoužívá AI ani vzdálenou službu. Skripty z PDF nespouští.
Z kořenové složky zdrojů na Linuxu/macOS:

```bash
python3 -m venv .venv-pdf
.venv-pdf/bin/python -m pip install -r scripts/import_pdf_requirements.txt
```

Na Windows v PowerShellu:

```powershell
py -3 -m venv .venv-pdf
.\.venv-pdf\Scripts\python.exe -m pip install -r scripts\import_pdf_requirements.txt
```

V desktopové aplikaci zvolte **Soubor → Importovat PDF jako grafiku…**. Po
dokončení uložte projekt jako `.oecad`. Import nahrazuje otevřený dokument a
respektuje dialog neuložených změn. Během převodu původní dokument zůstává v paměti;
pokud jej mezitím změníte, výsledek importu se nepoužije.
Upozornění převodníku se po importu zobrazí v pravém panelu jako zpráva o importu.

Pro vlastní instalaci lze zadat absolutní cestu k Pythonu přes `ECAD_PDF_PYTHON`
a k `scripts/import_pdf.py` přes `ECAD_PDF_IMPORTER`. Samotný sestavený Flutter
program Python neobsahuje. Vedle aplikace musí být dostupný převodník se závislostí,
nebo se použije následující příkaz samostatně.

## Převod z příkazové řádky a web

```bash
./scripts/import_pdf.sh vstup.pdf projekt.oecad --report import-report.json
./scripts/import_pdf.sh vstup.pdf vyber.oecad --pages 1,3-5 --report vyber-report.json
.venv-pdf/bin/python -m unittest discover -s scripts -p 'test_import_pdf.py'
```

Ve Windows použijte místo shellového wrapperu
`.\.venv-pdf\Scripts\python.exe scripts\import_pdf.py` se stejnými argumenty.
Webová aplikace proces Pythonu spustit nemůže; otevřete v ní již převedený `.oecad`
přes běžné **Otevřít projekt**. Zpráva o importu obsahuje počty objektů,
identifikaci zdroje SHA-256 a upozornění na nepřevedené vlastnosti.

## Věrnost a omezení

- Pořadí kreslení zachovává překrývání textu a cest, včetně bílých výplní symbolů.
  Základní barvy, tloušťky, přerušované čáry a natočení jsou součástí formátu.
- Fonty z PDF se nevkládají do projektu. Aplikace používá místní Noto Sans,
  přizpůsobené rozměrům původních textových polí. Jde o náhradu písma, nikoli
  záruku pixelově totožného výstupu.
- Odkazy a záložky PDF nejsou elektrické vazby. Dokument může obsahovat informace
  užitečné pro další rekonstrukci, ale tento import z nich nevytváří netlist.
- Obecné PDF s maskami, složitým ořezáváním nebo jinými nepodporovanými prvky
  vyžaduje kontrolu zprávy a vizuální srovnání. Naskenované PDF zůstane obrázkem;
  tento převodník neobsahuje OCR ani rozpoznávání symbolů.
- Limit dokumentu je 1 024 listů, 500 000 grafických objektů a 128 MiB souboru.
  Dokument i historie úprav jsou v paměti. Velké importy vyžadují dostatek RAM;
  úvodní načtení a export mohou trvat déle.
- Automatická pracovní kopie v nastavení je jen pro malé projekty do 2 MiB
  a 15 000 grafických objektů. Větší projekty **ukládejte ručně do souboru**;
  aplikace tento stav ukazuje v liště. Explicitní uložení zachovává všechny listy.

Formát v2 nadále čte starší soubory v1. Uložením se zapisuje v2, které starší
vydání aplikace nepřečte. Schéma je popsáno v [dokumentaci jádra](../packages/ecad_core/README.md).

Další etapy zahrnují vlastní symboly, vícepólové přístroje, svorkovnice, kabely,
rozpoznávání sítí a vazby mezi listy. Uživatelské vstupní dokumenty ani jejich
převedené projekty nejsou součástí veřejného repozitáře.
