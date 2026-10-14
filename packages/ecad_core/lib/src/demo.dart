// SPDX-License-Identifier: GPL-3.0-or-later
import 'model.dart';

/// Original illustrative diagrams; not a construction-ready circuit design.
abstract final class DemoProject {
  static EcadProject create() => EcadProject(
    id: 'project_demo',
    name: 'Dílna · pohon odsávání',
    description:
        'Ilustrační jednopólové schéma pohonu a samostatná ukázka ovládání 24 V. '
        'Jedna silová čára zastupuje tři fáze. Počty vodičů, úplná ochrana motoru, '
        'blokování a vazby mezi listy nejsou modelovány. Ukázka editoru; '
        'nejde o realizační dokumentaci ani posouzení elektrické bezpečnosti.',
    pages: [
      Sheet(
        id: 'sheet_power',
        name: 'Napájení motoru',
        number: '01',
        devices: const [
          Device(
            id: 'dev_supply',
            kind: DeviceKind.supply,
            designation: '-G1',
            position: Vec2(400, 150),
            description: 'Třífázový přívod zobrazený jednou čárou',
            rating: '3~ 400 V · 50 Hz',
          ),
          Device(
            id: 'dev_breaker',
            kind: DeviceKind.breaker,
            designation: '-Q1',
            position: Vec2(400, 270),
            description: 'Ilustrační jistič přívodu',
            rating: '3P · 10 A',
          ),
          Device(
            id: 'dev_contactor',
            kind: DeviceKind.contactor,
            designation: '-K1',
            position: Vec2(400, 390),
            description: 'Ilustrační třípólový hlavní stykač',
            rating: '3P · AC-3',
          ),
          Device(
            id: 'dev_motor',
            kind: DeviceKind.motor,
            designation: '-M1',
            position: Vec2(400, 550),
            description: 'Motor odsávání dílny',
            rating: '3~ · 2,2 kW',
          ),
          Device(
            id: 'dev_pe_terminal',
            kind: DeviceKind.terminal,
            designation: '-X1',
            position: Vec2(710, 460),
            description: 'Svorka ochranného vodiče',
            rating: 'PE',
          ),
          Device(
            id: 'dev_earth',
            kind: DeviceKind.earth,
            designation: '-PE1',
            position: Vec2(710, 585),
            description: 'Připojení ochranného uzemnění',
          ),
        ],
        wires: [
          _wire('wire_p1', 'dev_supply', 'out', 'dev_breaker', 'in'),
          _wire('wire_p2', 'dev_breaker', 'out', 'dev_contactor', 'in'),
          _wire('wire_p3', 'dev_contactor', 'out', 'dev_motor', 'in'),
          _wire('wire_pe1', 'dev_motor', 'pe', 'dev_pe_terminal', 'in', const [
            Vec2(600, 550),
            Vec2(600, 420),
            Vec2(710, 420),
          ]),
          _wire('wire_pe2', 'dev_pe_terminal', 'out', 'dev_earth', 'in'),
        ],
      ),
      Sheet(
        id: 'sheet_control',
        name: 'Ovládání 24 V',
        number: '02',
        devices: const [
          Device(
            id: 'dev_control_supply',
            kind: DeviceKind.supply,
            designation: '-G2',
            position: Vec2(370, 150),
            description: 'Externí napájení ovládání; zpětný vodič na X2',
            rating: '+24 V DC',
          ),
          Device(
            id: 'dev_enable',
            kind: DeviceKind.contactNo,
            designation: '-S1',
            position: Vec2(370, 280),
            description: 'Aretovaný ovládací spínač v rozepnuté poloze',
            rating: '13–14',
          ),
          Device(
            id: 'dev_coil',
            kind: DeviceKind.coil,
            designation: '-K2',
            position: Vec2(370, 440),
            description:
                'Ukázková cívka relé bez automatického propojení mezi listy',
            rating: '24 V DC',
          ),
          Device(
            id: 'dev_lamp',
            kind: DeviceKind.lamp,
            designation: '-H1',
            position: Vec2(700, 440),
            description: 'Signalizace sepnutí',
            rating: '24 V DC · zelená',
          ),
          Device(
            id: 'dev_return',
            kind: DeviceKind.terminal,
            designation: '-X2',
            position: Vec2(370, 585),
            description:
                'Externí zpětný vodič 0 V; volná svorka tvoří hranici výkresu',
            rating: '0 V DC',
          ),
        ],
        wires: [
          _wire('wire_c1', 'dev_control_supply', 'out', 'dev_enable', 'in'),
          _wire('wire_c2', 'dev_enable', 'out', 'dev_coil', 'a1'),
          _wire('wire_c3', 'dev_enable', 'out', 'dev_lamp', 'in', const [
            Vec2(370, 350),
            Vec2(700, 350),
          ]),
          _wire('wire_c4', 'dev_coil', 'a2', 'dev_return', 'in'),
          _wire('wire_c5', 'dev_lamp', 'out', 'dev_return', 'in', const [
            Vec2(700, 520),
            Vec2(370, 520),
          ]),
        ],
      ),
    ],
  );

  static Wire _wire(
    String id,
    String fromDevice,
    String fromPort,
    String toDevice,
    String toPort, [
    List<Vec2> waypoints = const [],
  ]) => Wire(
    id: id,
    from: TerminalRef(deviceId: fromDevice, portId: fromPort),
    to: TerminalRef(deviceId: toDevice, portId: toPort),
    waypoints: waypoints,
  );
}
