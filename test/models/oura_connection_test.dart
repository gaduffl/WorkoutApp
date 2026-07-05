import 'package:flutter_test/flutter_test.dart';
import 'package:morningcoach/models/oura_connection.dart';

void main() {
  test('unconfigured by default', () {
    const oura = OuraConnection();
    expect(oura.isConfigured, isFalse);
    expect(oura.isConnected, isFalse);
  });

  test('configured once both client id and secret are set', () {
    const oura = OuraConnection(clientId: 'abc', clientSecret: 'xyz');
    expect(oura.isConfigured, isTrue);
    expect(oura.isConnected, isFalse);
  });

  test('connected once an access token is present', () {
    final oura = OuraConnection(
      clientId: 'abc',
      clientSecret: 'xyz',
      accessToken: 'token',
      accessTokenExpiresAt: DateTime.now().add(const Duration(hours: 1)),
    );
    expect(oura.isConnected, isTrue);
    expect(oura.isExpired, isFalse);
  });

  test('treated as expired once past accessTokenExpiresAt, or if never set', () {
    final expired = OuraConnection(accessToken: 't', accessTokenExpiresAt: DateTime.now().subtract(const Duration(minutes: 1)));
    expect(expired.isExpired, isTrue);

    const noExpiry = OuraConnection(accessToken: 't');
    expect(noExpiry.isExpired, isTrue);
  });

  test('clearTokens drops tokens but keeps client id/secret', () {
    const oura = OuraConnection(clientId: 'abc', clientSecret: 'xyz', accessToken: 't', refreshToken: 'r');
    final cleared = oura.copyWith(clearTokens: true);
    expect(cleared.clientId, 'abc');
    expect(cleared.clientSecret, 'xyz');
    expect(cleared.accessToken, isNull);
    expect(cleared.refreshToken, isNull);
  });
}
