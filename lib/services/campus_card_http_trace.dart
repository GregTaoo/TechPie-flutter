import 'dart:convert';

import '../features/campus_card/data/api/decrypted_http_trace.dart';
import 'debug_logger.dart';

/// Sends the feature's existing request trace to TechPie's shared debug log.
/// The logger's live switch and redaction apply to both auth and card requests.
DecryptedHttpTraceInterceptor campusCardHttpTrace(DebugLogger logger) =>
    DecryptedHttpTraceInterceptor(
      enabled: () => logger.enabled,
      onRecord: (record) {
        final isRequest = record['event'] == 'request';
        final fingerprint = record['qrcodeFingerprint'];
        final raw = record['payload'];
        // Scan payments log a length/digest pair so both phases can be
        // compared without writing the code itself.
        final payload = fingerprint == null || raw is! Map
            ? raw
            : <String, Object?>{
                ...raw.cast<String, Object?>(),
                'qrcodeFingerprint': fingerprint,
              };
        logger.log(
          method: record['method']! as String,
          url: record['url']! as String,
          statusCode: record['statusCode'] as int?,
          requestBody: isRequest ? jsonEncode(payload) : null,
          responseBody: isRequest ? null : jsonEncode(payload),
          error: record['dioExceptionType'] as String?,
          tag: 'Campus Card',
        );
      },
    );
