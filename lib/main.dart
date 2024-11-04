import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_sound/flutter_sound.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/status.dart' as status;

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  // Root of the application
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Real-Time Audio Streaming',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
        useMaterial3: true,
      ),
      home: const MyHomePage(title: 'Real-Time Audio Streaming'),
    );
  }
}

class MyHomePage extends StatefulWidget {
  const MyHomePage({super.key, required this.title});

  final String title;

  @override
  State<MyHomePage> createState() => _MyHomePageState();
}

class _MyHomePageState extends State<MyHomePage> {
  final FlutterSoundRecorder _recorder = FlutterSoundRecorder();
  final FlutterSoundPlayer _player = FlutterSoundPlayer();

  bool _isRecording = false;

  StreamController<Uint8List>? _audioStreamController;
  late StreamSubscription _recorderSubscription;

  List<Uint8List> _recordedAudioData = [];

  late IOWebSocketChannel _channel;

  // Variable to hold the transcription text
  String _transcriptionText = '';

  @override
  void initState() {
    super.initState();
    _initialize();
  }

  Future<void> _initialize() async {
    await _requestPermissions();
    await _initRecorder();
    await _initPlayer();
    _connectWebSocket();
  }

  Future<void> _requestPermissions() async {
    await Permission.microphone.request();
  }

  Future<void> _initRecorder() async {
    await _recorder.openRecorder();
    await _recorder.setSubscriptionDuration(Duration(milliseconds: 50));
  }

  Future<void> _initPlayer() async {
    await _player.openPlayer();
    await _player.startPlayerFromStream(
      codec: Codec.pcm16,
      numChannels: 1,
      sampleRate: 24000,
    );
  }

  void _connectWebSocket() {
    _channel = IOWebSocketChannel.connect('ws://192.168.1.85:8080');

    _channel.stream.listen((message) {
      final data = jsonDecode(message);

      // Handle audio transcription delta messages
      if (data['type'] == 'response.audio_transcript.delta' &&
          data['delta'] != null) {
        String deltaText = data['delta'];
        _onTranscriptionReceived(deltaText);
      }

      // Handle audio chunk messages
      if (data['type'] == 'response.audio.delta' && data['delta'] != null) {
        Uint8List audioChunk = base64Decode(data['delta']);
        _onAudioChunkReceived(audioChunk);
      }
    }, onDone: () {
      print('WebSocket closed');
    }, onError: (error) {
      print('WebSocket error: $error');
    });
  }

  void _startRecording() async {
    if (_isRecording) return;

    _recordedAudioData.clear();

    _audioStreamController = StreamController<Uint8List>();

    await _recorder.startRecorder(
      toStream: _audioStreamController!.sink,
      codec: Codec.pcm16,
      numChannels: 1,
      sampleRate: 24000,
    );

    _recorderSubscription = _recorder.onProgress!.listen((event) {
      // Update UI if needed
    });

    // Listen to the audio stream and collect data
    _audioStreamController!.stream.listen((buffer) {
      _recordedAudioData.add(buffer);
    });

    setState(() {
      _isRecording = true;
      _transcriptionText = ''; // Reset transcription text
    });
  }

  void _stopRecording() async {
    if (!_isRecording) return;

    await _recorder.stopRecorder();
    await _recorderSubscription.cancel();
    await _audioStreamController!.close();
    _audioStreamController = null;

    // Combine the recorded audio data
    Uint8List completeAudioData =
        Uint8List.fromList(_recordedAudioData.expand((x) => x).toList());

    // Encode and send over WebSocket
    final audioData = base64Encode(completeAudioData);

    final message = {
      'type': 'conversation.item.create',
      'item': {
        'type': 'message',
        'role': 'user',
        'content': [
          {
            'type': 'input_audio',
            'audio': audioData,
          },
        ],
      },
    };
    _channel.sink.add(jsonEncode(message));

    setState(() {
      _isRecording = false;
    });
  }

  void _onAudioChunkReceived(Uint8List chunk) {
    _player.foodSink!.add(FoodData(chunk));
  }

  void _onTranscriptionReceived(String deltaText) {
    setState(() {
      _transcriptionText += deltaText;
    });
  }

  @override
  void dispose() {
    _recorder.closeRecorder();
    _player.closePlayer();
    _channel.sink.close(status.goingAway);

    if (_audioStreamController != null) {
      _audioStreamController!.close();
    }

    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          children: <Widget>[
            Text(
              _isRecording
                  ? 'Recording...'
                  : 'Press the button to start recording',
              style: TextStyle(fontSize: 20),
            ),
            SizedBox(height: 20),
            ElevatedButton(
              onPressed: _isRecording ? _stopRecording : _startRecording,
              child:
                  Text(_isRecording ? 'Stop Recording' : 'Start Recording'),
            ),
            SizedBox(height: 20),
            Expanded(
              child: SingleChildScrollView(
                child: Text(
                  _transcriptionText,
                  style: TextStyle(fontSize: 18),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
