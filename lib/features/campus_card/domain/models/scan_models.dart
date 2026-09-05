import '../money_fen.dart';

enum ScanSuccessKind { payment, attendance, openDevice, bindTray, unknown }

sealed class ScanPaymentResult {
  const ScanPaymentResult();
}

final class ScanPasswordRequired extends ScanPaymentResult {
  const ScanPasswordRequired({required this.serverQrCode});
  final String serverQrCode;
}

final class ScanSucceeded extends ScanPaymentResult {
  const ScanSucceeded({
    required this.kind,
    this.amount,
    this.fee,
    this.balance,
    this.message,
  });

  final ScanSuccessKind kind;
  final MoneyFen? amount;
  final MoneyFen? fee;
  final MoneyFen? balance;
  final String? message;
}

final class ScanFailed extends ScanPaymentResult {
  const ScanFailed({required this.message, this.code});
  final String message;
  final String? code;
}

enum ScanFlowPhase { idle, submitting, passwordRequired, succeeded, failed }

final class ScanFlowState {
  const ScanFlowState({
    required this.phase,
    this.pendingServerQrCode,
    this.success,
    this.message,
  });

  const ScanFlowState.idle()
      : phase = ScanFlowPhase.idle,
        pendingServerQrCode = null,
        success = null,
        message = null;

  final ScanFlowPhase phase;
  final String? pendingServerQrCode;
  final ScanSucceeded? success;
  final String? message;
}
