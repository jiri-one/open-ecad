import 'package:ecad_core/ecad_core.dart';

String diagnosticText(EcadProject project, Diagnostic diagnostic) {
  final component = project.componentById(diagnostic.componentId ?? '');
  final article = project.articleById(diagnostic.articleId ?? '');
  final subject =
      (component == null
          ? null
          : ProjectResolver(project).fullDesignation(component)) ??
      (component?.description.isNotEmpty == true
          ? component!.description
          : null) ??
      article?.name;
  final text = diagnosticCodeText(diagnostic.code, diagnostic.message);
  final address = [
    if (subject != null && subject.isNotEmpty) subject,
    if (diagnostic.sheetId case final id?)
      'list ${project.sheetById(id) == null ? id : fullPageDesignation(project.sheetById(id)!)}',
    if (diagnostic.deviceId case final id?) id,
  ];
  return address.isEmpty ? text : '${address.join(' · ')}: $text';
}

String diagnosticCodeText(String code, String fallback) => switch (code) {
  'unassigned_article' => 'Chybí přiřazený artikl.',
  'incomplete_article' => 'Artikl nemá vyplněného výrobce nebo objednací kód.',
  'unknown_quantity' => 'Množství materiálu není určeno.',
  'missing_mounting_dimensions' => 'Pro montáž chybí známá šířka a výška v mm.',
  'placement_outside_surface' => 'Komponenta přesahuje montážní plochu.',
  'mounting_overlap' => 'Montážní obrysy komponent se překrývají.',
  'repeated_wiring_terminal' => 'Vývod má více zapojovacích zobrazení.',
  'unconnected_port' => 'Vývod není připojen vodičem.',
  'unconnected_continuation' => 'Pokračování není připojeno vodičem.',
  'orphan_continuation' => 'Pokračování nemá protější cíl.',
  'invalid_id' => 'Identifikátor má neplatný formát.',
  'duplicate_id' => 'Identifikátor je v projektu použit vícekrát.',
  'invalid_metadata' =>
    'Vyplňte povinné označení nebo název a dodržte délku textových polí.',
  'invalid_revision' => 'Revize projektu není platná.',
  'invalid_page_count' => 'Projekt musí obsahovat alespoň jeden list.',
  'limit_exceeded' => 'Projekt překročil povolený rozsah dat.',
  'duplicate_designation' => 'Označení komponenty je již použité. Zvolte jiné.',
  'procurement_cycle' => 'Odkazy na součást dodávky nesmějí tvořit kruh.',
  'duplicate_link_label' =>
    'Název pokračování je již použitý. Vyberte existující vazbu.',
  'duplicate_sheet_number' => 'Číslo listu je již použité.',
  'reserved_sheet_number' =>
    'Číslo listu je rezervované pro další stranu reportu.',
  'invalid_dimensions' => 'Rozměry musí být kladná konečná čísla v mm.',
  'invalid_source_url' =>
    'Zdroj musí být adresa HTTP nebo HTTPS bez přihlašovacích údajů.',
  'invalid_quantity' =>
    'Množství musí být kladné, nebo prázdné pro neurčené množství.',
  'physical_quantity' => 'Jeden fyzický přístroj představuje právě 1 ks.',
  'missing_article' => 'Přiřazený artikl v projektu neexistuje.',
  'unit_mismatch' => 'Jednotka artiklu se liší od jednotky materiálu.',
  'invalid_procurement' =>
    'Součást dodávky musí odkazovat na jinou existující komponentu.',
  'invalid_electrical_model' =>
    'Elektrické funkce může mít pouze fyzický kus určený k instalaci.',
  'duplicate_terminal_designation' =>
    'Označení vývodů musí být v rámci komponenty jedinečná.',
  'invalid_function_terminals' =>
    'Funkce musí odkazovat na různé existující vývody svého kusu.',
  'invalid_geometry' => 'Poloha, rozměry, měřítko nebo natočení nejsou platné.',
  'missing_component' => 'Odkazovaná komponenta v projektu neexistuje.',
  'invalid_occurrence' =>
    'Zobrazení ve schématu vyžaduje fyzický kus určený k instalaci.',
  'missing_function' => 'Zvolená elektrická funkce u komponenty neexistuje.',
  'duplicate_main_function' => 'Přístroj může mít jen jednu hlavní funkci.',
  'logical_symbol' => 'Pro ochranný potenciál použijte značku pokračování.',
  'invalid_port_binding' => 'Každý port musí odpovídat vývodu vybrané funkce.',
  'invalid_port' =>
    'Port není platný nebo na odstraněný port stále vede vodič. Nejprve vodič odpojte.',
  'invalid_port_geometry' =>
    'Porty musí mít různé polohy uvnitř zvolené hrany.',
  'incompatible_sheet_content' =>
    'Obsah listu neodpovídá zvolenému typu. Nejprve obsah přesuňte nebo odeberte.',
  'missing_layout' => 'Montážní plocha v projektu neexistuje.',
  'viewport_outside_sheet' => 'Výřez montážního pohledu přesahuje papír.',
  'missing_link' => 'Vazba pokračování v projektu neexistuje.',
  'same_endpoint' => 'Vodič nemůže spojovat vývod se sebou samým.',
  'missing_device' => 'Konec vodiče odkazuje na neexistující výskyt na listu.',
  'reference_endpoint' => 'Referenční zobrazení nemůže přijímat vodiče.',
  'missing_marker' =>
    'Konec vodiče odkazuje na neexistující pokračování na listu.',
  'invalid_corner_endpoint' =>
    'Konec vodiče odkazuje na neexistující port spojovacího rohu.',
  'corner_clearance' =>
    'Rameno spojovacího rohu se nevejde před konec vodiče nebo zalomení. Posuňte roh dále.',
  'wire_waypoints_bypassed' =>
    'Trasa obchází některé ruční body kvůli poloze vývodů; uložené body zůstaly zachovány.',
  'duplicate_connection' => 'Tyto koncové body již spojuje vodič.',
  'invalid_surface_component' =>
    'Montážní plocha musí odkazovat na fyzický kus určený k instalaci.',
  'invalid_placement' =>
    'Umístit lze fyzický kus určený k instalaci, odlišný od montážní plochy.',
  'duplicate_placement' =>
    'Kus je již umístěný. Pro další pohled vyberte tutéž montážní plochu.',
  'article_unit_in_use' =>
    'Jednotku používaného artiklu nelze změnit. Vytvořte nový artikl.',
  'stale_revision' =>
    'Projekt se mezitím změnil. Zopakujte úpravu nad aktuální verzí.',
  'missing_reference' =>
    'Položka neexistuje nebo ji stále používá jiná část projektu.',
  _ => fallback,
};
