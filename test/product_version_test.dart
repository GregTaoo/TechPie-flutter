import 'package:flutter_test/flutter_test.dart';
import 'package:techpie/utils/product_version.dart';

void main() {
  group('tryParse', () {
    test('reads the shapes we publish, and nothing else', () {
      // pubspec's version line, a release name, a candidate tag, a legacy tag.
      expect(ProductVersion.tryParse('1.0.1+5'), const ProductVersion(1, 0, 1));
      expect(ProductVersion.tryParse('1.0.1-rc.2'), const ProductVersion(1, 0, 1, 2));
      expect(ProductVersion.tryParse('v1.0.1-rc.2+5'), const ProductVersion(1, 0, 1, 2));
      expect(ProductVersion.tryParse('android-v1.0.0-rc.1+3'), const ProductVersion(1, 0, 0, 1));
      expect(ProductVersion.tryParse(' v1.0.0+12 '), const ProductVersion(1, 0, 0));

      // A shape we do not know is not a version we may act on: an "update" that
      // is not one is worse than no update.
      expect(ProductVersion.tryParse(''), isNull);
      expect(ProductVersion.tryParse('latest'), isNull);
      expect(ProductVersion.tryParse('v1.0'), isNull);
      expect(ProductVersion.tryParse('1.0.1.2+5'), isNull);
      expect(ProductVersion.tryParse('1.0.1-beta.1'), isNull);
      expect(ProductVersion.tryParse('1.0.1+'), isNull);
    });
  });

  group('ordering', () {
    test('the build number is not part of the version', () {
      expect(ProductVersion.tryParse('1.0.1+5'), ProductVersion.tryParse('1.0.1+6'));
      expect(ProductVersion.tryParse('v1.0.1+6')!.isNewerThan(ProductVersion.tryParse('1.0.1+5')!), isFalse);
    });

    test('a stable release outranks every candidate of itself', () {
      expect(ProductVersion.tryParse('1.0.1-rc.2')!.isNewerThan(ProductVersion.tryParse('1.0.1')!), isFalse);
      expect(ProductVersion.tryParse('1.0.1')!.isNewerThan(ProductVersion.tryParse('1.0.1-rc.2')!), isTrue);
    });

    test('candidates of one version order by number, not as text', () {
      expect(ProductVersion.tryParse('1.0.1-rc.10')!.isNewerThan(ProductVersion.tryParse('1.0.1-rc.2')!), isTrue);
      expect(ProductVersion.tryParse('1.0.1-rc.2')!.isNewerThan(ProductVersion.tryParse('1.0.1-rc.1')!), isTrue);
    });

    test('more than one field has to lose before a version is not newer', () {
      expect(ProductVersion.tryParse('1.0.2-rc.1')!.isNewerThan(ProductVersion.tryParse('1.0.1')!), isTrue);
      expect(ProductVersion.tryParse('1.1.0')!.isNewerThan(ProductVersion.tryParse('1.0.9')!), isTrue);
      expect(ProductVersion.tryParse('2.0.0')!.isNewerThan(ProductVersion.tryParse('1.99.99')!), isTrue);
      expect(ProductVersion.tryParse('1.0.0')!.isNewerThan(ProductVersion.tryParse('1.0.1')!), isFalse);
    });

    test('orders a sequence the way the release policy reads it', () {
      final sequence = [
        '1.0.0-rc.1',
        '1.0.0-rc.2',
        '1.0.0',
        '1.0.1-rc.1',
        '1.0.1-rc.2',
        '1.0.1',
      ].map((t) => ProductVersion.tryParse(t)!).toList();
      for (var i = 1; i < sequence.length; i++) {
        expect(sequence[i].isNewerThan(sequence[i - 1]), isTrue, reason: '${sequence[i]} > ${sequence[i - 1]}');
      }
      expect(sequence.first.isNewerThan(sequence.last), isFalse);
    });
  });

  test('renders back as a release name', () {
    expect(ProductVersion.tryParse('v1.0.1-rc.2+5').toString(), '1.0.1-rc.2');
    expect(ProductVersion.tryParse('1.0.1+5').toString(), '1.0.1');
  });
}
