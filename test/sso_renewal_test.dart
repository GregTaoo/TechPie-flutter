import 'package:flutter_test/flutter_test.dart';
import 'package:techpie/services/auth_service.dart';
import 'package:techpie/services/uni_auth_service.dart';

void main() {
  // A Casdoor access token response as this instance actually answers it: the
  // lifetime is `expires_in` seconds, and there is no `expires_at` field.
  final now = DateTime.utc(2026, 9, 20, 12);

  group('reading the expiry out of a token response', () {
    test('expires_in becomes an absolute time', () {
      final expiry = UniAuthService.expiryFromTokenResponse(
        const {'expires_in': 604800},
        now,
      );

      expect(DateTime.parse(expiry!), now.add(const Duration(days: 7)));
    });

    test('a response without expires_in falls back to expires_at', () {
      expect(
        UniAuthService.expiryFromTokenResponse(
          const {'expires_at': '2026-10-01T00:00:00Z'},
          now,
        ),
        '2026-10-01T00:00:00Z',
      );
      expect(UniAuthService.expiryFromTokenResponse(const {}, now), isNull);
      expect(
        UniAuthService.expiryFromTokenResponse(const {'expires_in': '0'}, now),
        isNull,
      );
    });
  });

  group('when a refresh token is worth spending', () {
    test('an expiry that cannot be read renews', () {
      expect(
        AuthService.needsRenewal(null, now, AuthService.renewWindow),
        isTrue,
      );
      expect(
        AuthService.needsRenewal('not a date', now, AuthService.renewWindow),
        isTrue,
      );
    });

    test('a token expiring inside the window renews', () {
      expect(
        AuthService.needsRenewal(
          now.add(const Duration(hours: 6)).toIso8601String(),
          now,
          AuthService.renewWindow,
        ),
        isTrue,
      );
    });

    test('the seven day token this instance issues is left alone', () {
      expect(
        AuthService.needsRenewal(
          now.add(const Duration(days: 7)).toIso8601String(),
          now,
          AuthService.renewWindow,
        ),
        isFalse,
      );
    });
  });
}
