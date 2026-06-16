/**
 * Feature flags + deployment settings for the OAuth demo.
 * Remote scenario: the web server (webDNS) and FileMaker Server (fmsDNS) are different boxes.
 * Copy oauth-config.example.js to this file and edit for your deployment.
 */
var OAUTH_CONFIG = {
	/** Published WebDirect file name to open after OAuth (no .fmp12 extension). */
	dbName: 'OAuth_tester',
	/** FileMaker Server box: target of all API calls and the login form POST. */
	fmsDNS: 'mbp2013.ets.fm',
	/** This web server box: X-FMS-Return-URL (popup mode) + post-login homeUrl. */
	webDNS: 'webdlogin.ets.fm',
	/** Provider name passed to getOAuthURL (must match the FMS OAuth config). */
	identityProvider: 'Microsoft',
	/** Start OAuth as soon as provider info loads (button remains for manual retry). */
	autoStartOAuth: false,
	/** Use a full-page redirect to the IdP instead of a popup (see README.txt). */
	useFullPageRedirect: false,
	/** loglevel verbosity: trace | debug | info | warn | error | silent. */
	logLevel: 'debug'
};
