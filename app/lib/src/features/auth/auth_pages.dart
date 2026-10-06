import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:pontomax_core/pontomax_core.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../config.dart';
import '../../state/session.dart';
import '../../theme.dart';
import '../../widgets/common.dart';

/// Layout das telas de entrada (painel de marca à esquerda em telas largas).
class AuthLayout extends StatelessWidget {
  final String title;
  final String? subtitle;
  final List<Widget> children;
  const AuthLayout({
    super.key,
    required this.title,
    this.subtitle,
    required this.children,
  });

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final form = SafeArea(
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (!isWide(context)) ...[
                  const _Logo(),
                  const SizedBox(height: 28),
                ],
                Text(
                  title,
                  style: t.textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
                if (subtitle != null) ...[
                  const SizedBox(height: 6),
                  Text(
                    subtitle!,
                    style: t.textTheme.bodyMedium?.copyWith(
                      color: AppColors.muted,
                    ),
                  ),
                ],
                const SizedBox(height: 24),
                ...children,
              ],
            ),
          ),
        ),
      ),
    );
    if (!isWide(context)) return Scaffold(body: form);
    return Scaffold(
      body: Row(
        children: [
          Expanded(
            child: Container(
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  colors: [
                    Color(0xFF1E3A8A),
                    Color(0xFF1E40AF),
                    Color(0xFF0E7490),
                  ],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
              ),
              padding: const EdgeInsets.all(48),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const _Logo(light: true),
                  const SizedBox(height: 32),
                  Text(
                    'Controle de ponto simples, seguro e dentro da lei.',
                    style: t.textTheme.headlineMedium?.copyWith(
                      color: Colors.white,
                      fontWeight: FontWeight.w800,
                      height: 1.2,
                    ),
                  ),
                  const SizedBox(height: 20),
                  for (final f in const [
                    (
                      Icons.verified_user_outlined,
                      'REP-P conforme a Portaria 671 (AFD, AEJ e comprovantes)',
                    ),
                    (
                      Icons.location_on_outlined,
                      'Marcação por GPS com perímetro, selfie e QR Code',
                    ),
                    (
                      Icons.calculate_outlined,
                      'Horas extras, banco de horas e adicional noturno automáticos',
                    ),
                    (
                      Icons.devices_outlined,
                      'Celular, tablet (quiosque), computador e web',
                    ),
                  ])
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 6),
                      child: Row(
                        children: [
                          Icon(f.$1, color: Colors.white70),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              f.$2,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 15,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ),
          Expanded(child: form),
        ],
      ),
    );
  }
}

class _Logo extends StatelessWidget {
  final bool light;
  const _Logo({this.light = false});

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: light ? Colors.white : AppColors.brand,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Icon(
          Icons.fingerprint,
          color: light ? AppColors.brand : Colors.white,
          size: 28,
        ),
      ),
      const SizedBox(width: 12),
      Text(
        'PontoMax',
        style: Theme.of(context).textTheme.headlineSmall?.copyWith(
          fontWeight: FontWeight.w900,
          color: light ? Colors.white : null,
        ),
      ),
    ],
  );
}

