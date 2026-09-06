import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
      'both native platforms share short PCM sounds and matching pulse timelines',
      () {
    final patterns = jsonDecode(
      File('assets/campus_card/data/feedback_patterns.json').readAsStringSync(),
    ) as Map<String, dynamic>;
    expect(
      patterns.keys,
      containsAll(['paymentSuccess', 'networkDisconnected']),
    );
    for (final entry in patterns.entries) {
      final pattern = entry.value as Map<String, dynamic>;
      final bytes = File(pattern['audio'] as String).readAsBytesSync();
      final data = ByteData.sublistView(bytes);
      expect(ascii.decode(bytes.sublist(0, 4)), 'RIFF');
      expect(ascii.decode(bytes.sublist(8, 12)), 'WAVE');
      expect(data.getUint16(20, Endian.little), 1);
      expect(data.getUint16(22, Endian.little), 1);
      expect(data.getUint32(24, Endian.little), 44100);
      expect(data.getUint16(34, Endian.little), 16);
      var offset = 12;
      var pcmBytes = 0;
      while (offset + 8 <= bytes.length) {
        final size = data.getUint32(offset + 4, Endian.little);
        if (ascii.decode(bytes.sublist(offset, offset + 4)) == 'data') {
          pcmBytes = size;
          break;
        }
        offset += 8 + size + size % 2;
      }
      final durationMs = pcmBytes / (44100 * 2) * 1000;
      expect(durationMs, inInclusiveRange(900, 1500));
      expect(
        (pattern['durationMs'] as num) - durationMs,
        inInclusiveRange(0, 2),
      );
      var end = 0;
      for (final value in pattern['pulses'] as List) {
        final pulse = value as Map<String, dynamic>;
        final at = pulse['atMs'] as int;
        expect(at, greaterThanOrEqualTo(end));
        end = at + (pulse['durationMs'] as int);
        expect(end, lessThan(durationMs));
        expect(pulse['intensity'], inInclusiveRange(0, 1));
      }
    }
  });
}
