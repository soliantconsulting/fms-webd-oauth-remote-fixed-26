/**
 * Copy this file to oauth-config.js and edit the values for your deployment.
 * Remote scenario: the web server (webDNS) and FileMaker Server (fmsDNS) are different boxes.
 * This site is static HTML/JS — the browser cannot read a .env file; edit this object instead.
 */
var OAUTH_CONFIG = {
	/** Published WebDirect file name to open after OAuth (no .fmp12 extension). */
	dbName: 'OAuth_tester',
	/** FileMaker Server box: target of all API calls and the login form POST. */
	fmsDNS: 'your-filemaker-server.example.com',
	/** This web server box: X-FMS-Return-URL (popup mode) + post-login homeUrl. */
	webDNS: 'your-web-server.example.com',
	/** Provider name passed to getOAuthURL (must match the FMS OAuth config). */
	identityProvider: 'Microsoft',
	/** Start OAuth as soon as provider info loads (button remains for manual retry). */
	autoStartOAuth: false,
	/** Use a full-page redirect to the IdP instead of a popup (see README.txt). */
	useFullPageRedirect: false,
	/** loglevel verbosity: trace | debug | info | warn | error | silent. */
	logLevel: 'debug'
};
