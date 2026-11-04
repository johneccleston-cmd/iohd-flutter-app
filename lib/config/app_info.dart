// The company and build details shown on the sign-in screen, in About and on printed PDFs.
// Keep kAppVersion in step with `version:` in pubspec.yaml, or override it at build time:
//   flutter build web --release --dart-define=APP_VERSION=1.2.0

const String kAppName = 'IOHD Office';

/// The legal name, for copyright and legal lines.
const String kCompanyName = 'Integrity Overhead Door, LLC';

/// The everyday name, for running text.
const String kCompanyBrand = 'Integrity Overhead Door';
/// Who staff contact when something in the app is wrong.
const String kSupportName = 'John Eccleston';
const String kSupportPhone = '(479) 334-3254';
const String kSupportEmail = 'john.eccleston@integritydoornwa.com';

const String kAppVersion = String.fromEnvironment('APP_VERSION', defaultValue: '1.0.0');

/// "© 2026 Integrity Overhead Door, LLC", always the current year.
String copyrightLine() => '© ${DateTime.now().year} $kCompanyName';
