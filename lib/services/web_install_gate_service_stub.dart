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
    return const InstallGateContext(
      isMobile: false,
      isStandalone: false,
      isIos: false,
      isAndroid: false,
      canPromptInstall: false,
      continueInBrowser: false,
      pendingReferralCode: '',
    );
  }

  Future<bool> shouldGateInstallFirst() async => false;

  Future<InstallPromptResult> promptInstall() async {
    return const InstallPromptResult(prompted: false, outcome: 'unsupported');
  }

  Future<void> allowContinueInBrowserForSession() async {}

  Future<String> getPendingReferralCode() async => '';
}
