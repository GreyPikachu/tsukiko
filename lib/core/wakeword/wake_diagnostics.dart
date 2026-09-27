import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../../platform/os.dart' show appVersion, os;
import '../library.dart' show supportDir;
import 'personal_keyword_spotter.dart';

/// An explicit, local developer session. It records the same PCM frames that
/// reach the keyword detector, with sample-aligned scores and user marks.
class WakeDiagnosticsSession {
  WakeDiagnosticsSession._(this.directory, this._audio, this._events);

  static const sampleRate = 16000;
  static const maxSamples = sampleRate * 60 * 20;

  final String directory;
  final RandomAccessFile _audio;
  final IOSink _events;
  int samples = 0;
  bool _closed = false;

  static WakeDiagnosticsSession start({
    required String wakeWord,
    required String closeWord,
    required String detector,
    String? root,
  }) {
    final base = Directory(root ?? os.join(supportDir, 'wake-diagnostics'));
    base.createSync(recursive: true);
    final stamp = DateTime.now()
        .toUtc()
        .toIso8601String()
        .replaceAll(':', '-')
        .replaceAll('.', '-');
    final dir = Directory(os.join(base.path, stamp));
    dir.createSync();
    File(os.join(dir.path, 'metadata.json')).writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert({
        'version': appVersion,
        'startedAtUtc': DateTime.now().toUtc().toIso8601String(),
        'sampleRate': sampleRate,
        'channels': 1,
        'wakeWord': wakeWord,
        'closeWord': closeWord,
        'detector': detector,
        'maxMinutes': 20,
      }),
    );
    final audio = File(
      os.join(dir.path, 'audio.wav'),
    ).openSync(mode: FileMode.write);
    audio.writeFromSync(_wavHeader(0));
    final events = File(os.join(dir.path, 'events.jsonl')).openWrite();
    final session = WakeDiagnosticsSession._(dir.path, audio, events);
    session.event('start');
    return session;
  }

  double get seconds => samples / sampleRate;

  void recordAudio(Float32List pcm) {
    if (_closed || pcm.isEmpty) return;
    final bytes = ByteData(pcm.length * 2);
    for (var i = 0; i < pcm.length; i++) {
      bytes.setInt16(
        i * 2,
        (pcm[i] * 32768).round().clamp(-32768, 32767),
        Endian.little,
      );
    }
    _audio.writeFromSync(bytes.buffer.asUint8List());
    samples += pcm.length;
    // Keep a usable WAV even if the app is interrupted before Stop is tapped.
    if (samples % (sampleRate * 10) < pcm.length) _updateHeader();
  }

  void score(KeywordScore value) => event('score', value.toJson());

  void mark(String word) => event('mark', {'word': word});

  void event(String type, [Map<String, Object?> details = const {}]) {
    if (_closed) return;
    _events.writeln(
      jsonEncode({
        'type': type,
        'sample': samples,
        'seconds': seconds,
        'timeUtc': DateTime.now().toUtc().toIso8601String(),
        ...details,
      }),
    );
  }

  void _updateHeader() {
    final end = _audio.positionSync();
    _audio.setPositionSync(0);
    _audio.writeFromSync(_wavHeader(samples * 2));
    _audio.setPositionSync(end);
    _audio.flushSync();
  }

  Future<void> stop() async {
    if (_closed) return;
    event('stop');
    _closed = true;
    _updateHeader();
    _audio.closeSync();
    await _events.flush();
    await _events.close();
  }

  static Uint8List _wavHeader(int dataBytes) {
    final out = ByteData(44);
    void tag(int at, String value) {
      for (var i = 0; i < value.length; i++) {
        out.setUint8(at + i, value.codeUnitAt(i));
      }
    }

    tag(0, 'RIFF');
    out.setUint32(4, 36 + dataBytes, Endian.little);
    tag(8, 'WAVE');
    tag(12, 'fmt ');
    out.setUint32(16, 16, Endian.little);
    out.setUint16(20, 1, Endian.little);
    out.setUint16(22, 1, Endian.little);
    out.setUint32(24, sampleRate, Endian.little);
    out.setUint32(28, sampleRate * 2, Endian.little);
    out.setUint16(32, 2, Endian.little);
    out.setUint16(34, 16, Endian.little);
    tag(36, 'data');
    out.setUint32(40, dataBytes, Endian.little);
    return out.buffer.asUint8List();
  }
}
