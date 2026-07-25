import 'package:aml/src/features/accounts/ui/msa_login_dialog.dart';
import 'package:aml/src/rust/api/launcher.dart' as rust;
import 'package:flutter/material.dart';
import 'package:signals_flutter/signals_flutter.dart';

class AccountStore {
  AccountStore();

  final accounts = signal<List<rust.AccountDto>>([]);
  final yggdrasilServices = signal<List<rust.YggdrasilServiceDto>>([]);
  final error = signal<String?>(null);
  final microsoftLoginBusy = signal(false);
  final yggdrasilLoginBusy = signal(false);

  Future<void> refresh() async {
    try {
      final results = await Future.wait([
        rust.listAccounts(),
        rust.listYggdrasilServices(),
      ]);
      accounts.value = results[0] as List<rust.AccountDto>;
      yggdrasilServices.value = results[1] as List<rust.YggdrasilServiceDto>;
    } catch (e) {
      error.value = e.toString();
      debugPrint('listAccounts failed: $e');
    }
  }

  rust.AccountDto? get activeAccount {
    final list = accounts.value;
    for (final a in list) {
      if (a.active) return a;
    }
    return null;
  }

  Future<void> createOffline(String username) async {
    await rust.createOfflineAccount(username: username);
    await refresh();
  }

  Future<void> setActive(String id) async {
    await rust.setActiveAccount(id: id);
    await refresh();
  }

  Future<void> remove(String id) async {
    await rust.removeAccount(id: id);
    await refresh();
  }

  /// MSA login: in-app WebView, auto-capture redirect `code`.
  /// Returns `true` on success, `false` if cancelled.
  Future<bool> loginMicrosoft(BuildContext context) async {
    if (microsoftLoginBusy.value) return false;
    microsoftLoginBusy.value = true;
    error.value = null;
    try {
      final begin = await rust.beginMsaLogin();
      if (!context.mounted) return false;

      final redirectUrl = await MsaLoginDialog.show(
        context,
        authUrl: begin.authUrl,
      );
      if (redirectUrl == null || redirectUrl.isEmpty) return false;

      await rust.finishMsaLogin(
        loginId: begin.loginId,
        redirectUrl: redirectUrl,
      );
      await refresh();
      return true;
    } catch (e) {
      error.value = e.toString();
      debugPrint('loginMicrosoft failed: $e');
      rethrow;
    } finally {
      microsoftLoginBusy.value = false;
    }
  }

  Future<rust.YggdrasilLoginBeginDto> beginYggdrasilLogin({
    required String serviceId,
    required String username,
    required String password,
  }) async {
    if (yggdrasilLoginBusy.value) {
      throw StateError('外置登录正在进行中');
    }
    yggdrasilLoginBusy.value = true;
    error.value = null;
    try {
      return await rust.beginYggdrasilLogin(
        serviceId: serviceId,
        username: username,
        password: password,
      );
    } catch (e) {
      error.value = e.toString();
      rethrow;
    } finally {
      yggdrasilLoginBusy.value = false;
    }
  }

  Future<void> finishYggdrasilLogin({
    required String loginId,
    required String profileId,
  }) async {
    if (yggdrasilLoginBusy.value) return;
    yggdrasilLoginBusy.value = true;
    try {
      await rust.finishYggdrasilLogin(
        loginId: loginId,
        profileId: profileId,
      );
      await refresh();
    } finally {
      yggdrasilLoginBusy.value = false;
    }
  }
}
