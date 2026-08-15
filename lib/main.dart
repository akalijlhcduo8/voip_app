import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MaterialApp(
    home: VoIPApp(),
    debugShowCheckedModeBanner: false,
  ));
}

class VoIPApp extends StatefulWidget {
  const VoIPApp({Key? key}) : super(key: key);

  @override
  State<VoIPApp> createState() => _VoIPAppState();
}

class _VoIPAppState extends State<VoIPApp> {
  final TextEditingController _serverController = TextEditingController(text: 'ws://192.168.0.180:8080');
  final TextEditingController _myNumberController = TextEditingController(text: '1001');
  final TextEditingController _targetNumberController = TextEditingController(text: '1002');

  WebSocketChannel? _channel;
  RTCPeerConnection? _peerConnection;
  MediaStream? _localStream;
  
  bool _isConnected = false;
  bool _isInCall = false;
  String _callStatus = "غير متصل";

  List<Map<String, dynamic>> _iceServers = [
    {'urls': 'stun:stun.l.google.com:19302'}
  ];

  @override
  void initState() {
    super.initState();
    _requestPermissions();
  }

  Future<void> _requestPermissions() async {
    await Permission.microphone.request();
  }

  void _connectToServer() {
    try {
      _channel = WebSocketChannel.connect(Uri.parse(_serverController.text.trim()));
      _channel!.stream.listen(_handleSocketMessage, onDone: () {
        setState(() {
          _isConnected = false;
          _callStatus = "انقطع الاتصال بالسيرفر";
        });
      });

      _sendMessage({
        'type': 'register',
        'virtualNumber': _myNumberController.text.trim(),
      });
    } catch (e) {
      setState(() => _callStatus = "خطأ في الاتصال: $e");
    }
  }

  void _handleSocketMessage(dynamic raw) async {
    final data = jsonDecode(raw);
    switch (data['type']) {
      case 'registered':
        setState(() {
          _isConnected = true;
          _callStatus = "متصل وجاهز لاستقبال المكالمات";
          if (data['iceServers'] != null) {
            _iceServers = List<Map<String, dynamic>>.from(data['iceServers']);
          }
        });
        break;

      case 'offer':
        _showIncomingCallDialog(data['callerNumber'], data['offer']);
        break;

      case 'answer':
        await _peerConnection?.setRemoteDescription(
          RTCSessionDescription(data['answer']['sdp'], data['answer']['type']),
        );
        setState(() => _callStatus = "المكالمة جارية");
        break;

      case 'ice_candidate':
        final c = data['candidate'];
        if (c != null) {
          await _peerConnection?.addCandidate(
            RTCIceCandidate(c['candidate'], c['sdpMid'], c['sdpMLineIndex']),
          );
        }
        break;

      case 'hangup':
        _endCallLocally();
        setState(() => _callStatus = "تم إنهاء المكالمة من الطرف الآخر");
        break;
    }
  }

  Future<void> _startCall() async {
    final target = _targetNumberController.text.trim();
    if (target.isEmpty) return;

    await _initPeerConnection(target);

    RTCSessionDescription offer = await _peerConnection!.createOffer({
      'offerToReceiveAudio': 1,
      'offerToReceiveVideo': 0,
    });
    await _peerConnection!.setLocalDescription(offer);

    _sendMessage({
      'type': 'offer',
      'targetNumber': target,
      'offer': {'sdp': offer.sdp, 'type': offer.type},
    });

    setState(() {
      _isInCall = true;
      _callStatus = "جاري الاتصال بـ $target...";
    });
  }

  Future<void> _acceptCall(String callerNumber, Map<String, dynamic> offer) async {
    await _initPeerConnection(callerNumber);

    await _peerConnection!.setRemoteDescription(
      RTCSessionDescription(offer['sdp'], offer['type']),
    );

    RTCSessionDescription answer = await _peerConnection!.createAnswer({
      'offerToReceiveAudio': 1,
      'offerToReceiveVideo': 0,
    });
    await _peerConnection!.setLocalDescription(answer);

    _sendMessage({
      'type': 'answer',
      'callerNumber': callerNumber,
      'answer': {'sdp': answer.sdp, 'type': answer.type},
    });

    setState(() {
      _isInCall = true;
      _callStatus = "المكالمة جارية مع $callerNumber";
    });
  }