class LoginPage extends ConsumerStatefulWidget {
  const LoginPage({super.key});
  @override
  ConsumerState<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends ConsumerState<LoginPage> {
  final _email = TextEditingController();
  final _password = TextEditingController();
  final _form = GlobalKey<FormState>();
  bool _busy = false;
  bool _obscure = true;

  Future<void> _submit() async {
    if (!_form.currentState!.validate()) return;
    setState(() => _busy = true);
    await runAction(
      context,
      () => ref
          .read(sessionProvider.notifier)
          .login(_email.text.trim(), _password.text),
    );
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final error = ref.watch(sessionProvider).error;
    return AuthLayout(
      title: 'Entrar',
      subtitle:
          'Acesse sua conta para registrar o ponto ou gerenciar a equipe.',
      children: [
        if (error != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: Card(
              color: AppColors.warning.withValues(alpha: 0.12),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Text(error),
              ),
            ),
          ),
        Form(
          key: _form,
          child: AutofillGroup(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextFormField(
                  controller: _email,
                  keyboardType: TextInputType.emailAddress,
                  autofillHints: const [AutofillHints.email],
                  decoration: const InputDecoration(
                    labelText: 'E-mail',
                    prefixIcon: Icon(Icons.alternate_email),
                  ),
                  validator: (v) => Documents.isValidEmail(v?.trim())
                      ? null
                      : 'Informe um e-mail válido',
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _password,
                  obscureText: _obscure,
                  autofillHints: const [AutofillHints.password],
                  onFieldSubmitted: (_) => _submit(),
                  decoration: InputDecoration(
                    labelText: 'Senha',
                    prefixIcon: const Icon(Icons.lock_outline),
                    suffixIcon: IconButton(
                      icon: Icon(
                        _obscure
                            ? Icons.visibility_outlined
                            : Icons.visibility_off_outlined,
                      ),
                      onPressed: () => setState(() => _obscure = !_obscure),
                    ),
                  ),
                  validator: (v) =>
                      (v ?? '').isEmpty ? 'Informe a senha' : null,
                ),
              ],
            ),
          ),
        ),
        Align(
          alignment: Alignment.centerRight,
          child: TextButton(
            onPressed: () => context.push('/esqueci'),
            child: const Text('Esqueci minha senha'),
          ),
        ),
        const SizedBox(height: 8),
        FilledButton(
          onPressed: _busy ? null : _submit,
          child: _busy
              ? const SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(strokeWidth: 2.5),
                )
              : const Text('Entrar'),
        ),
        const SizedBox(height: 12),
        OutlinedButton.icon(
          onPressed: () => context.push('/cadastro'),
          icon: const Icon(Icons.add_business_outlined),
          label: const Text('Cadastrar minha empresa'),
        ),
        const SizedBox(height: 24),
        Wrap(
          alignment: WrapAlignment.center,
          spacing: 8,
          children: [
            TextButton.icon(
              onPressed: () => context.push('/kiosk/ativar'),
              icon: const Icon(Icons.tablet_android_outlined, size: 18),
              label: const Text('Usar como quiosque'),
            ),
            TextButton.icon(
              onPressed: () => _serverDialog(context),
              icon: const Icon(Icons.dns_outlined, size: 18),
              label: const Text('Servidor'),
            ),
          ],
        ),
      ],
    );
  }

  Future<void> _serverDialog(BuildContext context) async {
    final url = await promptText(
      context,
      'Endereço do servidor',
      label: 'Ex.: https://ponto.suaempresa.com.br ou 192.168.0.10:8080',
      initial: AppConfig.apiUrl,
      required: false,
    );
    if (url == null) return;
    final error = url.isEmpty ? null : AppConfig.validateServer(url);
    if (error != null) {
      if (context.mounted) showSnack(context, error, error: true);
      return;
    }
    await AppConfig.setApiUrl(url.isEmpty ? null : url);
    if (context.mounted) showSnack(context, 'Servidor: ${AppConfig.apiUrl}');
  }
}

class RegisterPage extends ConsumerStatefulWidget {
  const RegisterPage({super.key});
  @override
  ConsumerState<RegisterPage> createState() => _RegisterPageState();
}

class _RegisterPageState extends ConsumerState<RegisterPage> {
  final _form = GlobalKey<FormState>();
  final _company = TextEditingController();
  final _document = TextEditingController();
  final _name = TextEditingController();
  final _cpf = TextEditingController();
  final _email = TextEditingController();
  final _phone = TextEditingController();
  final _password = TextEditingController();
  bool _accept = false;
  bool _busy = false;

