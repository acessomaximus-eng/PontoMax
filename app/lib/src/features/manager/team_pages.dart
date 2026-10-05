import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:pontomax_core/pontomax_core.dart';

import '../../state/data.dart';
import '../../state/session.dart';
import '../../theme.dart';
import '../../widgets/common.dart';
import '../common/timesheet_view.dart';
import '../employee/employee_pages.dart';

class TeamPage extends ConsumerStatefulWidget {
  const TeamPage({super.key});
  @override
  ConsumerState<TeamPage> createState() => _TeamPageState();
}

class _TeamPageState extends ConsumerState<TeamPage> {
  String _status = 'active';
  String? _q;

  @override
  Widget build(BuildContext context) {
    final filter = (status: _status, q: _q);
    final data = ref.watch(membersProvider(filter));
    return Scaffold(
      appBar: AppBar(title: const Text('Colaboradores')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => context.push('/equipe/novo'),
        icon: const Icon(Icons.person_add_alt_1),
        label: const Text('Novo colaborador'),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: Constrained(
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      decoration: const InputDecoration(
                        prefixIcon: Icon(Icons.search),
                        hintText: 'Buscar por nome, e-mail, CPF ou matrícula',
                        isDense: true,
                      ),
                      onSubmitted: (v) => setState(
                        () => _q = v.trim().isEmpty ? null : v.trim(),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  SegmentedButton<String>(
                    segments: const [
                      ButtonSegment(value: 'active', label: Text('Ativos')),
                      ButtonSegment(
                        value: 'inactive',
                        label: Text('Desligados'),
                      ),
                    ],
                    selected: {_status},
                    onSelectionChanged: (s) =>
                        setState(() => _status = s.first),
                  ),
                ],
              ),
            ),
          ),
          Expanded(
            child: RefreshIndicator(
              onRefresh: () async => ref.invalidate(membersProvider),
              child: AsyncView(
                value: data,
                onRetry: () => ref.invalidate(membersProvider(filter)),
                builder: (list) => list.isEmpty
                    ? ListView(
                        children: const [
                          SizedBox(height: 60),
                          EmptyState(
                            icon: Icons.groups_outlined,
                            title: 'Nenhum colaborador encontrado',
                          ),
                        ],
                      )
                    : ListView.separated(
                        padding: const EdgeInsets.fromLTRB(16, 0, 16, 96),
                        itemCount: list.length,
                        separatorBuilder: (_, _) => const SizedBox(height: 6),
                        itemBuilder: (c, i) {
                          final m = list[i];
                          return Constrained(
                            child: Card(
                              child: ListTile(
                                leading: Avatar(name: m.name, url: m.photoUrl),
                                title: Text(
                                  m.name,
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                subtitle: Text(
                                  [
                                    m.positionName ?? m.role.label,
                                    if (m.departmentName != null)
                                      m.departmentName!,
                                    if (m.scheduleName != null) m.scheduleName!,
                                  ].join(' • '),
                                ),
                                trailing: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    if (m.role.isManager)
                                      StatusChip(
                                        m.role.label,
                                        color: AppColors.brand,
                                      ),
                                    if (!m.active)
                                      const StatusChip(
                                        'Desligado',
                                        color: AppColors.muted,
                                      ),
                                    const Icon(Icons.chevron_right),
                                  ],
                                ),
                                onTap: () => context.push('/equipe/${m.id}'),
                              ),
                            ),
                          );
                        },
                      ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Detalhe do colaborador: espelho com tratamento, banco de horas, dados.
class MemberDetailPage extends ConsumerWidget {
  final String memberId;
  const MemberDetailPage({super.key, required this.memberId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final member = ref.watch(memberProvider(memberId));
    return DefaultTabController(
      length: 3,
      child: Scaffold(
        appBar: AppBar(
          title: member.when(
            data: (m) => Row(
              children: [
                Avatar(name: m.name, url: m.photoUrl, radius: 18),
                const SizedBox(width: 10),
                Expanded(child: Text(m.name, overflow: TextOverflow.ellipsis)),
              ],
            ),
            loading: () => const Text('Colaborador'),
            error: (_, _) => const Text('Colaborador'),
          ),
          actions: [
            IconButton(
              tooltip: 'Editar',
              onPressed: () => context.push('/equipe/$memberId/editar'),
              icon: const Icon(Icons.edit_outlined),
            ),
            IconButton(
              tooltip: 'Mensagem',
              onPressed: () => context.push(
                '/chat/$memberId?name=${Uri.encodeComponent(member.value?.name ?? '')}',
              ),
              icon: const Icon(Icons.chat_bubble_outline),
            ),
          ],
          bottom: const TabBar(
            tabs: [
              Tab(text: 'Espelho / tratamento'),
              Tab(text: 'Banco de horas'),
              Tab(text: 'Dados'),
            ],
          ),
        ),
        body: TabBarView(
          children: [
            TimesheetView(memberId: memberId, canTreat: true),
            _MemberBankTab(memberId: memberId),
            AsyncView(
              value: member,
              builder: (m) => _MemberInfo(member: m),
            ),
          ],
        ),
      ),
    );
  }
}

class _MemberBankTab extends ConsumerWidget {
  final String memberId;
  const _MemberBankTab({required this.memberId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final data = ref.watch(bankProvider(memberId));
    return Scaffold(
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _addEntry(context, ref),
        icon: const Icon(Icons.add),
        label: const Text('Lançamento'),
      ),
      body: AsyncView(
        value: data,
        onRetry: () => ref.invalidate(bankProvider(memberId)),
        builder: (d) => BankView(data: d),
      ),
    );
  }

  Future<void> _addEntry(BuildContext context, WidgetRef ref) async {
    var type = BankEntryType.credit;
    final hours = TextEditingController();
    final desc = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (c, set) => AlertDialog(
          title: const Text('Lançamento no banco de horas'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              DropdownButtonFormField<BankEntryType>(
                initialValue: type,
                decoration: const InputDecoration(labelText: 'Tipo'),
                items: [
                  for (final t in BankEntryType.values)
                    DropdownMenuItem(value: t, child: Text(t.label)),
                ],
                onChanged: (v) => set(() => type = v ?? type),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: hours,
                decoration: const InputDecoration(
                  labelText: 'Horas (HH:MM)',
                  hintText: '02:30',
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: desc,
                decoration: const InputDecoration(labelText: 'Descrição'),
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
              child: const Text('Lançar'),
            ),
          ],
        ),
      ),
    );
    if (ok != true || !context.mounted) return;
    await runAction(context, () async {
      var minutes = TimeFmt.parseHm(
        hours.text.contains(':')
            ? hours.text.replaceAll('-', '')
            : '${hours.text}:00',
      );
      if (type == BankEntryType.initial && hours.text.trim().startsWith('-')) {
        minutes = -minutes;
      }
      await ref.read(apiProvider).post('/bank/entries', {
        'member_id': memberId,
        'type': type.code,
        'minutes': minutes,
        'description': desc.text,
      });
    }, success: 'Lançamento registrado');
    ref.invalidate(bankProvider(memberId));
  }
}

class _MemberInfo extends ConsumerWidget {
  final Member member;
  const _MemberInfo({required this.member});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final m = member;
    final api = ref.read(apiProvider);
    Widget row(String k, String? v) => ListTile(
      dense: true,
      title: Text(k),
      subtitle: Text(v == null || v.isEmpty ? '—' : v),
    );
    void reload() {
      ref.invalidate(memberProvider(m.id));
      ref.invalidate(membersProvider);
    }

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Constrained(
          maxWidth: 800,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Card(
                child: Column(
                  children: [
                    row('E-mail', m.email),
                    row('CPF', Documents.formatCpf(m.cpf)),
                    row('Telefone', m.phone),
                    row('Perfil', m.role.label),
                    row('Matrícula', m.registration),
                    row('Departamento', m.departmentName),
                    row('Cargo', m.positionName),
                    row('Escala', m.scheduleName ?? 'Padrão da empresa'),
                    row('Admissão', m.admissionDate?.toBr()),
                    if (m.dismissalDate != null)
                      row('Desligamento', m.dismissalDate!.toBr()),
                    row('Crachá', m.badgeCode),
                    row(
                      'PIN do quiosque',
                      m.hasPin ? 'Definido' : 'Não definido',
                    ),
                    row(
                      'Marcação fora do perímetro',
                      m.allowAnywhere
                          ? 'Permitida (externo/remoto)'
                          : 'Não permitida',
                    ),
                    row('Matrícula eSocial', m.esocialRegistration),
                  ],
                ),
              ),
              _MemberAbsences(memberId: m.id),
              const SizedBox(height: 16),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  OutlinedButton.icon(
                    onPressed: () async {
                      final r = await runAction(
                        context,
                        () => api.post('/members/${m.id}/reset-password'),
                      );
                      if (r != null && context.mounted) {
                        await showDialog(
                          context: context,
                          builder: (c) => AlertDialog(
                            title: const Text('Senha provisória'),
                            content: SelectableText(
                              'Envie ao colaborador: ${(r as Map)['temporary_password']}',
                            ),
                            actions: [
                              TextButton(
                                onPressed: () => Clipboard.setData(
                                  ClipboardData(
                                    text: r['temporary_password'] as String,
                                  ),
                                ),
                                child: const Text('Copiar'),
                              ),
                              FilledButton(
                                onPressed: () => Navigator.pop(c),
                                child: const Text('OK'),
                              ),
                            ],
                          ),
                        );
                      }
                    },
                    icon: const Icon(Icons.key_outlined),
                    label: const Text('Redefinir senha'),
                  ),
                  OutlinedButton.icon(
                    onPressed: () async {
                      final pin = await promptText(
                        context,
                        'Definir PIN do quiosque (4 a 6 dígitos)',
                        label: 'PIN',
                      );
                      if (pin == null || !context.mounted) return;
                      await runAction(
                        context,
                        () => api.put('/members/${m.id}/pin', {'pin': pin}),
                        success: 'PIN definido',
                      );
                      reload();
                    },
                    icon: const Icon(Icons.pin_outlined),
                    label: const Text('Definir PIN'),
                  ),
                  if (m.active)
                    OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        foregroundColor: AppColors.danger,
                      ),
                      onPressed: () async {
                        if (!await confirm(
                          context,
                          'Desligar colaborador',
                          '${m.name} não poderá mais registrar o ponto. O histórico é mantido.',
                          destructive: true,
                          ok: 'Desligar',
                        )) {
                          return;
                        }
                        if (!context.mounted) return;
                        await runAction(
                          context,
                          () => api.post('/members/${m.id}/dismiss'),
                          success: 'Colaborador desligado',
                        );
                        reload();
                      },
                      icon: const Icon(Icons.person_off_outlined),
                      label: const Text('Desligar'),
                    )
                  else
                    FilledButton.tonalIcon(
                      onPressed: () async {
                        await runAction(
                          context,
                          () => api.post('/members/${m.id}/reactivate'),
                          success: 'Colaborador reativado',
                        );
                        reload();
                      },
                      icon: const Icon(Icons.person_add_alt),
                      label: const Text('Reativar'),
                    ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Cadastro/edição de colaborador.
class MemberFormPage extends ConsumerStatefulWidget {
  final String? memberId;
  const MemberFormPage({super.key, this.memberId});

  @override
  ConsumerState<MemberFormPage> createState() => _MemberFormPageState();
}

class _MemberFormPageState extends ConsumerState<MemberFormPage> {
  final _form = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _email = TextEditingController();
  final _cpf = TextEditingController();
  final _phone = TextEditingController();
  final _registration = TextEditingController();
  final _badge = TextEditingController();
  final _pin = TextEditingController();
  final _esocial = TextEditingController();
  Role _role = Role.employee;
  String? _department, _position, _schedule;
  LocalDate? _admission;
  bool _allowAnywhere = false;
  Set<String> _geofences = {};
  bool _loaded = false;
  bool _busy = false;

  bool get _editing => widget.memberId != null;

  @override
  void initState() {
    super.initState();
    if (_editing) {
      ref.read(apiProvider).getMap('/members/${widget.memberId}').then((j) {
        final m = Member.fromJson(j);
        if (!mounted) return;
        setState(() {
          _name.text = m.name;
          _email.text = m.email;
          _cpf.text = Documents.formatCpf(m.cpf);
          _phone.text = m.phone ?? '';
          _registration.text = m.registration ?? '';
          _badge.text = m.badgeCode ?? '';
          _esocial.text = m.esocialRegistration ?? '';
          _role = m.role;
          _department = m.departmentId;
          _position = m.positionId;
          _schedule = m.scheduleId;
          _admission = m.admissionDate;
          _allowAnywhere = m.allowAnywhere;
          _geofences = m.geofenceIds.toSet();
          _loaded = true;
        });
      });
    } else {
      _loaded = true;
    }
  }

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    setState(() => _busy = true);
    final api = ref.read(apiProvider);
    final body = {
      'name': _name.text.trim(),
      'email': _email.text.trim(),
      'cpf': _cpf.text.trim(),
      'phone': _phone.text.trim(),
      'registration': _registration.text.trim(),
      'badge_code': _badge.text.trim(),
      'esocial_registration': _esocial.text.trim(),
      'role': _role.code,
      'department_id': _department,
      'position_id': _position,
      'schedule_id': _schedule,
      'admission_date': _admission?.toString(),
      'allow_anywhere': _allowAnywhere,
      'geofence_ids': _geofences.toList(),
      if (!_editing && _pin.text.isNotEmpty) 'pin': _pin.text,
    };
    final r = await runAction(context, () async {
      if (_editing) return api.put('/members/${widget.memberId}', body);
      return api.post('/members', body);
    }, success: _editing ? 'Dados atualizados' : 'Colaborador cadastrado');
    if (!mounted) return;
    setState(() => _busy = false);
    if (r == null) return;
    ref.invalidate(membersProvider);
    if (_editing) ref.invalidate(memberProvider(widget.memberId!));
    final temp = (r as Map)['temporary_password'];
    if (temp != null) {
      await showDialog(
        context: context,
        builder: (c) => AlertDialog(
          title: const Text('Acesso criado'),
          content: SelectableText(
            'Envie ao colaborador:\n\nE-mail: ${_email.text.trim()}\nSenha provisória: $temp\n\nEle também recebeu um convite por e-mail.',
          ),
          actions: [
            TextButton(
              onPressed: () => Clipboard.setData(
                ClipboardData(
                  text: 'PontoMax — e-mail: ${_email.text.trim()} senha: $temp',
                ),
              ),
              child: const Text('Copiar'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(c),
              child: const Text('OK'),
            ),
          ],
        ),
      );
    }
    if (mounted) context.pop();
  }

  @override
  Widget build(BuildContext context) {
    final me = ref.watch(meProvider);
    final deps = ref.watch(departmentsProvider).value ?? const [];
    final positions = ref.watch(positionsProvider).value ?? const [];
    final schedules = ref.watch(schedulesProvider).value ?? const [];
    final fences = ref.watch(geofencesProvider).value ?? const [];
    return Scaffold(
      appBar: AppBar(
        title: Text(_editing ? 'Editar colaborador' : 'Novo colaborador'),
      ),
      body: !_loaded
          ? const Center(child: CircularProgressIndicator())
          : Form(
              key: _form,
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  Constrained(
                    maxWidth: 760,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        const SectionTitle('Identificação'),
                        TextFormField(
                          controller: _name,
                          decoration: const InputDecoration(
                            labelText: 'Nome completo *',
                          ),
                          validator: (v) => (v ?? '').trim().length < 3
                              ? 'Informe o nome'
                              : null,
                        ),
                        const SizedBox(height: 12),
                        TextFormField(
                          controller: _email,
                          keyboardType: TextInputType.emailAddress,
                          decoration: const InputDecoration(
                            labelText: 'E-mail (login) *',
                          ),
                          validator: (v) => Documents.isValidEmail(v?.trim())
                              ? null
                              : 'E-mail inválido',
                        ),
                        const SizedBox(height: 12),
                        Row(
                          children: [
                            Expanded(
                              child: TextFormField(
                                controller: _cpf,
                                keyboardType: TextInputType.number,
                                decoration: const InputDecoration(
                                  labelText: 'CPF *',
                                  helperText: 'Obrigatório (Portaria 671)',
                                ),
                                validator: (v) => Documents.isValidCpf(v)
                                    ? null
                                    : 'CPF inválido',
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: TextFormField(
                                controller: _phone,
                                decoration: const InputDecoration(
                                  labelText: 'Celular',
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SectionTitle('Vínculo'),
                        Row(
                          children: [
                            Expanded(
                              child: TextFormField(
                                controller: _registration,
                                decoration: const InputDecoration(
                                  labelText: 'Matrícula',
                                ),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: OutlinedButton.icon(
                                onPressed: () async {
                                  final d = await showDatePicker(
                                    context: context,
                                    initialDate:
                                        (_admission?.toDateTime() ??
                                                DateTime.now())
                                            .toLocal(),
                                    firstDate: DateTime(1980),
                                    lastDate: DateTime.now().add(
                                      const Duration(days: 365),
                                    ),
                                  );
                                  if (d != null) {
                                    setState(
                                      () => _admission = LocalDate(
                                        d.year,
                                        d.month,
                                        d.day,
                                      ),
                                    );
                                  }
                                },
                                icon: const Icon(Icons.event),
                                label: Text(
                                  _admission == null
                                      ? 'Data de admissão'
                                      : 'Admissão: ${_admission!.toBr()}',
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        DropdownButtonFormField<Role>(
                          initialValue: _role,
                          decoration: const InputDecoration(
                            labelText: 'Perfil de acesso',
                          ),
                          items: [
                            for (final r in Role.values)
                              if (me.isAdmin || !r.isAdmin)
                                DropdownMenuItem(
                                  value: r,
                                  child: Text(r.label),
                                ),
                          ],
                          onChanged: (v) => setState(() => _role = v ?? _role),
                        ),
                        const SizedBox(height: 12),
                        _dropdown(
                          'Departamento',
                          _department,
                          deps,
                          (v) => setState(() => _department = v),
                        ),
                        const SizedBox(height: 12),
                        _dropdown(
                          'Cargo',
                          _position,
                          positions,
                          (v) => setState(() => _position = v),
                        ),
                        const SizedBox(height: 12),
                        DropdownButtonFormField<String?>(
                          initialValue: _schedule,
                          decoration: const InputDecoration(
                            labelText: 'Escala de trabalho',
                          ),
                          items: [
                            const DropdownMenuItem(
                              value: null,
                              child: Text('Padrão da empresa'),
                            ),
                            for (final s in schedules)
                              DropdownMenuItem(
                                value: s.id,
                                child: Text(s.name),
                              ),
                          ],
                          onChanged: (v) => setState(() => _schedule = v),
                        ),
                        const SectionTitle('Marcação de ponto'),
                        SwitchListTile(
                          value: _allowAnywhere,
                          onChanged: (v) => setState(() => _allowAnywhere = v),
                          title: const Text(
                            'Permitir marcar fora dos perímetros',
                          ),
                          subtitle: const Text(
                            'Para trabalho externo, home office ou vendedores',
                          ),
                        ),
                        if (fences.isNotEmpty) ...[
                          const Padding(
                            padding: EdgeInsets.only(top: 8, bottom: 4),
                            child: Text(
                              'Perímetros permitidos (vazio = todos da empresa)',
                              style: TextStyle(color: AppColors.muted),
                            ),
                          ),
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: [
                              for (final f in fences)
                                FilterChip(
                                  label: Text(f.name),
                                  selected: _geofences.contains(f.id),
                                  onSelected: (v) => setState(
                                    () => v
                                        ? _geofences.add(f.id)
                                        : _geofences.remove(f.id),
                                  ),
                                ),
                            ],
                          ),
                        ],
                        const SizedBox(height: 12),
                        Row(
                          children: [
                            Expanded(
                              child: TextFormField(
                                controller: _badge,
                                decoration: const InputDecoration(
                                  labelText: 'Código do crachá',
                                ),
                              ),
                            ),
                            if (!_editing) ...[
                              const SizedBox(width: 12),
                              Expanded(
                                child: TextFormField(
                                  controller: _pin,
                                  keyboardType: TextInputType.number,
                                  obscureText: true,
                                  decoration: const InputDecoration(
                                    labelText: 'PIN do quiosque',
                                  ),
                                  validator: (v) =>
                                      (v ?? '').isEmpty ||
                                          RegExp(r'^\d{4,6}$').hasMatch(v!)
                                      ? null
                                      : '4 a 6 dígitos',
                                ),
                              ),
                            ],
                          ],
                        ),
                        const SizedBox(height: 12),
                        TextFormField(
                          controller: _esocial,
                          decoration: const InputDecoration(
                            labelText: 'Matrícula eSocial (AEJ)',
                          ),
                        ),
                        const SizedBox(height: 24),
                        FilledButton(
                          onPressed: _busy ? null : _save,
                          child: _busy
                              ? const SizedBox(
                                  width: 22,
                                  height: 22,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2.5,
                                  ),
                                )
                              : Text(
                                  _editing
                                      ? 'Salvar alterações'
                                      : 'Cadastrar colaborador',
                                ),
                        ),
                        const SizedBox(height: 32),
                      ],
                    ),
                  ),
                ],
              ),
            ),
    );
  }

  Widget _dropdown(
    String label,
    String? value,
    List<NamedEntity> items,
    ValueChanged<String?> onChanged,
  ) => DropdownButtonFormField<String?>(
    initialValue: items.any((i) => i.id == value) ? value : null,
    decoration: InputDecoration(labelText: label),
    items: [
      const DropdownMenuItem(value: null, child: Text('—')),
      for (final i in items) DropdownMenuItem(value: i.id, child: Text(i.name)),
    ],
    onChanged: onChanged,
  );
}

/// Ausências, abonos, atestados e férias lançados para o colaborador.
class _MemberAbsences extends ConsumerWidget {
  final String memberId;
  const _MemberAbsences({required this.memberId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final data = ref.watch(absencesProvider(memberId));
    final list = data.value ?? const <AbsenceEntity>[];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SectionTitle('Ausências e abonos'),
        if (list.isEmpty)
          const Card(
            child: ListTile(
              leading: Icon(Icons.event_available_outlined),
              title: Text('Nenhuma ausência lançada'),
              subtitle: Text(
                'Lance abonos, atestados e folgas pelo espelho de ponto (toque no dia).',
              ),
            ),
          )
        else
          Card(
            child: Column(
              children: [
                for (final a in list)
                  ListTile(
                    leading: const Icon(Icons.healing_outlined),
                    title: Text(a.type.label),
                    subtitle: Text(
                      [
                        a.startDate == a.endDate
                            ? a.startDate.toBr()
                            : '${a.startDate.toBr()} a ${a.endDate.toBr()}',
                        if (a.minutesPerDay != null)
                          '${hm(a.minutesPerDay!)}/dia',
                        if (a.reason.isNotEmpty) a.reason,
                      ].join(' • '),
                    ),
                    trailing: IconButton(
                      tooltip: 'Excluir',
                      icon: const Icon(Icons.delete_outline),
                      onPressed: () async {
                        if (!await confirm(
                          context,
                          'Excluir lançamento',
                          'Remover "${a.type.label}"?',
                          destructive: true,
                        )) {
                          return;
                        }
                        if (!context.mounted) return;
                        await runAction(
                          context,
                          () =>
                              ref.read(apiProvider).delete('/absences/${a.id}'),
                          success: 'Lançamento excluído',
                        );
                        ref.invalidate(absencesProvider(memberId));
                        ref.invalidate(timesheetProvider);
                      },
                    ),
                  ),
              ],
            ),
          ),
      ],
    );
  }
}
