# Open ECAD · prototyp 0.1

Otevřený editor elektrotechnických schémat ve Flutteru. Ruční kreslení i asistent
používají stejné datové jádro a vratné příkazy. Projekt je připravený pro Windows,
Linux, macOS a web; první lokální ověření proběhlo na Linuxu a ve webovém náhledu.

## Spuštění

Aktuální sestavení používá **Flutter 3.47.7 / Dart 3.13.5**. Stejnou verzi Flutteru
používá CI. Skripty upřednostňují již nainstalované SDK z `PATH`.

```bash
./scripts/run.sh
```

Skript najde Flutter v `PATH` nebo obvyklém umístění SDK. Vlastní cestu lze zadat
proměnnou `ECAD_FLUTTER_BIN`. Na Windows v PowerShellu:

```powershell
.\scripts\run.ps1
```

Pro sestavení Windows verze je potřeba Flutter SDK a Visual Studio s workloadem
**Desktop development with C++**. Hotový portable ZIP z GitHub Actions se jen
rozbalí a spustí přes `open_ecad.exe`; Flutter ani Visual Studio příjemce
nepotřebuje. Postup sestavení a obsah balíčku popisuje
[Windows portable build](docs/windows-native-build.md).

Hotový ZIP stáhněte z nejnovějšího
[testovacího vydání pro Windows](https://github.com/jiri-one/open-ecad/releases)
v části **Assets**. Rozbalte celý archiv a spusťte `open_ecad.exe`.
Průběžné balíčky v Actions jsou dostupné jen sedm dní; vydání v Releases
mají trvalý odkaz ke stažení.

Webový náhled bez externího CDN:

```bash
flutter --no-version-check --suppress-analytics pub get
flutter --no-version-check --suppress-analytics build web --release --no-web-resources-cdn --pwa-strategy=none
python3 -m http.server 4173 --bind 127.0.0.1 --directory build/web
```

Potom otevřít [localhost:4173](http://localhost:4173). Mobilní rozhraní není součástí
tohoto prototypu; pracovní plocha se ověřuje od šířky 1024 px.

## Co funguje

- Více současně otevřených projektů a listů v tabech, struktura označení
  `=funkce+umístění-produkt`, devatenáct původních vektorových symbolů, mřížka, výběr,
  hromadné přesouvání, otáčení, duplikace a editace vlastností. Knihovna obsahuje
  mimo jiné pojistku, odpojovač, rozpínací kontakt, spínací tlačítko,
  transformátor, transformátor proudu, ampérmetr, voltmetr a třípólový jistič či
  odpojovač se samostatně připojitelnými póly 1–6. Jde o obecné značky bez nároku
  na shodu s normami.
- Spoje mezi skutečnými vývody; při přesunu nebo otočení sledují přístroj.
  Vodič vzniká kliknutím na první a druhý připojovací bod v režimu **Propojit**.
- Undo/redo, pojmenování listů a projektu, kontrola struktury a nepřipojených bodů.
- Typy listů **vícepólové schéma**, **jednopólové schéma (1P)**, **výstavba
  rozvaděče**, **formulář** a **kusovník**. Typ se volí při vytvoření listu, mění se ve
  vlastnostech listu nebo v nabídce seznamu listů a ukládá se do souboru.
  Seznam listů typ zobrazuje i vyhledává, záhlaví výkresu i exportu ho uvádí.
  Formulář může začít prázdnou tabulkou k ručnímu vyplnění. List kusovníku
  zobrazuje živý stránkovaný materiálový přehled nebo seznam komponent.
- Artikly a fyzické komponenty se sdílenými elektrickými a montážními zobrazeními.
  Kusovník počítá fyzický kus jednou. Výstavba používá rozměry a polohy v mm;
  přístroje se umísťují ručně do společného montážního prostoru.
- Otevřený verzovaný JSON formát `.oecad`, otevření/uložení, místní pracovní kopie
  a obnova po opětovném spuštění. Explicitní uložení zapisuje soubor; automatická
  kopie obsahuje poslední stav každého otevřeného projektu po přibližně 400 ms
  klidu. Uchovává se také deset posledních kopií z předchozích relací; výslovné
  zavření projektu jeho kopii odstraní. Obnova zachová i stav uložení do souboru.
- Vektorový PDF export všech listů, SVG export aktuálního listu a CSV kusovníku,
  s českými texty a zachovaným měřítkem.
- [Místní import PDF](docs/pdf-import.md) jako editovatelné vektory, texty a obrázky
  se skutečnými rozměry listů. Kreslení čar, obdélníků a textů, úpravy vlastností,
  hledání listů. Elektrické vazby ze zdrojového PDF se zatím neobnovují.
- Asistent s náhledem změn ve výkresu, potvrzením nebo odložením a jediným krokem
  undo pro celou dávku. Návrh nad starší revizí se nedá omylem aplikovat.
- **Kontrastní bílý**, **kontrastní černý** a **barevný** motiv. Výchozí je bílý;
  oba kontrastní motivy používají černou a bílou, bez barevného kódování významu.
- Paleta příkazů a klávesové zkratky; levý a pravý panel lze skrýt.
  V levém panelu se přepíná mezi záložkami **Listy**, **Značky**, **Přístroje** a **Artikly**;
  každá využívá celou dostupnou výšku.

Ukázkový projekt **Ukázka · jeden kus, více zobrazení** má pět listů:
cívku, kontakt s opakovaným pohledem, výstavbu a dva živé přehledy. Ukazuje,
že několik zobrazení jednoho přístroje tvoří jediný fyzický kus v kusovníku.
Obsahuje záměrně otevřené připojovací body a neurčený materiál.
Je sestavený přímo z kódu aplikace; uživatelské projektové soubory se nezveřejňují.

Při návrhu výstavby používejte [zásady rozmístění v rozvaděči](docs/cabinet-layout.md):
svorkovnice k místu vstupu kabelů a přístroje s největším ztrátovým teplem
co nejvýše, se zachováním chladicích odstupů a přístupu pro zapojení.

## Asistent: místní příkazy a model

Bez nastavování fungují **místní příkazy**. Je to omezený parser češtiny a
angličtiny, nikoli jazykový model. Vyzkoušet lze například:

```text
Přidej motorový vývod
Vlož svorku
Přidej jistič QF2
Přidej třípólový jistič
Přidej pojistku F3
Duplikuj výběr 3×
Přejmenuj výběr na KM2
Smaž výběr
Zkontroluj projekt
Vrať poslední změnu
```

Pro volné zadání je implementovaný adaptér **Ollama**. V nastavení asistenta se
zadá adresa serveru, jméno již nainstalovaného modelu a zapne používání modelu.
Výchozí adresa je `http://localhost:11434`; předvyplněné `qwen2.5:7b` je pouze
příklad jména, model není součástí aplikace. Síťový požadavek vzniká až odesláním
zadání. Odesílá se zadání, výběr a nejvýše 200 zobrazení z aktuálního listu
s údaji jejich komponent a vývodů. Poznámky komponent se neposílají.

Adaptér používá [Ollama Chat API](https://docs.ollama.com/api/chat) se strukturovanou
JSON odpovědí. Podporuje vložení přístroje či motorového vývodu, práci s výběrem,
undo/redo a kontrolu. Nemá přístup k shellu ani souborovým operacím. Spoje vývodu
sestaví doménové příkazy; obecné plánování libovolného zapojení zatím chybí.

HTTP integrace má automatické testy s řízenými odpověďmi; kvalita skutečného modelu
nebyla v této první verzi ověřena proti běžícímu Ollama serveru. Webové připojení
navíc podléhá pravidlům pro CORS a HTTP/HTTPS; povolení konkrétního původu řeší
`OLLAMA_ORIGINS` podle [Ollama FAQ](https://docs.ollama.com/faq).

## Klávesnice

| Zkratka | Akce |
| --- | --- |
| Ctrl/Cmd + K | Paleta příkazů |
| Ctrl/Cmd + L | Zadání asistentovi |
| Ctrl/Cmd + S / O | Uložit / otevřít projekt |
| Ctrl/Cmd + Z / Shift + Z; Ctrl + Y | Undo / redo |
| Ctrl/Cmd + C / V | Kopírovat výběr / vložit náhled kliknutím; Esc zruší |
| Ctrl/Cmd + A / D | Vybrat vše / duplikovat výběr |
| V / W / H | Výběr / propojení / posun plochy |
| L / B / T | Kreslit čáru / obdélník / text |
| R / Delete | Otočit / odstranit výběr |
| Dvojklik / F4 | Vlastnosti přístroje, odkazu, grafiky nebo spojovacího rohu |
| F | Přejít na protějšek vybraného odkazu nebo odkazu pod myší |
| Home | Přizpůsobit celý list oknu |
| Esc | Ukončit vkládání, spojování nebo náhled; návrh asistenta zůstane k použití |
| Kolečko | Zoom kolem ukazatele |
| Prostřední/pravé tlačítko, případně mezerník + tažení | Posun plochy |
| Enter / Shift + Enter v asistentovi | Odeslat / nový řádek |

## Kopírování a historie úprav

Schránka kresby kopíruje vybrané značky, přístroje, grafiku, spojovací rohy a
vodiče mezi vybranými konci. Ctrl+V zobrazí náhled přichycený ke kurzoru;
pokud kurzor není v kresbě, začne náhled uprostřed pohledu. Kliknutí vloží
celý výběr jako jediný krok undo. Nové objekty zůstanou vybrané a jednotlivý
objekt lze hned upravit dvojklikem nebo F4 (grafika otevře panel vlastností,
spojovací roh nabídne změnu orientace). Ctrl+V lze opakovat.

Pokračovací markery ve stejné otevřené relaci dokumentu zachovají síť, ale mají
nová ID výskytů. V jiném dokumentu nebo po nahrazení dokumentu se sítě importují
s novými ID a nekolidujícími názvy. Přístroje vytvoří nové fyzické kusy; více
vybraných zobrazení stejného kusu zůstane jedním novým kusem v kusovníku.
Čistá grafika zůstává grafikou. Montážní zobrazení a kusovník nejsou pro tuto
schránku podporovány. Zahrnutou komponentu je nutné vybrat i s nadřazeným kusem.
Schránka přenáší nejvýše 500 objektů (včetně vnitřních vodičů) a 2 MiB dat,
bez projektových cest a poznámek. Grafika má limit 10 000 segmentů a obrázky
celkem 16 megapixelů. Při psaní textu fungují běžné textové zkratky.

Tlačítko **Historie úprav** na liště a v paletě zobrazí dostupné kroky undo a
redo, vždy nejbližší krok nahoře. Volba „Vrátit tyto 3 kroky“ zahrne i vybraný
krok; obdobně lze obnovit více kroků. Tooltipy šipek ukazují následující akci.
Historie patří otevřené relaci dokumentu, má omezenou kapacitu a neukládá se do
souboru. Nová úprava zahodí větev redo. Procházení listů není součástí historie.

## Pokračovací odkazy

Tlačítkem **Vložit pokračovací odkaz** zapněte vkládání a klikněte na požadované
místo ve schématu. V dialogu založte pojmenovanou síť nebo výslovně vyberte
existující síť. Výběr sítě, protějšku i cílového listu nabízí hledání podle
názvu, plného označení, struktury nebo ID. Bez dotazu lze procházet strom
struktur; s dotazem se zobrazí přímo výsledky. Šipky mění výběr, Enter jej
potvrdí a Esc dialog zruší. Markery jedné sítě propojují její připojené vodiče; samotný text
ani grafika importovaná z PDF elektrickou vazbu nevytváří.

Dvojklik nebo **F4** otevře vlastnosti vybraného markeru i bez pravého panelu.
Volba **Přejmenovat společnou síť** mění označení všech jejích markerů.
Přepojení na jinou síť mění vazbu pouze upravovaného markeru a jeho vodičů;
dialog tento dopad vysvětluje. **Další marker této sítě…** v panelu vlastností
nabídne list a následně místo pro vložení protějšku. Úpravy lze vrátit přes Undo.

**F** přejde z odkazu pod myší, případně z jednoho vybraného odkazu, na
protějšek v témže projektu. Při více protějšcích vyberte podle plného označení
listu, jeho názvu a souřadnic X/Y (v jednotkách výkresu). Totéž lze provést
kliknutím na cíl v panelu vlastností. Chybějící protějšek zobrazí zprávu.
Skok zachová zoom, zpřístupní cíl a vybere marker, bez změny projektu či Undo.
Viditelný cíl na stejném listu neposouvá pohled. Na Linuxu s X11 se po skoku
přesune také systémový ukazatel myši na cíl, pokud je okno aktivní a ukazatel
uvnitř výkresové aplikace. Úspěch se ověřuje skutečnou polohou ukazatele.
Na Waylandu, ostatních platformách nebo při neověřeném přesunu zůstává
výběr markeru, klávesový fokus a zvýrazněný kreslicí cíl; stavový řádek tyto
výsledky rozlišuje. Přesun se neprovádí během gesta, psaní, dialogu ani při
ztrátě fokusu. Další pohyb myši cílové zvýraznění uvolní.
**Home** přizpůsobí celý list oknu.

F/F4 při psaní textu a během rozpracovaného kreslení nepřepínají scénu.
Dialog otevřený před změnou projektu či listu odmítne zastaralé uložení nebo
skok; otevřete jej znovu z aktuálního výkresu.

## Architektura, kontroly a výkon

Jádro `packages/ecad_core` je čistý Dart bez závislosti na Flutteru. Je použitelné
z GUI, testů i samostatného CLI; [architektura](docs/architecture.md) popisuje
hranice a příkazový protokol. [Dokumentace jádra](packages/ecad_core/README.md)
obsahuje příklady úprav projektu bez grafického rozhraní.

```bash
./scripts/verify.sh
./scripts/run_canvas_benchmark.sh
```

Benchmarky vytvářejí syntetické scény z kódu. Naměřené výstupy zůstávají místní;
nejsou součástí zdrojového repozitáře. Výsledky se posuzují podle prostředí,
nikoli jako záruka výkonu na jiném zařízení.

Repozitář obsahuje zdroje, prostředky aplikace a obecnou dokumentaci. Vstupní
PDF, uživatelské projekty, data pro analýzu nebo trénování ani poznámky k nim
se nezveřejňují. `python3 scripts/check_publication.py` kontroluje sledované
cesty; místní ochranu před pushnutím lze zapnout příkazem
`git config core.hooksPath .githooks`. Obsah změn je stále nutné zkontrolovat.

CI v [GitHub Actions](https://github.com/jiri-one/open-ecad/actions) provádí
statickou analýzu, testy aplikace, jádra a PDF převodníku a sestavuje portable
Windows ZIP. Archiv obsahuje runtime knihovny a data aplikace. Workflow také
ověřuje spuštění rozbaleného programu na Windows runneru; ruční test na cílovém
počítači doplňuje [scénář pro kolegu](docs/testing.md). Linux a web byly ověřeny
místně, macOS zatím nemá potvrzené sestavení.

## Rozsah první verze

Chybí například editor knihovny vlastních značek, rozsáhlý katalog výrobců,
číslování vodičů, kabelové přehledy, DXF a sémantický import QElectroTech/EPLAN.
Vlastní přístroje lze zobrazit blokem s editovatelnými porty. Grafický import
z PDF je popsaný výše. Vodiče mají ortogonální trasu, která vychází
z vývodu směrem ven a obchází obě připojené značky; jiným přístrojům se
automaticky nevyhýbá. Při překrytí připojených značek nemusí jít průchodu
značkou zabránit. Trasování počítá s otáčením po 90°; jiné úhly v externě
vytvořeném souboru nemusí dodržet směr napojení nebo obejít připojenou značku.
Schéma používá výkresové jednotky; fyzické rozměry a montážní polohy jsou v mm
a montážní pohled i export respektují nastavené měřítko.

Kontrola ověřuje konzistenci dat a konektivitu, neposuzuje dimenzování, jištění ani
soulad elektroinstalace s normami. Obnova uchovává pracovní stav po dokumentových
relacích; historie undo ani chat se neukládají. Každá kopie je omezena na 2 MiB a 15 000
grafických objektů; velké importy vyžadují ruční uložení do souboru. Používá se
paměťový dokument a celoprojektová validace; rozsáhlé importy mohou blokovat UI.
Formát se v této rané fázi může měnit bez zachování zpětné kompatibility.

## Licence

Původní kód a symboly: **GPL-3.0-or-later**, viz [LICENSE](LICENSE).
QElectroTech slouží jako funkční reference; tato verze nepřebírá jeho kód ani
knihovnu symbolů. Použité knihovny a fonty zachovávají vlastní licence, viz
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