  Future<void> _submit() async {
    if (!_form.currentState!.validate()) return;
    if (!_accept) {
      showSnack(
        context,
        'Aceite os termos de uso e a política de privacidade',
        error: true,
      );
      return;
    }
    setState(() => _busy = true);
    await runAction(
      context,
      () => ref.read(sessionProvider.notifier).register({
        'company_name': _company.text.trim(),
        'document': _document.text.trim(),
        'name': _name.text.trim(),
        'cpf': _cpf.text.trim(),
        'email': _email.text.trim(),
        'phone': _phone.text.trim(),
        'password': _password.text,
      }),
      success: 'Empresa criada! Bem-vindo(a) ao PontoMax.',
    );
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final digits = FilteringTextInputFormatter.allow(RegExp(r'[0-9A-Za-z./-]'));
    return AuthLayout(
      title: 'Cadastre sua empresa',
      subtitle: 'Comece agora: escala comercial e feriados nacionais já vêm configurados.',
      children: [
        Form(
          key: _form,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextFormField(
                controller: _company,
                decoration: const InputDecoration(
                  labelText: 'Nome da empresa',
                  prefixIcon: Icon(Icons.business),
                ),
                validator: (v) => (v ?? '').trim().length < 2
                    ? 'Informe o nome da empresa'
                    : null,
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _document,
                inputFormatters: [digits],
                decoration: const InputDecoration(
                  labelText: 'CNPJ (ou CPF do empregador)',
                  prefixIcon: Icon(Icons.badge_outlined),
                ),
                validator: (v) {
                  final d = Documents.onlyAlnum(v);
                  if (d.isEmpty) return 'Informe o CNPJ ou CPF';
                  return Documents.isValidCnpj(d) || Documents.isValidCpf(d)
                      ? null
                      : 'Documento inválido';
                },
              ),
              const SizedBox(height: 20),
              TextFormField(
                controller: _name,
                decoration: const InputDecoration(
                  labelText: 'Seu nome completo',
                  prefixIcon: Icon(Icons.person_outline),
                ),
                validator: (v) => (v ?? '').trim().split(' ').length < 2
                    ? 'Informe nome e sobrenome'
                    : null,
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _cpf,
                keyboardType: TextInputType.number,
                inputFormatters: [
                  FilteringTextInputFormatter.allow(RegExp(r'[0-9.-]')),
                ],
                decoration: const InputDecoration(
                  labelText: 'Seu CPF',
                  prefixIcon: Icon(Icons.fingerprint),
                ),
                validator: (v) =>
                    Documents.isValidCpf(v) ? null : 'CPF inválido',
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _email,
                keyboardType: TextInputType.emailAddress,
                decoration: const InputDecoration(
                  labelText: 'E-mail',
                  prefixIcon: Icon(Icons.alternate_email),
                ),
                validator: (v) => Documents.isValidEmail(v?.trim())
                    ? null
                    : 'E-mail inválido',
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _phone,
                keyboardType: TextInputType.phone,
                decoration: const InputDecoration(
                  labelText: 'Celular (opcional)',
                  prefixIcon: Icon(Icons.phone_outlined),
                ),
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _password,
                obscureText: true,
                decoration: const InputDecoration(
                  labelText: 'Senha',
                  helperText: 'Mínimo de 8 caracteres, com letras e números',
                  prefixIcon: Icon(Icons.lock_outline),
                ),
                validator: (v) {
                  final s = v ?? '';
                  if (s.length < 8) return 'Mínimo de 8 caracteres';
                  if (!RegExp(r'[A-Za-z]').hasMatch(s) ||
                      !RegExp(r'\d').hasMatch(s)) {
                    return 'Use letras e números';
                  }
                  return null;
                },
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        CheckboxListTile(
          value: _accept,
          contentPadding: EdgeInsets.zero,
          controlAffinity: ListTileControlAffinity.leading,
          onChanged: (v) => setState(() => _accept = v ?? false),
          title: const Text(
            'Li e aceito os termos de uso e a política de privacidade (LGPD).',
            style: TextStyle(fontSize: 13),
          ),
        ),
        Wrap(
          spacing: 4,
          children: [
            TextButton(
              onPressed: () =>
                  launchUrl(Uri.parse('${AppConfig.serverOrigin}/termos.html')),
              child: const Text('Termos de uso'),
            ),
            TextButton(
              onPressed: () => launchUrl(
                Uri.parse('${AppConfig.serverOrigin}/privacidade.html'),
              ),
              child: const Text('Política de privacidade'),
            ),
          ],
        ),
        const SizedBox(height: 8),
        FilledButton(
          onPressed: _busy ? null : _submit,
          child: _busy
              ? const SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(strokeWidth: 2.5),
                )
              : const Text('Criar conta'),
        ),
        TextButton(
          onPressed: () => context.go('/login'),
          child: const Text('Já tenho conta'),
        ),
      ],
    );
  }
}

class ForgotPage extends ConsumerStatefulWidget {
  const ForgotPage({super.key});
  @override
  ConsumerState<ForgotPage> createState() => _ForgotPageState();
}

class _ForgotPageState extends ConsumerState<ForgotPage> {
  final _email = TextEditingController();
  bool _sent = false;

  @override
  Widget build(BuildContext context) => AuthLayout(
    title: 'Recuperar senha',
    subtitle: _sent
        ? 'Se o e-mail estiver cadastrado, você receberá um link para criar uma nova senha.'
        : 'Informe seu e-mail para receber o link de redefinição.',
    children: [
      if (!_sent) ...[
        TextField(
          controller: _email,
          keyboardType: TextInputType.emailAddress,
          decoration: const InputDecoration(
            labelText: 'E-mail',
            prefixIcon: Icon(Icons.alternate_email),
          ),
        ),
        const SizedBox(height: 16),
        FilledButton(
          onPressed: () async {
            final r = await runAction(
              context,
              () => ref.read(apiProvider).post('/auth/forgot', {
                'email': _email.text.trim(),
              }),
            );
            if (r != null) setState(() => _sent = true);
          },
          child: const Text('Enviar link'),
        ),
      ],
      TextButton(
        onPressed: () => context.go('/login'),
        child: const Text('Voltar ao login'),
      ),
    ],
  );
}

class ResetPage extends ConsumerStatefulWidget {
  final String token;
  const ResetPage({super.key, required this.token});
  @override
  ConsumerState<ResetPage> createState() => _ResetPageState();
}

class _ResetPageState extends ConsumerState<ResetPage> {
  final _password = TextEditingController();

  @override
  Widget build(BuildContext context) => AuthLayout(
    title: 'Nova senha',
    children: [
      TextField(
        controller: _password,
        obscureText: true,
        decoration: const InputDecoration(
          labelText: 'Nova senha',
          helperText: 'Mínimo de 8 caracteres, com letras e números',
        ),
      ),
      const SizedBox(height: 16),
      FilledButton(
        onPressed: () async {
          final r = await runAction(
            context,
            () => ref.read(apiProvider).post('/auth/reset', {
              'token': widget.token,
              'password': _password.text,
            }),
            success: 'Senha alterada! Entre com a nova senha.',
          );
          if (r != null && context.mounted) context.go('/login');
        },
        child: const Text('Salvar'),
      ),
    ],
  );
}
