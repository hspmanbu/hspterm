import 'runtime_errors.dart';
import 'terminal/font_licenses.dart';
import 'workbench/tmux_choice.dart';

import 'dart:async';
import 'dart:io';
import 'dart:ui' show AppExitResponse;

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import 'src/rust/api.dart' as rust;
import 'terminal/backend.dart';
import 'terminal/controller.dart';
import 'terminal/view.dart';

Future<void> main() async {
  installApplicationErrorBoundary();
  WidgetsFlutterBinding.ensureInitialized();
  registerTerminalFontLicenses();
  try {
    await initializeRust();
    runApp(const HsptermApp());
  } catch (_) {
    RuntimeFaults.instance.record(RuntimeFault.nativeStartup);
    runApp(
      MaterialApp(
        home: Scaffold(
          body: Center(child: SelectableText(nativeStartupFailure)),
        ),
      ),
    );
  }
}

class HsptermApp extends StatelessWidget {
  const HsptermApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'HSPTerm',
    debugShowCheckedModeBanner: false,
    theme: ThemeData.dark(useMaterial3: true)
        .copyWith(scaffoldBackgroundColor: const Color(0xff10151d)),
    home: const TerminalPage(),
  );
}

class TerminalPage extends StatefulWidget {
  const TerminalPage({super.key});
  @override
  State<TerminalPage> createState() => _TerminalPageState();
}

