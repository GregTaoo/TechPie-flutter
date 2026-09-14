/// Named route paths (PRODUCT_SPEC §2).
abstract final class GpRoutes {
  static const login = '/login';
  static const sessionRestore = '/session/restore';
  static const bindCard = '/bind/card';
  static const pay = '/pay';
  static const transactions = '/transactions';
  static const me = '/me';
  static const offline = '/offline';
  static const widgetSetup = '/widget';

  static String transactionDetail(String id) => '$transactions/$id';
}
