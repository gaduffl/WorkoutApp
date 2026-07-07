import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:morningcoach/integrations/onedrive_client.dart';

void main() {
  test('PKCE: challenge is the S256 of the verifier, base64url without padding', () {
    final p = PkcePair.generate();
    expect(p.verifier, isNotEmpty);
    expect(p.verifier.contains('='), isFalse);
    expect(p.challenge.contains('='), isFalse);
    final expected = base64Url.encode(sha256.convert(utf8.encode(p.verifier)).bytes).replaceAll('=', '');
    expect(p.challenge, expected);
    // two generations differ (random verifier)
    expect(PkcePair.generate().verifier, isNot(p.verifier));
  });

  test('authorization URL carries client id, PKCE S256 challenge, redirect and scopes', () {
    const c = OneDriveClient();
    final url = c.buildAuthorizationUrl(state: 'state123', codeChallenge: 'challengeXYZ');
    expect(url.origin + url.path, OneDriveClient.authorizationEndpoint);
    expect(url.queryParameters['client_id'], OneDriveClient.clientId);
    expect(url.queryParameters['response_type'], 'code');
    expect(url.queryParameters['redirect_uri'], 'msal29d50c5e-c912-4a00-8de0-99c0f8e8c44d://auth');
    expect(url.queryParameters['code_challenge'], 'challengeXYZ');
    expect(url.queryParameters['code_challenge_method'], 'S256');
    expect(url.queryParameters['state'], 'state123');
    expect(url.queryParameters['scope'], contains('Files.ReadWrite.AppFolder'));
    expect(url.queryParameters['scope'], contains('offline_access'));
  });
}
