# První ověření na Windows

CI kontroluje sestavení a spuštění rozbaleného Windows balíku. Interaktivní
chování a škálování ověřte na cílovém počítači následujícím průchodem:

1. Spustit `scripts/run.ps1`, případně rozbalit celý release adresář a spustit
   `open_ecad.exe`. Zaznamenat verzi Windows, rozlišení a škálování monitoru.
   Přesunout okno za volné místo horní lišty, maximalizovat dvojklikem a obnovit
   jeho velikost. Ověřit změnu velikosti za okraje a tlačítka okna.
2. Přepnout všechny tři motivy. Ověřit české popisky, ikony a fokus klávesnice při
   100 %, 125 % a 150 % škálování; zkusit e-ink a zmenšení okna na 1024 × 768.
   V levém panelu přepnout mezi **Listy**, **Značky**, **Přístroje** a **Artikly**, vyhledat symbol
   a ověřit zachování filtru po přepnutí tam a zpět.
   Motivy jsou v **Nastavení programu**. V horní liště přepnout sady **Elektro**,
   **Kreslení** a **Úpravy**; při menší šířce jsou nástroje v nabídce sady.
   **Celý list** ve spodním řádku přizpůsobí list s malým okrajem. Při zobrazení
   celého listu otevřít a skrýt boční panely; ručně přiblížený pohled zachová měřítko.
   V **Písmo rozhraní…** vyzkoušet 150 % a 200 %, uložení, zrušení náhledu
   a návrat **Podle systému**. Projít záložky levého panelu, knihovnu značek,
   asistenta, vlastnosti a dialogy; text se nesmí svisle ořezávat. Zvětšení
   písma má zachovat velikost ikon a ručně nastavené přiblížení výkresu.
   Na Linuxu změnit systémovou rodinu i velikost GTK písma za běhu aplikace;
   zkontrolovat také kombinaci se systémovým zvětšením textu.
   Roztáhnout oba boční panely za úchyty u výkresu. Kurzor musí reagovat v celé
   šířce úchytu a zachovat vodorovné šipky po dobu tažení i na hranici rozsahu.
   Zmenšit a znovu zvětšit okno, skrýt a otevřít panely a restartovat aplikaci;
   ověřit zapamatované šířky, dvojklik pro návrat a ovládání úchytu šipkami.
   V seznamu listů ověřit dlouhé názvy na jednom řádku, celé názvy v bublinách
   a společný vodorovný posuvník včetně tažení myší. Vyzkoušet rozsáhlý projekt,
   skok na poslední list, sbalování větví a filtrování po posunutí seznamu.
3. Na ukázce vybrat a přesunout symbol, otočit jej a vrátit změny.
   V každém typu pohledu přiblížit a oddálit kolečkem, posunout výkres a dvojklikem
   kolečka vrátit celý list doprostřed. Vyzkoušet také okraj plochy mimo papír,
   mírný pohyb myši při kliknutí a samostatné tažení bez následného přizpůsobení.
   Přidat svorku a propojit její bod s dalším vývodem. Vybrat a odstranit vodič.
   Dva body bez automatického propojení spojit opakovaně, i v opačném pořadí:
   zůstane jediný vodič a stavový řádek oznámí existující spoj. Jediné Undo spoj
   odstraní, Redo ho obnoví. Spojit také dva horní vývody vedle sebe a zopakovat
   po otočení značek o 90°, 180° a 270°; vodič musí vycházet ven z vývodu a obejít
   obě značky.
4. Projít pět listů ukázky: cívku, kontakt s opakovaným pohledem, výstavbu,
   kusovník a seznam komponent. Ověřit, že relé je stále jeden fyzický kus.
   Přejmenovat list přes nabídku seznamu listů a přidat nový list.
   Při najetí na odkaz přístroje nebo návaznosti vodiče ověřit podtržení bez Ctrl.
   Stisknout a uvolnit Ctrl při stojícím kurzoru; Ctrl+klik přejde na konkrétní
   cíl. Stejně přejít z přístroje v montážním pohledu na určenou hlavní funkci
   a z jednotlivé svorky na její výskyt ve schématu. Chybějící nebo nejednoznačný
   cíl nesmí dostat aktivní odkaz. Běžný klik vybírá, přetažení přesouvá.
   Vytvořit formulář s prázdnou tabulkou, změnit typ listu ve **Vlastnostech**
   a vrátit změnu. V hledání listů zkusit „1P“ a „formular“ bez diakritiky.
5. Zadat `Přidej motorový vývod`. Zkontrolovat náhled, přepnout na původní schéma,
   použít návrh a vrátit ho jediným undo. Esc zavře náhled, návrh ale zůstane
   v panelu asistenta. Vyzkoušet duplikaci vybraných přístrojů.
6. V textovém poli napsat písmena V, W a R a mazat text; kreslicí zkratky nesmějí
   při psaní měnit dokument. Vyzkoušet Ctrl+K, Ctrl+L, Ctrl+Z, Ctrl+Y a Ctrl+S.
   Ctrl+C/V zobrazí náhled; kliknutí jej vloží jako jediný krok historie, Esc
   ho zruší. V **Historii úprav** vrátit a obnovit více kroků.
7. Uložit `.oecad` do cesty s mezerou a diakritikou, otevřít jiný projekt a načíst
   uložený soubor. Zrušit souborový dialog a ověřit, že dokument zůstal zachovaný.
8. Změnit projekt, počkat na uložení pracovní kopie, zavřít a znovu otevřít aplikaci.
   Po uložení do souboru a restartu nesmí záhlaví hlásit neuložené změny.
9. Exportovat PDF a SVG. Ověřit všechny listy a odvozené reportové stránky,
   české texty, konce spojů při zoomu a měřítko montážního pohledu.
10. Spustit `Zkontroluj projekt`; ukázka má otevřené body a neurčený materiál. Kliknutí
    na nález přejde na příslušný přístroj.

Ollama je samostatný volitelný scénář. Ověřit známý nainstalovaný model, nedostupný
server, neznámé jméno modelu a změnu listu během čekání na odpověď. Návrh se musí
buď zobrazit nad správnou revizí, nebo být odmítnut bez změny dokumentu. Zrušený
požadavek ponechá v konverzaci zprávu o zrušení.

Při chybě uložit `.oecad` a zapsat přesné kroky, očekávané/chybné chování, motiv
a škálování. Soubor projektu usnadní reprodukci více než samotný obrázek.

Automatické ověření: `scripts/verify.sh` na Linuxu/macOS nebo odpovídající příkazy
`flutter analyze`, `flutter test` a v `packages/ecad_core` `dart analyze`, `dart test`.
Výkon se měří odděleně pomocí `scripts/run_canvas_benchmark.sh`; nejde o jednotkový
test a nevynucuje univerzální limit FPS.