class _TerminalPageState extends State<TerminalPage> {
  final terminal = TerminalController(const NativeTerminalBackend());
  final view = GlobalKey<TerminalViewState>();
  late final AppLifecycleListener _lifecycle;
  bool unlocked = false, busy = false;
  String? message, selected;
  List<rust.Profile> profiles = [];
  double fontSize = 15;
  String _observedPhase = 'Idle';
  void _phaseChanged() {
    if (terminal.phase != _observedPhase && mounted) {
      setState(() => _observedPhase = terminal.phase);
    }
  }

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(
      onExitRequested: () async {
        try {
          await terminal.shutdown();
        } catch (_) {
          RuntimeFaults.instance.record(RuntimeFault.shutdown);
          // Keep this original controller available for a deliberate retry.
          return AppExitResponse.cancel;
        }
        return AppExitResponse.exit;
      },
    );
    terminal.addListener(_phaseChanged);
    terminal.confirmHostKey = _hostKey;
    terminal.chooseTmux = (prompt) async =>
        mounted ? showTmuxChoice(context, terminal, prompt) : null;
    unawaited(terminal.start().catchError(terminal.report));
  }

  Future<bool> _hostKey(rust.BridgeEvent event) async =>
      mounted &&
      (await showDialog<bool>(
            context: context,
            barrierDismissible: false,
            builder: (context) => AlertDialog(
              title: const Text('首次连接：确认 SSH 主机指纹'),
              content: SelectableText(
                '${event.detail}\n\n${event.text}\n\n请通过可信途径核对。确认后加密保存，后续指纹变化将阻止连接。',
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: const Text('拒绝'),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(context, true),
                  child: const Text('信任并保存'),
                ),
              ],
            ),
          )) ==
          true;
  Future<void> _unlock() async {
    final directory = await getApplicationSupportDirectory();
    final path = '${directory.path}${Platform.pathSeparator}hspterm.vault';
    final exists = await File(path).exists();
    if (!mounted) return;
    final password = TextEditingController();
    final confirmation = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, change) => AlertDialog(
          title: Text(exists ? '解锁加密配置' : '创建加密配置库'),
          content: SizedBox(
            width: 380,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(exists ? '输入主密码以读取已保存主机。' : '主密码用于加密主机和凭据。请妥善保管。'),
                TextField(
                  controller: password,
                  obscureText: true,
                  autofocus: true,
                  decoration: const InputDecoration(labelText: '主密码'),
                  onChanged: (_) => change(() {}),
                ),
                if (!exists)
                  TextField(
                    controller: confirmation,
                    obscureText: true,
                    decoration: const InputDecoration(labelText: '再次输入主密码'),
                    onChanged: (_) => change(() {}),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed:
                  password.text.isNotEmpty &&
                      (exists || password.text == confirmation.text)
                  ? () => Navigator.pop(context, true)
                  : null,
              child: const Text('解锁'),
            ),
          ],
        ),
      ),
    );
    final secret = password.text;
    password.clear();
    confirmation.clear();
    password.dispose();
    confirmation.dispose();
    if (ok != true) return;
    setState(() {
      busy = true;
      message = null;
    });
    try {
      await directory.create(recursive: true);
      await rust.unlockVault(path: path, password: secret);
      final list = await rust.listProfiles();
      if (mounted) {
        setState(() {
          unlocked = true;
          profiles = list;
          selected = list.firstOrNull?.id;
        });
      }
    } catch (error) {
      if (mounted) setState(() => message = error.toString());
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _save() async {
    final name = TextEditingController(),
        host = TextEditingController(),
        port = TextEditingController(text: '22'),
        user = TextEditingController(),
        secret = TextEditingController(),
        passphrase = TextEditingController();
    var privateKey = false;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, change) => AlertDialog(
          title: const Text('保存 SSH 主机'),
          content: SizedBox(
            width: 500,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: name,
                    decoration: const InputDecoration(labelText: '名称'),
                  ),
                  TextField(
                    controller: host,
                    decoration: const InputDecoration(labelText: '地址'),
                  ),
                  TextField(
                    controller: port,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(labelText: '端口'),
                  ),
                  TextField(
                    controller: user,
                    decoration: const InputDecoration(labelText: '用户名'),
                  ),
                  SwitchListTile(
                    title: const Text('使用 OpenSSH 私钥'),
                    value: privateKey,
                    onChanged: (v) => change(() => privateKey = v),
                  ),
                  TextField(
                    controller: secret,
                    obscureText: !privateKey,
                    maxLines: privateKey ? 6 : 1,
                    decoration: InputDecoration(
                      labelText: privateKey ? '粘贴 OpenSSH 私钥' : '密码',
                    ),
                  ),
                  if (privateKey)
                    TextField(
                      controller: passphrase,
                      obscureText: true,
                      decoration: const InputDecoration(labelText: '私钥口令（可空）'),
                    ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('保存并连接'),
            ),
          ],
        ),
      ),
    );
    try {
      if (ok == true) {
        final saved = await rust.saveProfile(
          profile: rust.Profile(
            id: '',
            name: name.text.trim().isEmpty
                ? host.text.trim()
                : name.text.trim(),
            address: host.text.trim(),
            port: int.parse(port.text),
            username: user.text,
            privateKey: privateKey,
          ),
          secret: secret.text,
          passphrase: passphrase.text.isEmpty ? null : passphrase.text,
        );
        final list = await rust.listProfiles();
        if (mounted) {
          setState(() {
            profiles = list;
            selected = saved.id;
          });
          await terminal.connect(
            saved.id,
            label: '${saved.username}@${saved.address}:${saved.port}',
          );
        }
      }
    } catch (error) {
      terminal.report(error);
    } finally {
      for (final c in [name, host, port, user, secret, passphrase]) {
        c.clear();
        c.dispose();
      }
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            child: Wrap(
              spacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                const Text('HSPTerm · SSH'),
                if (!unlocked)
                  FilledButton(
                    onPressed: busy ? null : _unlock,
                    child: Text(busy ? '正在解锁…' : '解锁配置'),
                  ),
                if (unlocked) ...[
                  DropdownButton<String>(
                    value: selected,
                    hint: const Text('已保存主机'),
                    items: profiles
                        .map(
                          (p) => DropdownMenuItem(
                            value: p.id,
                            child: Text(p.name),
                          ),
                        )
                        .toList(),
                    onChanged: terminal.connected
                        ? null
                        : (v) => setState(() => selected = v),
                  ),
                  FilledButton(
                    onPressed:
                        terminal.connected || terminal.phase == 'Connecting'
                        ? null
                        : () {
                            if (selected != null) {
                              final profile = profiles.firstWhere(
                                (p) => p.id == selected,
                              );
                              unawaited(
                                terminal.connect(
                                  selected!,
                                  label:
                                      '${profile.username}@${profile.address}:${profile.port}',
                                ),
                              );
                            }
                          },
                    child: const Text('连接'),
                  ),
                  TextButton(
                    onPressed: terminal.connected ? null : _save,
                    child: const Text('新建主机'),
                  ),
                ],
                IconButton(
                  tooltip: '终端搜索',
                  onPressed: () => view.currentState?.showSearch(),
                  icon: const Icon(Icons.search),
                ),
                IconButton(
                  tooltip: '导出终端历史',
                  onPressed: () => view.currentState?.exportHistory(),
                  icon: const Icon(Icons.save_alt),
                ),
                ListenableBuilder(
                  listenable: terminal,
                  builder: (context, _) => IconButton(
                    tooltip: terminal.metadata?.sizeLocked == true
                        ? '解除PTY尺寸锁定'
                        : '锁定PTY尺寸',
                    isSelected: terminal.metadata?.sizeLocked == true,
                    onPressed: () => unawaited(
                      terminal
                          .lockSize(!(terminal.metadata?.sizeLocked ?? false))
                          .catchError(terminal.report),
                    ),
                    icon: const Icon(Icons.aspect_ratio),
                  ),
                ),
                ListenableBuilder(
                  listenable: terminal,
                  builder: (context, _) => IconButton(
                    tooltip: terminal.osc52Enabled
                        ? '关闭远端OSC52剪贴板'
                        : '允许远端OSC52剪贴板',
                    isSelected: terminal.osc52Enabled,
                    onPressed: () => unawaited(
                      terminal
                          .setOsc52(!terminal.osc52Enabled)
                          .catchError(terminal.report),
                    ),
                    icon: const Icon(Icons.content_paste_go),
                  ),
                ),
                IconButton(
                  tooltip: '复制 Ctrl+Shift+C',
                  onPressed: () => view.currentState?.copy(),
                  icon: const Icon(Icons.copy),
                ),
                IconButton(
                  tooltip: '粘贴 Ctrl+Shift+V',
                  onPressed: () => view.currentState?.paste(),
                  icon: const Icon(Icons.paste),
                ),
                IconButton(
                  tooltip: '缩小字体',
                  onPressed: () =>
                      setState(() => fontSize = (fontSize - 1).clamp(9, 36)),
                  icon: const Icon(Icons.remove),
                ),
                IconButton(
                  tooltip: '放大字体',
                  onPressed: () =>
                      setState(() => fontSize = (fontSize + 1).clamp(9, 36)),
                  icon: const Icon(Icons.add),
                ),
              ],
            ),
          ),
          ListenableBuilder(
            listenable: terminal,
            builder: (context, child) => Column(
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          '${terminal.phase} · ${terminal.title}${terminal.metadata == null ? '' : ' · ${terminal.metadata!.columns}×${terminal.metadata!.rows}'}',
                        ),
                      ),
                      if (terminal.phase == 'Connecting')
                        TextButton(
                          onPressed: () {
                            if (terminal.id != null) {
                              unawaited(terminal.backend.cancel(terminal.id!));
                            }
                          },
                          child: const Text('取消连接'),
                        ),
                      if (terminal.phase == 'Disconnected' ||
                          terminal.phase == 'Failed')
                        TextButton(
                          onPressed: terminal.reconnect,
                          child: const Text('手动重连（或终端中按 Enter）'),
                        ),
                    ],
                  ),
                ),
                if (terminal.error != null || message != null)
                  Padding(
                    padding: const EdgeInsets.all(8),
                    child: SelectableText(
                      terminal.error ?? message!,
                      style: const TextStyle(color: Colors.orangeAccent),
                    ),
                  ),
              ],
            ),
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: TerminalView(
                key: view,
                controller: terminal,
                fontSize: fontSize,
              ),
            ),
          ),
        ],
      ),
    ),
  );
  @override
  void dispose() {
    _lifecycle.dispose();
    terminal.removeListener(_phaseChanged);
    terminal.dispose();
    super.dispose();
  }
}
