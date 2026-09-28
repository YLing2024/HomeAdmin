// OAuth2 PKCE（RFC 7636）纯逻辑：verifier / challenge / state 的生成与校验。
//
// 这里只做无副作用的计算，不碰网络与存储，便于单测（见 test/pkce_test.dart）。
// 登录流程本身见 lib/auth.dart。

import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';

/// code_verifier 的合法字符集（RFC 7636 §4.1）：`[A-Za-z0-9-._~]`，长度 43-128。
final RegExp kCodeVerifierPattern = RegExp(r'^[A-Za-z0-9\-._~]{43,128}$');

/// 生成 code_verifier：32 随机字节做 base64url（无填充）= 43 个字符，
/// 落在 RFC 允许的字符集与长度区间内。
///
/// [random] 仅供测试注入确定性随机源；生产用 [Random.secure]。
String generateCodeVerifier([Random? random]) {
  final rng = random ?? Random.secure();
  final bytes = List<int>.generate(32, (_) => rng.nextInt(256));
  return _base64UrlNoPad(bytes);
}

/// 计算 S256 code_challenge：`BASE64URL(SHA256(ASCII(verifier)))`，去掉 `=` 填充。
String codeChallengeS256(String verifier) {
  final digest = sha256.convert(utf8.encode(verifier));
  return _base64UrlNoPad(digest.bytes);
}

/// 生成 `state`：24 随机字节（192 bit）base64url，用于防 CSRF / 授权码注入。
String generateState([Random? random]) {
  final rng = random ?? Random.secure();
  final bytes = List<int>.generate(24, (_) => rng.nextInt(256));
  return _base64UrlNoPad(bytes);
}

/// 校验回调携带的 `state` 是否与发出的一致：缺失或不一致一律拒绝。
bool verifyState(String expected, String? received) =>
    expected.isNotEmpty && received != null && expected == received;

String _base64UrlNoPad(List<int> bytes) =>
    base64Url.encode(bytes).replaceAll('=', '');
