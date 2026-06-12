import 'dart:async';
import 'dart:js_util' as js_util;

class InstallGateContext {
  final bool isMobile;
  final bool isStandalone;
  final bool isIos;
  final bool isAndroid;
  final bool canPromptInstall;
  final bool continueInBrowser;
  final String pendingReferralCode;

  const InstallGateContext({
    required this.isMobile,
    required this.isStandalone,
    required this.isIos,
    required this.isAndroid,
    required this.canPromptInstall,
    required this.continueInBrowser,
    required this.pendingReferralCode,
  });

  bool get isDesktop => !isMobile;
  bool get shouldShowInstallGate =>
      isMobile && !isStandalone && !continueInBrowser;
}

class InstallPromptResult {
  final bool prompted;
  final String outcome;

  const InstallPromptResult({required this.prompted, required this.outcome});
}

class InstallGateService {
  InstallGateService._();

  static final InstallGateService instance = InstallGateService._();

  Future<InstallGateContext> currentContext() async {
    final raw = await _callJsPromise('facemeetGetInstallContext');
    final map = _toMap(raw);
    return InstallGateContext(
      isMobile: map['isMobile'] == true,
      isStandalone: map['isStandalone'] == true,
      isIos: map['isIos'] == true,
      isAndroid: map['isAndroid'] == true,
      canPromptInstall: map['canPromptInstall'] == true,
      continueInBrowser: map['continueInBrowser'] == true,
      pendingReferralCode: map['pendingReferralCode']?.toString() ?? '',
    );
  }

  Future<bool> shouldGateInstallFirst() async {
    final context = await currentContext();
    return context.shouldShowInstallGate;
  }

  Future<InstallPromptResult> promptInstall() async {
    final raw = await _callJsPromise('facemeetPromptInstall');
    final map = _toMap(raw);
    return InstallPromptResult(
      prompted: map['prompted'] == true,
      outcome: map['outcome']?.toString() ?? 'unknown',
    );
  }

  Future<void> allowContinueInBrowserForSession() async {
    js_util.callMethod(
      js_util.globalThis,
      'facemeetAllowContinueInBrowser',
      [],
    );
  }

  Future<String> getPendingReferralCode() async {
    final raw = await _callJsPromise('facemeetGetPendingReferralCode');
    return raw?.toString() ?? '';
  }

  Future<dynamic> _callJsPromise(String method) async {
    final result = js_util.callMethod(js_util.globalThis, method, []);
    return js_util.promiseToFuture<dynamic>(result);
  }

  Map<String, dynamic> _toMap(dynamic object) {
    if (object == null) return const {};
    final keys = js_util.objectKeys(object);
    final map = <String, dynamic>{};
    for (final key in keys) {
      final stringKey = key.toString();
      map[stringKey] = js_util.getProperty(object, stringKey);
    }
    return map;
  }
}
