import 'package:flutter_test/flutter_test.dart';
import 'package:techpie/services/campus_web_session.dart';

void main() {
  test('only the IDS session cookies count as owned by the native store', () {
    // The page skips exactly these when the store already holds the IDS login;
    // every other campus cookie (eams/elearning/egate sessions) must still be
    // injected, or those pages lose their own login.
    expect(CampusWebSession.isIdsSessionCookie('CASTGC', 'ids.shanghaitech.edu.cn'), isTrue);
    expect(CampusWebSession.isIdsSessionCookie('AUTHTGC', 'IDS.ShanghaiTech.edu.cn'), isTrue);
    expect(CampusWebSession.isIdsSessionCookie('JSESSIONID', 'ids.shanghaitech.edu.cn'), isFalse);
    expect(CampusWebSession.isIdsSessionCookie('CASTGC', 'egate.shanghaitech.edu.cn'), isFalse);
  });
}
