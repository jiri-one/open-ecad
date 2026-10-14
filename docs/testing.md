# První ověření na Windows

CI kontroluje sestavení a spuštění rozbaleného Windows balíku. Interaktivní
chování a škálování ověřte na cílovém počítači následujícím průchodem:

1. Spustit `scripts/run.ps1`, případně rozbalit celý release adresář a spustit
   `open_ecad.exe`. Zaznamenat verzi Windows, rozlišení a škálování monitoru.
2. Přepnout všechny tři motivy. Ověřit české popisky, ikony a fokus klávesnice při
   100 %, 125 % a 150 % škálování; zkusit e-ink a zmenšení okna na 1024 × 768.
   V levém panelu přepnout mezi **Listy projektu** a **Přístroje**, vyhledat symbol
   a ověřit zachování filtru po přepnutí tam a zpět.
3. Na ukázce vybrat a přesunout několik přístrojů, otočit jistič a vrátit změny.
   Přidat svorku a propojit její bod s dalším vývodem. Vybrat a odstranit vodič.
4. Přepnout na druhý list, dvojklikem přejmenovat jeho záložku, přidat nový list.
5. Zadat `Přidej motorový vývod`. Zkontrolovat náhled, přepnout na původní schéma,
   použít návrh a vrátit ho jediným undo. Vyzkoušet duplikaci vybraných přístrojů.
6. V textovém poli napsat písmena V, W a R a mazat text; kreslicí zkratky nesmějí
   při psaní měnit dokument. Vyzkoušet Ctrl+K, Ctrl+L, Ctrl+Z a Ctrl+S.
7. Uložit `.oecad` do cesty s mezerou a diakritikou, otevřít jiný projekt a načíst
   uložený soubor. Zrušit souborový dialog a ověřit, že dokument zůstal zachovaný.
8. Změnit projekt, počkat na uložení pracovní kopie, zavřít a znovu otevřít aplikaci.
9. Exportovat PDF a SVG. Ověřit dva listy PDF, české texty a konce spojů při zoomu.
10. Spustit `Zkontroluj projekt`; ukázka má upozornění na otevřený bod. Kliknutí
    na nález přejde na příslušný přístroj.

Ollama je samostatný volitelný scénář. Ověřit známý nainstalovaný model, nedostupný
server, neznámé jméno modelu a změnu listu během čekání na odpověď. Návrh se musí
buď zobrazit nad správnou revizí, nebo být odmítnut bez změny dokumentu.

Při chybě uložit `.oecad` a zapsat přesné kroky, očekávané/chybné chování, motiv
a škálování. Soubor projektu usnadní reprodukci více než samotný obrázek.

Automatické ověření: `scripts/verify.sh` na Linuxu/macOS nebo odpovídající příkazy
`flutter analyze`, `flutter test` a v `packages/ecad_core` `dart analyze`, `dart test`.
Výkon se měří odděleně pomocí `scripts/run_canvas_benchmark.sh`; nejde o jednotkový
test a nevynucuje univerzální limit FPS.
