import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:home_admin/pkce.dart';

void main() {
  group('generateCodeVerifier', () {
    test('长度为 43、字符集合法（RFC 7636 §4.1）', () {
      final v = generateCodeVerifier();
      expect(v.length, 43);
      expect(kCodeVerifierPattern.hasMatch(v), isTrue, reason: v);
    });

    test('注入确定性随机源时可复现', () {
      final a = generateCodeVerifier(Random(1));
      final b = generateCodeVerifier(Random(1));
      expect(a, b);
    });

    test('不同随机源产生不同 verifier（极低碰撞概率）', () {
      expect(generateCodeVerifier(Random(1)), isNot(generateCodeVerifier(Random(2))));
    });
  });

  group('codeChallengeS256', () {
    // RFC 7636 Appendix B 的官方测试向量
    test('匹配 RFC 7636 测试向量', () {
      const verifier = 'dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk';
      expect(codeChallengeS256(verifier), 'E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM');
    });

    test('challenge 使用 base64url 且无填充', () {
      final c = codeChallengeS256(generateCodeVerifier());
      expect(c.contains('='), isFalse);
      expect(RegExp(r'^[A-Za-z0-9\-_]{43}$').hasMatch(c), isTrue, reason: c);
    });

    test('相同 verifier 恒定输出', () {
      const v = 'abcdefghijklmnopqrstuvwxyz-._~0123456789ABCDEF';
      expect(codeChallengeS256(v), codeChallengeS256(v));
    });
  });

  group('generateState / verifyState', () {
    test('state 每次不同且无填充', () {
      final s1 = generateState();
      final s2 = generateState();
      expect(s1, isNot(s2));
      expect(s1.contains('='), isFalse);
      expect(s1.isNotEmpty, isTrue);
    });

    test('一致时通过', () {
      final s = generateState();
      expect(verifyState(s, s), isTrue);
    });

    test('缺失或不一致时拒绝（防 CSRF / 授权码注入）', () {
      final s = generateState();
      expect(verifyState(s, null), isFalse);
      expect(verifyState(s, generateState()), isFalse);
      expect(verifyState('', ''), isFalse);
    });
  });
}
