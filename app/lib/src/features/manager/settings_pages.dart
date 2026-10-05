import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';
import 'package:pontomax_core/pontomax_core.dart';

import '../../services/location_service.dart';
import '../../state/data.dart';
import '../../state/session.dart';
import '../../theme.dart';
import '../../widgets/common.dart';

// ---------------------------------------------------------------------------
// Feriados
// ---------------------------------------------------------------------------

class HolidaysPage extends ConsumerStatefulWidget {
  const HolidaysPage({super.key});
  @override
  ConsumerState<HolidaysPage> createState() => _HolidaysPageState();
}

class _HolidaysPageState extends ConsumerState<HolidaysPage> {
  int _year = DateTime.now().year;

  static const _scopes = {
    'national': 'Nacional',
    'state': 'Estadual',
    'city': 'Municipal',
    'company': 'Empresa',
  };

  Future<void> _edit([HolidayEntity? h]) async {
    final name = TextEditingController(text: h?.name);
    var date = h?.date ?? LocalDate(_year, 1, 1);
    var scope = h?.scope ?? 'city';
    var recurring = h?.recurring ?? false;
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (c, set) => AlertDialog(
          title: Text(h == null ? 'Novo feriado' : 'Editar feriado'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: name,
                decoration: const InputDecoration(labelText: 'Nome'),
              ),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: () async {
                  final d = await showDatePicker(
                    context: c,
                    initialDate: date.toDateTime().toLocal(),
                    firstDate: DateTime(2020),
                    lastDate: DateTime(2040),
                  );
                  if (d != null) {
                    set(() => date = LocalDate(d.year, d.month, d.day));
                  }
                },
                icon: const Icon(Icons.event),
                label: Text(date.toBr()),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                initialValue: scope,
                decoration: const InputDecoration(labelText: 'Abrangência'),
                items: [
                  for (final e in _scopes.entries)
                    DropdownMenuItem(value: e.key, child: Text(e.value)),
                ],
                onChanged: (v) => set(() => scope = v ?? scope),
              ),
              CheckboxListTile(
                value: recurring,
                onChanged: (v) => set(() => recurring = v ?? false),
                title: const Text('Repete todo ano'),
                contentPadding: EdgeInsets.zero,
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(c, false),
              child: const Text('Cancelar'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(c, true),
              child: const Text('Salvar'),
            ),
          ],
        ),
      ),
    );
    if (ok != true || !mounted) return;
    final body = {
      'name': name.text.trim(),
      'date': date.toString(),
      'scope': scope,
      'recurring': recurring,
    };
    final api = ref.read(apiProvider);
    await runAction(
      context,
      () => h == null
          ? api.post('/holidays', body)
          : api.put('/holidays/${h.id}', body),
      success: 'Feriado salvo',
    );
    ref.invalidate(holidaysProvider);
  }

  @override
  Widget build(BuildContext context) {
    final data = ref.watch(holidaysProvider(_year));
    final api = ref.read(apiProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Feriados'),
        actions: [
          IconButton(
            onPressed: () => setState(() => _year--),
            icon: const Icon(Icons.chevron_left),
          ),
          Center(
            child: Text(
              '$_year',
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
          ),
          IconButton(
            onPressed: () => setState(() => _year++),
            icon: const Icon(Icons.chevron_right),
          ),
          TextButton.icon(
            onPressed: () async {
              final r = await runAction(
                context,
                () => api.post('/holidays/import-national', {'year': _year}),
              );
              if (r != null && context.mounted) {
                showSnack(
                  context,
                  '${(r as Map)['imported']} feriado(s) importado(s)',
                );
              }
              ref.invalidate(holidaysProvider);
            },
            icon: const Icon(Icons.download_outlined),
            label: const Text('Importar nacionais'),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _edit,
        icon: const Icon(Icons.add),
        label: const Text('Feriado'),
      ),
      body: AsyncView(
        value: data,
        onRetry: () => ref.invalidate(holidaysProvider(_year)),
        builder: (list) => list.isEmpty
            ? const EmptyState(
                icon: Icons.event_outlined,
                title: 'Nenhum feriado cadastrado',
              )
            : ListView(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
                children: [
                  Constrained(
                    maxWidth: 800,
                    child: Card(
                      child: Column(
                        children: [
                          for (final h in list)
                            ListTile(
                              leading: CircleAvatar(
                                child: Text(
                                  h.date.day.toString().padLeft(2, '0'),
                                ),
                              ),
                              title: Text(h.name),
                              subtitle: Text(
                                '${h.date.toBr()} • ${_scopes[h.scope] ?? h.scope}${h.recurring ? ' • anual' : ''}',
                              ),
                              onTap: () => _edit(h),
                              trailing: IconButton(
                                icon: const Icon(Icons.delete_outline),
                                onPressed: () async {
                                  if (!await confirm(
                                    context,
                                    'Excluir feriado',
                                    h.name,
                                    destructive: true,
                                  )) {
                                    return;
                                  }
                                  await api.delete('/holidays/${h.id}');
                                  ref.invalidate(holidaysProvider);
                                },
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Perímetros (geocercas)
// ---------------------------------------------------------------------------

class GeofencesPage extends ConsumerWidget {
  const GeofencesPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final data = ref.watch(geofencesProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Perímetros de marcação')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => Navigator.of(
          context,
        ).push(MaterialPageRoute(builder: (_) => const GeofenceEditorPage())),
        icon: const Icon(Icons.add_location_alt_outlined),
        label: const Text('Novo perímetro'),
      ),
      body: AsyncView(
        value: data,
        onRetry: () => ref.invalidate(geofencesProvider),
        builder: (list) => list.isEmpty
            ? const EmptyState(
                icon: Icons.share_location_outlined,
                title: 'Nenhum perímetro',
                message: 'Cadastre os locais de trabalho para validar a localização das marcações.',
              )
            : ListView(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
                children: [
                  Constrained(
                    maxWidth: 900,
                    child: Column(
                      children: [
                        for (final g in list)
                          Card(
                            child: ListTile(
                              leading: Icon(
                                Icons.location_on,
                                color: g.active
                                    ? AppColors.accent
                                    : AppColors.muted,
                              ),
                              title: Text(g.name),
                              subtitle: Text(
                                '${g.address.isEmpty ? '${g.lat.toStringAsFixed(5)}, ${g.lng.toStringAsFixed(5)}' : g.address} • raio ${g.radius.round()} m',
                              ),
                              trailing: const Icon(Icons.chevron_right),
                              onTap: () => Navigator.of(context).push(
                                MaterialPageRoute(
                                  builder: (_) =>
                                      GeofenceEditorPage(geofence: g),
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}

class GeofenceEditorPage extends ConsumerStatefulWidget {
  final GeofenceEntity? geofence;
  const GeofenceEditorPage({super.key, this.geofence});
  @override
  ConsumerState<GeofenceEditorPage> createState() => _GeofenceEditorPageState();
}

class _GeofenceEditorPageState extends ConsumerState<GeofenceEditorPage> {
  late final _name = TextEditingController(text: widget.geofence?.name);
  late final _address = TextEditingController(text: widget.geofence?.address);
  late LatLng _center = widget.geofence == null
      ? const LatLng(-23.5505, -46.6333)
      : LatLng(widget.geofence!.lat, widget.geofence!.lng);
  late double _radius = widget.geofence?.radius ?? 150;
  late bool _active = widget.geofence?.active ?? true;
  final _map = MapController();

  Future<void> _useMyLocation() async {
    try {
      final loc = await LocationService.current(required: true);
      if (loc == null) return;
      setState(() => _center = LatLng(loc.lat, loc.lng));
      _map.move(_center, 17);
    } catch (e) {
      if (mounted) showSnack(context, errorMessage(e), error: true);
    }
  }

  Future<void> _save() async {
    if (_name.text.trim().isEmpty) {
      showSnack(context, 'Informe o nome', error: true);
      return;
    }
    final body = {
      'name': _name.text.trim(),
      'address': _address.text.trim(),
      'lat': _center.latitude,
      'lng': _center.longitude,
      'radius': _radius,
      'active': _active,
    };
    final api = ref.read(apiProvider);
    final r = await runAction(
      context,
      () => widget.geofence == null
          ? api.post('/geofences', body)
          : api.put('/geofences/${widget.geofence!.id}', body),
      success: 'Perímetro salvo',
    );
    if (r != null && mounted) {
      ref.invalidate(geofencesProvider);
      Navigator.pop(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    final form = Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: _name,
            decoration: const InputDecoration(
              labelText: 'Nome (ex.: Matriz, Obra Centro)',
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _address,
            decoration: const InputDecoration(
              labelText: 'Endereço (referência)',
            ),
          ),
          const SizedBox(height: 12),
          Text(
            'Raio: ${_radius.round()} m',
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
          Slider(
            value: _radius,
            min: 30,
            max: 2000,
            divisions: 197,
            label: '${_radius.round()} m',
            onChanged: (v) => setState(() => _radius = v),
          ),
          SwitchListTile(
            value: _active,
            onChanged: (v) => setState(() => _active = v),
            title: const Text('Ativo'),
            contentPadding: EdgeInsets.zero,
          ),
          Text(
            'Centro: ${_center.latitude.toStringAsFixed(6)}, ${_center.longitude.toStringAsFixed(6)}',
            style: const TextStyle(color: AppColors.muted, fontSize: 12),
          ),
          const SizedBox(height: 4),
          const Text(
            'Toque no mapa para posicionar o centro do perímetro.',
            style: TextStyle(color: AppColors.muted, fontSize: 12),
          ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: _useMyLocation,
            icon: const Icon(Icons.my_location),
            label: const Text('Usar minha localização'),
          ),
        ],
      ),
    );
    final map = FlutterMap(
      mapController: _map,
      options: MapOptions(
        initialCenter: _center,
        initialZoom: 16,
        onTap: (_, p) => setState(() => _center = p),
      ),
      children: [
        TileLayer(
          urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
          userAgentPackageName: 'app.pontomax',
        ),
        CircleLayer(
          circles: [
            CircleMarker(
              point: _center,
              radius: _radius,
              useRadiusInMeter: true,
              color: AppColors.brand.withValues(alpha: 0.15),
              borderColor: AppColors.brand,
              borderStrokeWidth: 2,
            ),
          ],
        ),
        MarkerLayer(
          markers: [
            Marker(
              point: _center,
              width: 40,
              height: 40,
              child: const Icon(
                Icons.location_on,
                color: AppColors.danger,
                size: 40,
              ),
            ),
          ],
        ),
        const RichAttributionWidget(
          attributions: [TextSourceAttribution('© OpenStreetMap')],
        ),
      ],
    );
    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.geofence == null ? 'Novo perímetro' : 'Editar perímetro',
        ),
        actions: [
          if (widget.geofence != null)
            IconButton(
              icon: const Icon(Icons.delete_outline),
              onPressed: () async {
                if (!await confirm(
                  context,
                  'Excluir perímetro',
                  'Deseja excluir "${widget.geofence!.name}"?',
                  destructive: true,
                )) {
                  return;
                }
                await ref
                    .read(apiProvider)
                    .delete('/geofences/${widget.geofence!.id}');
                ref.invalidate(geofencesProvider);
                if (context.mounted) Navigator.pop(context);
              },
            ),
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: FilledButton(onPressed: _save, child: const Text('Salvar')),
          ),
        ],
      ),
      body: isWide(context)
          ? Row(
              children: [
                SizedBox(width: 380, child: SingleChildScrollView(child: form)),
                Expanded(child: map),
              ],
            )
          : Column(
              children: [
                Expanded(child: map),
                SingleChildScrollView(child: form),
              ],
            ),
    );
  }
}

// ---------------------------------------------------------------------------
// Quiosques (dispositivos)
// ---------------------------------------------------------------------------

class DevicesPage extends ConsumerWidget {
  const DevicesPage({super.key});

  Future<void> _showCode(BuildContext context, Device d) => showDialog(
    context: context,
    builder: (c) => AlertDialog(
      title: Text('Ativar "${d.name}"'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text(
            'No tablet, abra o PontoMax, toque em "Usar como quiosque" e informe o código:',
          ),
          const SizedBox(height: 16),
          SelectableText(
            d.activationCode ?? '',
            style: const TextStyle(
              fontSize: 32,
              fontWeight: FontWeight.w900,
              letterSpacing: 6,
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            'O código vale por 7 dias e só pode ser usado uma vez.',
            style: TextStyle(color: AppColors.muted, fontSize: 12),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () =>
              Clipboard.setData(ClipboardData(text: d.activationCode ?? '')),
          child: const Text('Copiar'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(c),
          child: const Text('OK'),
        ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final data = ref.watch(devicesProvider);
    final fences = ref.watch(geofencesProvider).value ?? const [];
    final api = ref.read(apiProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Quiosques (tablets de ponto)')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () async {
          final name = await promptText(
            context,
            'Novo quiosque',
            label: 'Nome (ex.: Tablet da recepção)',
          );
          if (name == null || !context.mounted) return;
          String? fence;
          if (fences.isNotEmpty) {
            fence = await showDialog<String>(
              context: context,
              builder: (c) => SimpleDialog(
                title: const Text('Local do quiosque'),
                children: [
                  SimpleDialogOption(
                    onPressed: () => Navigator.pop(c),
                    child: const Text('Sem perímetro'),
                  ),
                  for (final f in fences)
                    SimpleDialogOption(
                      onPressed: () => Navigator.pop(c, f.id),
                      child: Text(f.name),
                    ),
                ],
              ),
            );
          }
          if (!context.mounted) return;
          final r = await runAction(
            context,
            () => api.post('/devices', {'name': name, 'geofence_id': ?fence}),
          );
          ref.invalidate(devicesProvider);
          if (r != null && context.mounted) {
            await _showCode(context, Device.fromJson((r as Map).cast()));
          }
        },
        icon: const Icon(Icons.add),
        label: const Text('Novo quiosque'),
      ),
      body: AsyncView(
        value: data,
        onRetry: () => ref.invalidate(devicesProvider),
        builder: (list) => list.isEmpty
            ? const EmptyState(
                icon: Icons.tablet_android_outlined,
                title: 'Nenhum quiosque',
                message: 'Transforme um tablet ou computador em relógio de ponto coletivo com PIN, crachá ou QR Code.',
              )
            : ListView(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
                children: [
                  Constrained(
                    maxWidth: 900,
                    child: Column(
                      children: [
                        for (final d in list)
                          Card(
                            child: ListTile(
                              leading: Icon(
                                Icons.tablet_android,
                                color: d.active
                                    ? AppColors.brand
                                    : AppColors.muted,
                              ),
                              title: Text(d.name),
                              subtitle: Text(
                                [
                                  d.geofenceName ?? 'Sem perímetro',
                                  if (d.activationCode != null)
                                    'Aguardando ativação',
                                  if (d.lastSeenAt != null)
                                    'visto ${relativeTime(d.lastSeenAt!)}',
                                  if (d.platform != null) d.platform!,
                                ].join(' • '),
                              ),
                              trailing: PopupMenuButton<String>(
                                onSelected: (v) async {
                                  if (v == 'code') {
                                    if (d.activationCode != null) {
                                      await _showCode(context, d);
                                    } else {
                                      final r = await runAction(
                                        context,
                                        () => api.post(
                                          '/devices/${d.id}/activation',
                                        ),
                                      );
                                      ref.invalidate(devicesProvider);
                                      if (r != null && context.mounted) {
                                        await _showCode(
                                          context,
                                          Device.fromJson((r as Map).cast()),
                                        );
                                      }
                                    }
                                  } else if (v == 'toggle') {
                                    await runAction(
                                      context,
                                      () => api.put('/devices/${d.id}', {
                                        'active': !d.active,
                                      }),
                                    );
                                    ref.invalidate(devicesProvider);
                                  } else if (v == 'delete') {
                                    if (!await confirm(
                                      context,
                                      'Excluir quiosque',
                                      d.name,
                                      destructive: true,
                                    )) {
                                      return;
                                    }
                                    await api.delete('/devices/${d.id}');
                                    ref.invalidate(devicesProvider);
                                  }
                                },
                                itemBuilder: (_) => [
                                  PopupMenuItem(
                                    value: 'code',
                                    child: Text(
                                      d.activationCode != null
                                          ? 'Ver código de ativação'
                                          : 'Gerar novo código (reativar)',
                                    ),
                                  ),
                                  PopupMenuItem(
                                    value: 'toggle',
                                    child: Text(
                                      d.active ? 'Desativar' : 'Ativar',
                                    ),
                                  ),
                                  const PopupMenuItem(
                                    value: 'delete',
                                    child: Text('Excluir'),
                                  ),
                                ],
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Departamentos e cargos
// ---------------------------------------------------------------------------

class CatalogsPage extends ConsumerWidget {
  const CatalogsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) => DefaultTabController(
    length: 2,
    child: Scaffold(
      appBar: AppBar(
        title: const Text('Departamentos e cargos'),
        bottom: const TabBar(
          tabs: [
            Tab(text: 'Departamentos'),
            Tab(text: 'Cargos'),
          ],
        ),
      ),
      body: const TabBarView(
        children: [
          _NamedList(path: '/departments', label: 'departamento'),
          _NamedList(path: '/positions', label: 'cargo'),
        ],
      ),
    ),
  );
}

class _NamedList extends ConsumerWidget {
  final String path;
  final String label;
  const _NamedList({required this.path, required this.label});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final data = path == '/departments'
        ? ref.watch(departmentsProvider)
        : ref.watch(positionsProvider);
    final api = ref.read(apiProvider);
    void reload() {
      ref.invalidate(departmentsProvider);
      ref.invalidate(positionsProvider);
    }

    return Scaffold(
      floatingActionButton: FloatingActionButton(
        onPressed: () async {
          final name = await promptText(context, 'Novo $label', label: 'Nome');
          if (name == null || !context.mounted) return;
          await runAction(context, () => api.post(path, {'name': name}));
          reload();
        },
        child: const Icon(Icons.add),
      ),
      body: AsyncView(
        value: data,
        builder: (list) => list.isEmpty
            ? EmptyState(
                icon: Icons.account_tree_outlined,
                title: 'Nenhum $label cadastrado',
              )
            : ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  Constrained(
                    maxWidth: 700,
                    child: Card(
                      child: Column(
                        children: [
                          for (final e in list)
                            ListTile(
                              title: Text(e.name),
                              subtitle: Text('${e.count} colaborador(es)'),
                              onTap: () async {
                                final name = await promptText(
                                  context,
                                  'Renomear',
                                  initial: e.name,
                                );
                                if (name == null || !context.mounted) return;
                                await runAction(
                                  context,
                                  () =>
                                      api.put('$path/${e.id}', {'name': name}),
                                );
                                reload();
                              },
                              trailing: IconButton(
                                icon: const Icon(Icons.delete_outline),
                                onPressed: () async {
                                  if (!await confirm(
                                    context,
                                    'Excluir',
                                    'Excluir "${e.name}"?',
                                    destructive: true,
                                  )) {
                                    return;
                                  }
                                  if (!context.mounted) return;
                                  await runAction(
                                    context,
                                    () => api.delete('$path/${e.id}'),
                                  );
                                  reload();
                                },
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Empresa e regras
// ---------------------------------------------------------------------------

class CompanyPage extends ConsumerStatefulWidget {
  const CompanyPage({super.key});
  @override
  ConsumerState<CompanyPage> createState() => _CompanyPageState();
}

class _CompanyPageState extends ConsumerState<CompanyPage> {
  final _c = <String, TextEditingController>{};
  CompanySettings? _settings;
  int _offset = -180;
  bool _loaded = false;

  static const _offsets = {
    -120: 'UTC-02 (Fernando de Noronha)',
    -180: 'UTC-03 (Brasília)',
    -240: 'UTC-04 (Amazonas, MT, MS, RO, RR)',
    -300: 'UTC-05 (Acre)',
  };

  TextEditingController _ctl(String k) =>
      _c.putIfAbsent(k, TextEditingController.new);

  @override
  void initState() {
    super.initState();
    ref.read(apiProvider).getMap('/company').then((j) {
      final c = Company.fromJson(j);
      if (!mounted) return;
      setState(() {
        _ctl('name').text = c.name;
        _ctl('legal_name').text = c.legalName;
        _ctl('document').text = Documents.formatDocument(c.document);
        _ctl('cno_caepf').text = c.cnoCaepf;
        _ctl('address').text = c.address;
        _ctl('city').text = c.city;
        _ctl('state').text = c.state;
        _ctl('inpi').text = c.settings.inpiNumber;
        _offset = c.utcOffsetMinutes;
        _settings = c.settings;
        _loaded = true;
      });
    });
  }

  Future<void> _saveCompany() async {
    await runAction(
      context,
      () => ref.read(apiProvider).put('/company', {
        for (final k in [
          'name',
          'legal_name',
          'document',
          'cno_caepf',
          'address',
          'city',
          'state',
        ])
          k: _ctl(k).text.trim(),
        'utc_offset_minutes': _offset,
      }),
      success: 'Dados da empresa salvos',
    );
    await ref.read(sessionProvider.notifier).refreshMe();
  }

  Future<void> _saveSettings(CompanySettings s) async {
    setState(() => _settings = s);
    await runAction(
      context,
      () => ref.read(apiProvider).put('/company/settings', s.toJson()),
    );
    await ref.read(sessionProvider.notifier).refreshMe();
  }

  CompanySettings _copy({
    bool? requirePhoto,
    bool? requireGeofence,
    bool? allowOffline,
    bool? allowMobile,
    bool? allowWeb,
    bool? allowDesktop,
    int? minMinutesBetweenPunches,
    int? closingDay,
    String? inpiNumber,
    bool? reminders,
    bool? showBankToEmployee,
    bool? requireTimesheetSignature,
    String? managerScope,
  }) {
    final s = _settings!;
    return CompanySettings(
      requirePhoto: requirePhoto ?? s.requirePhoto,
      requireGeofence: requireGeofence ?? s.requireGeofence,
      allowOffline: allowOffline ?? s.allowOffline,
      allowMobile: allowMobile ?? s.allowMobile,
      allowWeb: allowWeb ?? s.allowWeb,
      allowDesktop: allowDesktop ?? s.allowDesktop,
      faceCheck: s.faceCheck,
      minMinutesBetweenPunches:
          minMinutesBetweenPunches ?? s.minMinutesBetweenPunches,
      closingDay: closingDay ?? s.closingDay,
      inpiNumber: inpiNumber ?? s.inpiNumber,
      reminders: reminders ?? s.reminders,
      showBankToEmployee: showBankToEmployee ?? s.showBankToEmployee,
      requireTimesheetSignature:
          requireTimesheetSignature ?? s.requireTimesheetSignature,
      managerScope: managerScope ?? s.managerScope,
    );
  }

  @override
  Widget build(BuildContext context) {
    final me = ref.watch(meProvider);
    if (!_loaded) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    final s = _settings!;
    final admin = me.isAdmin;
    Widget field(String k, String label, {String? helper}) => Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: TextField(
        controller: _ctl(k),
        enabled: admin,
        decoration: InputDecoration(labelText: label, helperText: helper),
      ),
    );
    return Scaffold(
      appBar: AppBar(title: const Text('Empresa e regras')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Constrained(
            maxWidth: 820,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (!admin)
                  const Card(
                    child: ListTile(
                      leading: Icon(Icons.lock_outline),
                      title: Text(
                        'Somente administradores podem alterar estas configurações.',
                      ),
                    ),
                  ),
                const SectionTitle(
                  'Dados do empregador (AFD/AEJ e comprovantes)',
                ),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      children: [
                        field('name', 'Nome fantasia'),
                        field('legal_name', 'Razão social'),
                        field('document', 'CNPJ ou CPF'),
                        field('cno_caepf', 'CNO / CAEPF (se houver)'),
                        field(
                          'address',
                          'Endereço / local de prestação de serviço',
                        ),
                        Row(
                          children: [
                            Expanded(flex: 3, child: field('city', 'Cidade')),
                            const SizedBox(width: 12),
                            Expanded(child: field('state', 'UF')),
                          ],
                        ),
                        DropdownButtonFormField<int>(
                          initialValue: _offsets.containsKey(_offset)
                              ? _offset
                              : -180,
                          decoration: const InputDecoration(
                            labelText: 'Fuso horário',
                          ),
                          items: [
                            for (final e in _offsets.entries)
                              DropdownMenuItem(
                                value: e.key,
                                child: Text(e.value),
                              ),
                          ],
                          onChanged: admin
                              ? (v) => setState(() => _offset = v ?? -180)
                              : null,
                        ),
                        const SizedBox(height: 12),
                        Align(
                          alignment: Alignment.centerRight,
                          child: FilledButton(
                            onPressed: admin ? _saveCompany : null,
                            child: const Text('Salvar dados'),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SectionTitle('Regras de marcação'),
                Card(
                  child: Column(
                    children: [
                      SwitchListTile(
                        value: s.requireGeofence,
                        onChanged: admin
                            ? (v) => _saveSettings(_copy(requireGeofence: v))
                            : null,
                        title: const Text(
                          'Exigir marcação dentro do perímetro',
                        ),
                        subtitle: const Text(
                          'Bloqueia marcações fora das geocercas (exceto colaboradores externos)',
                        ),
                      ),
                      SwitchListTile(
                        value: s.requirePhoto,
                        onChanged: admin
                            ? (v) => _saveSettings(_copy(requirePhoto: v))
                            : null,
                        title: const Text('Exigir foto (selfie) na marcação'),
                      ),
                      SwitchListTile(
                        value: s.allowOffline,
                        onChanged: admin
                            ? (v) => _saveSettings(_copy(allowOffline: v))
                            : null,
                        title: const Text('Permitir marcação off-line'),
                        subtitle: const Text(
                          'Registradas sem internet e enviadas depois (identificadas no AFD)',
                        ),
                      ),
                      SwitchListTile(
                        value: s.allowMobile,
                        onChanged: admin
                            ? (v) => _saveSettings(_copy(allowMobile: v))
                            : null,
                        title: const Text('Permitir marcação pelo celular'),
                      ),
                      SwitchListTile(
                        value: s.allowWeb,
                        onChanged: admin
                            ? (v) => _saveSettings(_copy(allowWeb: v))
                            : null,
                        title: const Text('Permitir marcação pelo navegador'),
                      ),
                      SwitchListTile(
                        value: s.allowDesktop,
                        onChanged: admin
                            ? (v) => _saveSettings(_copy(allowDesktop: v))
                            : null,
                        title: const Text('Permitir marcação pelo app desktop'),
                      ),
                      ListTile(
                        title: const Text('Intervalo mínimo entre marcações'),
                        subtitle: const Text(
                          'Evita registros duplicados por toque acidental',
                        ),
                        trailing: DropdownButton<int>(
                          value: s.minMinutesBetweenPunches,
                          items: [
                            for (final m in const [0, 1, 2, 5, 10])
                              DropdownMenuItem(value: m, child: Text('$m min')),
                          ],
                          onChanged: admin
                              ? (v) => _saveSettings(
                                  _copy(minMinutesBetweenPunches: v),
                                )
                              : null,
                        ),
                      ),
                    ],
                  ),
                ),
                const SectionTitle('Apuração e colaborador'),
                Card(
                  child: Column(
                    children: [
                      ListTile(
                        title: const Text('Dia de fechamento do ponto'),
                        subtitle: Text(
                          s.closingDay == 0
                              ? 'Mês civil (1º ao último dia)'
                              : 'Período do dia ${s.closingDay + 1} ao dia ${s.closingDay}',
                        ),
                        trailing: DropdownButton<int>(
                          value: s.closingDay,
                          items: [
                            const DropdownMenuItem(
                              value: 0,
                              child: Text('Fim do mês'),
                            ),
                            for (var d = 1; d <= 27; d++)
                              DropdownMenuItem(value: d, child: Text('Dia $d')),
                          ],
                          onChanged: admin
                              ? (v) => _saveSettings(_copy(closingDay: v))
                              : null,
                        ),
                      ),
                      SwitchListTile(
                        value: s.managerScope == 'team',
                        onChanged: admin
                            ? (v) => _saveSettings(
                                _copy(managerScope: v ? 'team' : 'all'),
                              )
                            : null,
                        title: const Text(
                          'Gestores veem apenas a própria equipe',
                        ),
                        subtitle: const Text(
                          'Departamento do gestor e subordinados diretos. Administradores continuam vendo toda a empresa.',
                        ),
                      ),
                      SwitchListTile(
                        value: s.showBankToEmployee,
                        onChanged: admin
                            ? (v) => _saveSettings(_copy(showBankToEmployee: v))
                            : null,
                        title: const Text(
                          'Colaborador vê o próprio banco de horas',
                        ),
                      ),
                      SwitchListTile(
                        value: s.requireTimesheetSignature,
                        onChanged: admin
                            ? (v) => _saveSettings(
                                _copy(requireTimesheetSignature: v),
                              )
                            : null,
                        title: const Text(
                          'Solicitar assinatura mensal do espelho',
                        ),
                      ),
                      SwitchListTile(
                        value: s.reminders,
                        onChanged: admin
                            ? (v) => _saveSettings(_copy(reminders: v))
                            : null,
                        title: const Text(
                          'Lembretes de marcação no aplicativo',
                        ),
                      ),
                    ],
                  ),
                ),
                const SectionTitle('REP-P'),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        field(
                          'inpi',
                          'Nº de registro do programa no INPI',
                          helper:
                              'Exibido no comprovante e no cabeçalho do AFD',
                        ),
                        Align(
                          alignment: Alignment.centerRight,
                          child: OutlinedButton(
                            onPressed: admin
                                ? () => _saveSettings(
                                    _copy(inpiNumber: _ctl('inpi').text.trim()),
                                  )
                                : null,
                            child: const Text('Salvar'),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 32),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Auditoria
// ---------------------------------------------------------------------------

class AuditPage extends ConsumerStatefulWidget {
  const AuditPage({super.key});
  @override
  ConsumerState<AuditPage> createState() => _AuditPageState();
}

class _AuditPageState extends ConsumerState<AuditPage> {
  String? _entity;

  static const _entities = {
    null: 'Tudo',
    'punch': 'Marcações',
    'member': 'Colaboradores',
    'request': 'Solicitações',
    'schedule': 'Escalas',
    'settings': 'Configurações',
    'afd': 'AFD',
    'timesheet': 'Assinaturas',
    'period': 'Períodos',
    'api_key': 'Chaves de API',
    'webhook': 'Webhooks',
  };

  static const _actions = {
    'create': 'criou',
    'update': 'alterou',
    'delete': 'excluiu',
    'include': 'incluiu',
    'disregard': 'desconsiderou',
    'restore': 'restaurou',
    'approve': 'aprovou',
    'reject': 'recusou',
    'dismiss': 'desligou',
    'reactivate': 'reativou',
    'export': 'exportou',
    'sign': 'assinou',
    'reset_password': 'redefiniu a senha de',
    'set_pin': 'definiu o PIN de',
    'activate': 'ativou',
    'close': 'fechou',
    'reopen': 'reabriu',
    'revoke': 'revogou',
  };

  @override
  Widget build(BuildContext context) {
    final me = ref.watch(meProvider);
    final data = ref.watch(auditProvider(_entity));
    return Scaffold(
      appBar: AppBar(title: const Text('Auditoria')),
      body: Column(
        children: [
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              children: [
                for (final e in _entities.entries)
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: ChoiceChip(
                      label: Text(e.value),
                      selected: _entity == e.key,
                      onSelected: (_) => setState(() => _entity = e.key),
                    ),
                  ),
              ],
            ),
          ),
          Expanded(
            child: AsyncView(
              value: data,
              onRetry: () => ref.invalidate(auditProvider(_entity)),
              builder: (list) => list.isEmpty
                  ? const EmptyState(
                      icon: Icons.policy_outlined,
                      title: 'Nenhum registro',
                    )
                  : ListView.separated(
                      padding: const EdgeInsets.all(16),
                      itemCount: list.length,
                      separatorBuilder: (_, _) => const Divider(height: 1),
                      itemBuilder: (c, i) {
                        final a = list[i];
                        final wall = TimeFmt.toWall(a.createdAt, me.offset);
                        final details = a.data.entries
                            .where(
                              (e) =>
                                  e.value != null &&
                                  e.value.toString().isNotEmpty &&
                                  e.value is! Map &&
                                  e.value is! List,
                            )
                            .map((e) => '${e.key}: ${e.value}')
                            .take(4)
                            .join(' • ');
                        return Constrained(
                          maxWidth: 900,
                          child: ListTile(
                            leading: const Icon(Icons.history),
                            title: Text(
                              '${a.actorName ?? 'Sistema'} ${_actions[a.action] ?? a.action} ${_entities[a.entity]?.toLowerCase() ?? a.entity}',
                            ),
                            subtitle: Text(
                              '${TimeFmt.dateTimeBr(wall)}${a.ip != null ? ' • IP ${a.ip}' : ''}${details.isEmpty ? '' : '\n$details'}',
                            ),
                            isThreeLine: details.isNotEmpty,
                          ),
                        );
                      },
                    ),
            ),
          ),
        ],
      ),
    );
  }
}
