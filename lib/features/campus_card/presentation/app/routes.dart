/// Named route paths (PRODUCT_SPEC §2).
abstract final class GpRoutes {
  static const login = '/login';
  static const bindCard = '/bind/card';
  static const pay = '/pay';
  static const transactions = '/transactions';
  static const me = '/me';
  static const offline = '/offline';

  static String transactionDetail(String id) => '$transactions/$id';
}
