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
        final payload = jsonEncode(record['payload']);
        logger.log(
          method: record['method']! as String,
          url: record['url']! as String,
          statusCode: record['statusCode'] as int?,
          requestBody: isRequest ? payload : null,
          responseBody: isRequest ? null : payload,
          error: record['dioExceptionType'] as String?,
          tag: 'Campus Card',
        );
      },
    );
