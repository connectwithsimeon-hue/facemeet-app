import 'dart:html' as html;

Future<bool> openStripeCheckoutUrl(String url) async {
  final now = DateTime.now().millisecondsSinceEpoch.toString();
  html.window.sessionStorage['facemeet_checkout_in_progress'] = 'true';
  html.window.sessionStorage['facemeet_checkout_started_at'] = now;
  html.window.localStorage['facemeet_checkout_in_progress'] = 'true';
  html.window.localStorage['facemeet_checkout_started_at'] = now;
  html.window.console.info('STRIPE RETURN: checkout flag set');
  html.window.location.assign(url);
  return true;
}