  Future<void> _initPeerConnection(String remoteNumber) async {
    _peerConnection = await createPeerConnection({'iceServers': _iceServers});

    _localStream = await navigator.mediaDevices.getUserMedia({
      'audio': true,
      'video': false,
    });

    _localStream!.getTracks().forEach((track) {
      _peerConnection!.addTrack(track, _localStream!);
    });

    _peerConnection!.onIceCandidate = (candidate) {
      if (candidate.candidate != null) {
        _sendMessage({
          'type': 'ice_candidate',
          'targetNumber': remoteNumber,
          'candidate': {
            'candidate': candidate.candidate,
            'sdpMid': candidate.sdpMid,
            'sdpMLineIndex': candidate.sdpMLineIndex,
          }
        });
      }
    };
  }

  void _hangUp() {
    _sendMessage({
      'type': 'hangup',
      'targetNumber': _targetNumberController.text.trim(),
    });
    _endCallLocally();
  }

  void _endCallLocally() {
    _localStream?.getTracks().forEach((track) => track.stop());
    _localStream?.dispose();
    _peerConnection?.close();
    _localStream = null;
    _peerConnection = null;

    setState(() {
      _isInCall = false;
      _callStatus = "جاهز";
    });
  }

  void _sendMessage(Map<String, dynamic> msg) {
    _channel?.sink.add(jsonEncode(msg));
  }

  void _showIncomingCallDialog(String caller, Map<String, dynamic> offer) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text("مكالمة واردة"),
        content: Text("مكالمة صوتية من: $caller"),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              _hangUp();
            },
            child: const Text("رفض", style: TextStyle(color: Colors.red)),
          ),
          ElevatedButton(
            onPressed: () async {
              Navigator.pop(ctx);
              await _acceptCall(caller, offer);
            },
            child: const Text("رد"),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _channel?.sink.close();
    _endCallLocally();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("تطبيق الاتصال المشفر")),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          children: [
            TextField(
              controller: _serverController,
              decoration: const InputDecoration(labelText: "عنوان السيرفر (WebSocket URL)"),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _myNumberController,
                    decoration: const InputDecoration(labelText: "رقمي الوهمي"),
                    enabled: !_isConnected,
                  ),
                ),
                const SizedBox(width: 10),
                ElevatedButton(
                  onPressed: _isConnected ? null : _connectToServer,
                  child: Text(_isConnected ? "متصل" : "تسجيل"),
                ),
              ],
            ),
            const Divider(height: 30),
            TextField(
              controller: _targetNumberController,
              decoration: const InputDecoration(labelText: "الرقم المراد الاتصال به"),
            ),
            const SizedBox(height: 20),
            Text("الحالة: $_callStatus", style: const TextStyle(fontWeight: FontWeight.bold)),
            const Spacer(),
            if (!_isInCall)
              ElevatedButton.icon(
                style: ElevatedButton.styleFrom(backgroundColor: Colors.green, minimumSize: const Size.fromHeight(50)),
                icon: const Icon(Icons.call, color: Colors.white),
                label: const Text("بدء المكالمة", style: TextStyle(color: Colors.white)),
                onPressed: _isConnected ? _startCall : null,
              )
            else
              ElevatedButton.icon(
                style: ElevatedButton.styleFrom(backgroundColor: Colors.red, minimumSize: const Size.fromHeight(50)),
                icon: const Icon(Icons.call_end, color: Colors.white),
                label: const Text("إنهاء المكالمة", style: TextStyle(color: Colors.white)),
                onPressed: _hangUp,
              ),
          ],
        ),
      ),
    );
  }
}
