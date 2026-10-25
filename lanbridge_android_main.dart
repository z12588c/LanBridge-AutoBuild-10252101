// LanBridge Android 端主程序 (Flutter: lib/main.dart)
// 功能：
// 1. 局域网 UDP 自动发现电脑端（零配置一键连接）
// 2. 双端文件互传（发送手机文件到电脑 / 接收电脑文件存入 Download）
// 3. 双向实时投屏（观看并触控操作电脑画面 / 将手机屏幕投送到电脑）
// 4. 配合原生 AccessibilityService 接收电脑发来的点击与滑动反控指令
//
// 打包 APK 命令：
// flutter pub add file_picker:8.3.7
// flutter build apk --release

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';

const int udpDiscoveryPort = 50001;
const int fileTransferPort = 50002;
const int screenStreamPort = 50003;
const int controlEventPort = 50004;

void main() {
  runApp(const LanBridgeAndroidApp());
}

class LanBridgeAndroidApp extends StatelessWidget {
  const LanBridgeAndroidApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'LanBridge 极简互传与投屏',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF2563EB)),
        useMaterial3: true,
      ),
      home: const HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  static const MethodChannel _nativeChannel =
      MethodChannel('com.lanbridge.app/native_bridge');

  final TextEditingController _pcIpController = TextEditingController();
  String _status = '正在搜索局域网内的电脑...';
  double _progress = 0.0;
  bool _isCastingPhoneToPc = false;
  Uint8List? _pcScreenFrame;
  Socket? _controlSocket;

  @override
  void initState() {
    super.initState();
    _startUdpDiscovery();
    _startFileReceiveServer();
    _startPcScreenReceiver();
    _startPhoneControlReceiver();
  }

  // ===================== 1. 局域网 UDP 自动发现 =====================
  Future<void> _startUdpDiscovery() async {
    final RawDatagramSocket udp =
        await RawDatagramSocket.bind(InternetAddress.anyIPv4, udpDiscoveryPort);
    udp.broadcastEnabled = true;

    // 监听 Windows 端广播
    udp.listen((RawSocketEvent event) {
      if (event == RawSocketEvent.read) {
        final Datagram? dg = udp.receive();
        if (dg == null) return;
        try {
          final Map<String, dynamic> msg =
              jsonDecode(utf8.decode(dg.data)) as Map<String, dynamic>;
          if (msg['type'] == 'WINDOWS_PC') {
            final String ip = (msg['ip'] as String?) ?? dg.address.address;
            if (_pcIpController.text.isEmpty) {
              setState(() {
                _pcIpController.text = ip;
                _status = '已自动连接电脑: ${msg['name']} ($ip)';
              });
              _connectControlSocket(ip);
            }
          }
        } catch (_) {}
      }
    });

    // 定时广播手机自身在线状态
    Timer.periodic(const Duration(seconds: 2), (_) {
      final List<int> payload = utf8.encode(jsonEncode({
        'type': 'ANDROID_PHONE',
        'name': 'Android_Phone',
      }));
      udp.send(payload, InternetAddress('255.255.255.255'), udpDiscoveryPort);
    });
  }

  // ===================== 2. 双端文件互传 =====================
  Future<void> _pickAndSendFile() async {
    final String pcIp = _pcIpController.text.trim();
    if (pcIp.isEmpty) {
      _showSnack('请先确认电脑端局域网 IP');
      return;
    }
    final FilePickerResult? result = await FilePicker.platform.pickFiles();
    if (result == null || result.files.single.path == null) return;

    final File file = File(result.files.single.path!);
    final String filename = result.files.single.name;
    final int filesize = await file.length();

    try {
      setState(() => _status = '正在发送: $filename');
      final Socket sock = await Socket.connect(pcIp, fileTransferPort);
      final List<int> headerBytes =
          utf8.encode(jsonEncode({'filename': filename, 'size': filesize}));
      final ByteData lenBuf = ByteData(4)..setUint32(0, headerBytes.length);
      sock.add(lenBuf.buffer.asUint8List());
      sock.add(headerBytes);

      int sent = 0;
      await for (final List<int> chunk in file.openRead()) {
        sock.add(chunk);
        sent += chunk.length;
        setState(() => _progress = sent / (filesize == 0 ? 1 : filesize));
      }
      await sock.flush();
      await sock.close();
      setState(() => _status = '发送成功: $filename');
    } catch (e) {
      setState(() => _status = '发送失败: $e');
    }
  }

  Future<void> _startFileReceiveServer() async {
    final ServerSocket server =
        await ServerSocket.bind(InternetAddress.anyIPv4, fileTransferPort);
    await for (final Socket client in server) {
      _handleIncomingFile(client);
    }
  }

  Future<void> _handleIncomingFile(Socket client) async {
    try {
      final BytesBuilder buffer = BytesBuilder();
      int? headerLen;
      Map<String, dynamic>? header;
      IOSink? fileSink;
      int received = 0;
      int totalSize = 1;

      await for (final Uint8List chunk in client) {
        buffer.add(chunk);
        final Uint8List bytes = buffer.toBytes();

        if (headerLen == null && bytes.length >= 4) {
          headerLen = ByteData.sublistView(bytes, 0, 4).getUint32(0);
        }
        if (headerLen != null &&
            header == null &&
            bytes.length >= 4 + headerLen) {
          header = jsonDecode(utf8.decode(bytes.sublist(4, 4 + headerLen)))
              as Map<String, dynamic>;
          final String filename = header['filename'] as String;
          totalSize = header['size'] as int;
          final File outFile =
              File('/storage/emulated/0/Download/$filename');
          fileSink = outFile.openWrite();

          final Uint8List remain = bytes.sublist(4 + headerLen);
          fileSink.add(remain);
          received += remain.length;
          buffer.clear();
          setState(() => _status = '正在接收电脑文件: $filename');
        } else if (header != null && fileSink != null) {
          fileSink.add(chunk);
          received += chunk.length;
          buffer.clear();
          setState(() => _progress = received / totalSize);
        }
      }
      await fileSink?.flush();
      await fileSink?.close();
      setState(() => _status = '文件已保存至手机 Download 目录');
    } catch (e) {
      setState(() => _status = '接收文件异常: $e');
    } finally {
      client.destroy();
    }
  }

  // ===================== 3. 双向实时投屏 =====================
  Future<void> _startPcScreenReceiver() async {
    final ServerSocket server =
        await ServerSocket.bind(InternetAddress.anyIPv4, screenStreamPort);
    await for (final Socket client in server) {
      final BytesBuilder buf = BytesBuilder();
      int? frameLen;
      await for (final Uint8List chunk in client) {
        buf.add(chunk);
        while (true) {
          final Uint8List current = buf.toBytes();
          if (frameLen == null) {
            if (current.length < 4) break;
            frameLen = ByteData.sublistView(current, 0, 4).getUint32(0);
          }
          if (current.length < 4 + frameLen!) break;
          final Uint8List frameBytes = current.sublist(4, 4 + frameLen!);
          final Uint8List leftover = current.sublist(4 + frameLen!);
          buf.clear();
          buf.add(leftover);
          frameLen = null;
          setState(() => _pcScreenFrame = frameBytes);
        }
      }
    }
  }

  Future<void> _toggleCastPhoneToPc() async {
    final String pcIp = _pcIpController.text.trim();
    if (pcIp.isEmpty) {
      _showSnack('请先输入或选择电脑 IP');
      return;
    }
    if (_isCastingPhoneToPc) {
      await _nativeChannel.invokeMethod('stopScreenCapture');
      setState(() => _isCastingPhoneToPc = false);
    } else {
      await _nativeChannel.invokeMethod('startScreenCapture', {
        'targetIp': pcIp,
        'port': screenStreamPort,
      });
      setState(() => _isCastingPhoneToPc = true);
    }
  }

  // ===================== 4. 双向远程操控 =====================
  Future<void> _connectControlSocket(String pcIp) async {
    try {
      _controlSocket?.destroy();
      _controlSocket = await Socket.connect(pcIp, controlEventPort);
    } catch (_) {}
  }

  void _sendTouchToPc(Map<String, dynamic> cmd) {
    if (_controlSocket == null && _pcIpController.text.isNotEmpty) {
      _connectControlSocket(_pcIpController.text.trim());
    }
    try {
      _controlSocket?.write('${jsonEncode(cmd)}\n');
    } catch (_) {}
  }

  Future<void> _startPhoneControlReceiver() async {
    final ServerSocket server =
        await ServerSocket.bind(InternetAddress.anyIPv4, controlEventPort);
    await for (final Socket client in server) {
      utf8.decoder
          .bind(client)
          .transform(const LineSplitter())
          .listen((String line) async {
        if (line.trim().isEmpty) return;
        final Map<String, dynamic> msg =
            jsonDecode(line) as Map<String, dynamic>;
        // 转发给 Android 原生 AccessibilityService 执行真实点击/滑动/返回手势
        await _nativeChannel.invokeMethod('dispatchRemoteGesture', msg);
      });
    }
  }

  void _showSnack(String text) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  // ===================== 极简卡片式 UI =====================
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF8FAFC),
      appBar: AppBar(
        title: const Text('LanBridge 双端互传与双向投屏'),
        backgroundColor: const Color(0xFF1E293B),
        foregroundColor: Colors.white,
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // 状态与 IP 卡片
          Card(
            elevation: 0,
            color: Colors.white,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(_status,
                      style: const TextStyle(
                          fontWeight: FontWeight.bold, fontSize: 15)),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _pcIpController,
                    decoration: const InputDecoration(
                      labelText: '电脑端局域网 IP（自动发现或手动输入）',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),

          // 核心功能三合一按钮卡片
          Card(
            elevation: 0,
            color: Colors.white,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed: _pickAndSendFile,
                      icon: const Icon(Icons.upload_file),
                      label: const Text('发送手机文件到电脑'),
                    ),
                  ),
                  const SizedBox(height: 8),
                  LinearProgressIndicator(value: _progress),
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.tonalIcon(
                      onPressed: _toggleCastPhoneToPc,
                      icon: Icon(_isCastingPhoneToPc
                          ? Icons.stop_screen_share
                          : Icons.screen_share),
                      label: Text(_isCastingPhoneToPc
                          ? '停止投屏手机到电脑'
                          : '将手机投屏到电脑（允许电脑反控）'),
                    ),
                  ),
                  const SizedBox(height: 8),
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      onPressed: () =>
                          _nativeChannel.invokeMethod('openAccessibilitySettings'),
                      icon: const Icon(Icons.touch_app),
                      label: const Text('开启无障碍权限（支持电脑鼠标反控手机）'),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),

          // 电脑投屏画面展示与触控反控区
          Card(
            elevation: 0,
            color: const Color(0xFF0F172A),
            child: AspectRatio(
              aspectRatio: 16 / 9,
              child: _pcScreenFrame == null
                  ? const Center(
                      child: Text(
                        '💻 电脑投屏显示区\n当电脑开启「投屏到手机」时显示在此\n点击/双指触摸可直接操控电脑鼠标',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: Colors.white54),
                      ),
                    )
                  : LayoutBuilder(
                      builder: (context, constraints) {
                        return GestureDetector(
                          onTapUp: (details) {
                            final dx =
                                details.localPosition.dx / constraints.maxWidth;
                            final dy = details.localPosition.dy /
                                constraints.maxHeight;
                            _sendTouchToPc({'cmd': 'TAP', 'x': dx, 'y': dy});
                          },
                          onDoubleTapDown: (details) {
                            final dx =
                                details.localPosition.dx / constraints.maxWidth;
                            final dy = details.localPosition.dy /
                                constraints.maxHeight;
                            _sendTouchToPc(
                                {'cmd': 'DOUBLE_TAP', 'x': dx, 'y': dy});
                          },
                          onLongPressStart: (details) {
                            final dx =
                                details.localPosition.dx / constraints.maxWidth;
                            final dy = details.localPosition.dy /
                                constraints.maxHeight;
                            _sendTouchToPc(
                                {'cmd': 'RIGHT_CLICK', 'x': dx, 'y': dy});
                          },
                          onPanUpdate: (details) {
                            final dx =
                                details.localPosition.dx / constraints.maxWidth;
                            final dy = details.localPosition.dy /
                                constraints.maxHeight;
                            _sendTouchToPc({'cmd': 'MOVE', 'x': dx, 'y': dy});
                          },
                          child: Image.memory(
                            _pcScreenFrame!,
                            gaplessPlayback: true,
                            fit: BoxFit.contain,
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