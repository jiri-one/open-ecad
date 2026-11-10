# Import PDF do Open ECAD

První verze importu převádí PDF na editovatelnou **grafiku**: samostatné vektorové
cesty, texty a vložené obrázky. Každá stránka vytvoří list se svými rozměry.
Výsledkem je běžný přenositelný `.oecad` ve formátu v6, nikoli odkaz na původní
PDF nebo celostránkový snímek. Soubor lze otevřít i ve webové aplikaci.

Import zatím neobnovuje přístroje, vývody ani elektrické spoje. Nakreslená čára
proto není vodič v elektrickém modelu; kontrola projektu z ní nesestaví síť.
Grafiku lze vybrat, přesunout, otočit, duplikovat, smazat a měnit její vlastnosti.
Texty lze přepsat. Nové čáry, obdélníky a texty se vkládají přes **Kreslit grafiku**
nebo klávesami **L**, **B**, **T**. Existující nástroje přístrojů a vodičů fungují
na stejném listu. Editor jednotlivých uzlů křivek a tvorba vlastních elektrických
značek pro knihovnu jsou další etapa; bloky s editovatelnými porty již lze vložit.

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

V desktopové aplikaci zvolte **Soubor → Importovat PDF jako grafiku…**. Po převodu
se otevře náhled, ve kterém má každá stránka vlastní volbu:

- **Zachovat původní vzhled** ponechá všechny objekty a nepřidá další rámeček.
- **Použít naši šablonu** nabídne rámečky importu i aktuálního projektu. V náhledu
  označte původní rámeček a razítko k odstranění. Výběr lze vrátit nebo vymazat;
  při překryvu pomůže seznam objektů. Zbývající grafika se rovnoměrně přizpůsobí
  pracovní oblasti nové šablony. Nemá-li stránka původní rámeček, lze pokračovat
  bez označení objektů.

Následuje kontrola výsledku všech stránek. Do výběru se lze vrátit bez opakovaného
zmenšování grafiky; přijetí otevře celý import jako nový projekt. Potom jej uložte
jako `.oecad`. Zrušení náhledu neotevře částečný projekt. Pokud během importu
změníte, zavřete nebo přepnete původní dokument, výsledek se nepoužije.
Upozornění převodníku se po importu zobrazí v pravém panelu jako zpráva o importu.

Výběr odstraňuje celé grafické objekty. Spojenou cestu nebo obrázek nelze v tomto
kroku rozdělit; náhled zvýrazní celý odstraňovaný objekt. Automatické rozpoznání
rámečku, ořezání obsahu ani skrytí pod bílou plochou se neprovádí. Nové listy
přidané do importovaného projektu dědí jeho výchozí rámeček.

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
Samostatný převodník zachovává původní vzhled a nastaví importované listy bez
dalšího rámečku; výběr objektů a náhrada šablonou patří do náhledu v aplikaci.
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
- Typ listu se odhaduje jen z názvu stránky ve stromu záložek podle obecných slov,
  například „výstavba rozvaděče“, „jednopólové“, koncové „- 1P“, „kusovník“
  nebo „seznam“. Název bez takového slova nebo se slovy více typů zůstane bez
  odhadu a list dostane výchozí typ vícepólové schéma. Zpráva o importu uvádí
  počet odhadnutých listů; typ lze kdykoli změnit ve vlastnostech listu.
- Obecné PDF s maskami, složitým ořezáváním nebo jinými nepodporovanými prvky
  vyžaduje kontrolu zprávy a vizuální srovnání. Naskenované PDF zůstane obrázkem;
  tento převodník neobsahuje OCR ani rozpoznávání symbolů.
- Obrázky s krytím pod 50 % nemusí PyMuPDF vrátit ani započítat do zprávy;
  průhledné prvky proto ověřte vizuálně. Vložené JPEG 2000 může knihovna dekódovat
  ještě před kontrolou rozměrů, takže tyto kontroly neomezují celkovou spotřebu RAM.
- Limit dokumentu je 1 024 listů, 500 000 grafických objektů a 128 MiB souboru.
  Z delšího PDF lze přes `--pages` vybrat až 1 024 stránek s čísly do 1 000 000.
  Dokument i historie úprav jsou v paměti. Velké importy vyžadují dostatek RAM;
  úvodní načtení a export mohou trvat déle.
- Importované projekty se ukládají automaticky do místního úložiště včetně
  velkých importů v mezích limitu dokumentu. Stav zápisu je ve spodní liště;
  při chybě zůstane projekt otevřený. Soubor pro přenos vytvoříte přes
  **Vytvořit kopii projektu…**; kopie zachovává všechny listy.

Aplikace čte formáty v4, v5 a v6 a ukládá v6. PDF převodník vytváří v6.
Starší formáty se odmítají bez automatické migrace. Schéma je popsáno v
[dokumentaci jádra](../packages/ecad_core/README.md).

Další etapy importu zahrnují rozpoznávání elektrických značek, sítí a vazeb
mezi listy z PDF. V ručně vytvářeném projektu již existují komponenty,
svorkovnice i mezilistové odkazy. Uživatelské vstupní dokumenty ani jejich
převedené projekty nejsou součástí veřejného repozitáře.
