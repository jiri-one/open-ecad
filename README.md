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

Webový náhled bez externího CDN:

```bash
flutter --no-version-check --suppress-analytics pub get
flutter --no-version-check --suppress-analytics build web --release --no-web-resources-cdn --pwa-strategy=none
python3 -m http.server 4173 --bind 127.0.0.1 --directory build/web
```

Potom otevřít [localhost:4173](http://localhost:4173). Mobilní rozhraní není součástí
tohoto prototypu; pracovní plocha se ověřuje od šířky 1024 px.

## Co funguje

- Vícelistový projekt, devatenáct původních vektorových symbolů, mřížka, výběr,
  hromadné přesouvání, otáčení, duplikace a editace vlastností. Knihovna obsahuje
  mimo jiné pojistku, odpojovač, rozpínací kontakt, spínací tlačítko,
  transformátor, transformátor proudu, ampérmetr, voltmetr a třípólový jistič či
  odpojovač se samostatně připojitelnými póly 1–6. Jde o obecné značky bez nároku
  na shodu s normami.
- Spoje mezi skutečnými vývody; při přesunu nebo otočení sledují přístroj.
  Vodič vzniká kliknutím na první a druhý připojovací bod v režimu **Propojit**.
- Undo/redo, pojmenování listů a projektu, kontrola struktury a nepřipojených bodů.
- Typy listů **vícepólové schéma**, **jednopólové schéma (1P)**, **výstavba
  rozvaděče** a **formulář**. Typ se volí při vytvoření listu, mění se ve
  vlastnostech listu nebo v nabídce seznamu listů a ukládá se do souboru.
  Seznam listů typ zobrazuje i vyhledává, záhlaví výkresu i exportu ho uvádí.
  Formulář může začít prázdnou tabulkou k ručnímu vyplnění; kusovník ani
  rozmístění přístrojů ve skříni se automaticky negenerují.
- Otevřený verzovaný JSON formát `.oecad`, otevření/uložení, místní pracovní kopie
  a obnova po opětovném spuštění. Explicitní uložení zapisuje soubor; automatická
  kopie obsahuje poslední projekt na daném zařízení, po přibližně 400 ms klidu.
  Obnova zachová i stav uložení do souboru.
- Vektorový PDF export všech listů a SVG export aktuálního listu, s českými texty.
- [Místní import PDF](docs/pdf-import.md) jako editovatelné vektory, texty a obrázky
  se skutečnými rozměry listů. Kreslení čar, obdélníků a textů, úpravy vlastností,
  hledání listů. Elektrické vazby ze zdrojového PDF se zatím neobnovují.
- Asistent s náhledem změn ve výkresu, potvrzením nebo odložením a jediným krokem
  undo pro celou dávku. Návrh nad starší revizí se nedá omylem aplikovat.
- **Kontrastní bílý**, **kontrastní černý** a **barevný** motiv. Výchozí je bílý;
  oba kontrastní motivy používají černou a bílou, bez barevného kódování významu.
- Paleta příkazů a klávesové zkratky; levý a pravý panel lze skrýt.
  V levém panelu se přepíná mezi záložkami **Listy projektu** a **Přístroje**;
  každá využívá celou dostupnou výšku.

Ukázkový projekt **Dílna · pohon odsávání** má silový a ovládací list.
Je ilustrační a obsahuje záměrně otevřený připojovací bod v ovládací části.
Je sestavený přímo z kódu aplikace; uživatelské projektové soubory se nezveřejňují.

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
zadání. Odesílá se zadání, výběr a nejvýše 200 přístrojů z aktuálního listu.

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
| Ctrl/Cmd + A / D | Vybrat vše / duplikovat výběr |
| V / W / H | Výběr / propojení / posun plochy |
| L / B / T | Kreslit čáru / obdélník / text |
| R / Delete | Otočit / odstranit výběr |
| F | Přizpůsobit celý list oknu |
| Esc | Ukončit vkládání, spojování nebo náhled; návrh asistenta zůstane k použití |
| Kolečko | Zoom kolem ukazatele |
| Prostřední/pravé tlačítko, případně mezerník + tažení | Posun plochy |
| Enter / Shift + Enter v asistentovi | Odeslat / nový řádek |

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

Toto je funkční výchozí editor, ne hotová náhrada EPLANu. Chybí například editor
vlastních symbolů, databáze výrobků, obecné vícepólové modely (zatím jen třípólový
jistič a odpojovač), vazby mezi listy, svorkovnice,
kusovníky, číslování vodičů, DXF a sémantický import QElectroTech/EPLAN. Grafický
import z PDF je popsaný výše. Vodiče mají ortogonální trasu, která vychází
z vývodu směrem ven a obchází obě připojené značky; jiným přístrojům se
automaticky nevyhýbá. Při překrytí připojených značek nemusí jít průchodu
značkou zabránit. Trasování počítá s otáčením po 90°; jiné úhly v externě
vytvořeném souboru nemusí dodržet směr napojení nebo obejít připojenou značku.
Souřadnice jsou jednotky
výkresu, zatím bez fyzikálního měřítka pro konstrukční rozměry.

Kontrola ověřuje konzistenci dat a konektivitu, neposuzuje dimenzování, jištění ani
soulad elektroinstalace s normami. Obnova ukládá jeden pracovní dokument, ne historii
undo ani chat. Pracovní kopie je omezena na malé dokumenty do 2 MiB a 15 000
grafických objektů; velké importy vyžadují ruční uložení do souboru. Používá se
paměťový dokument a celoprojektová validace; rozsáhlé importy mohou blokovat UI.
Formát se v této rané fázi může měnit bez zachování zpětné kompatibility.

## Licence

Původní kód a symboly: **GPL-3.0-or-later**, viz [LICENSE](LICENSE).
QElectroTech slouží jako funkční reference; tato verze nepřebírá jeho kód ani
knihovnu symbolů. Použité knihovny a fonty zachovávají vlastní licence, viz
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
