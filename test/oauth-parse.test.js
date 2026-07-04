'use strict';

var fs = require('fs');
var vm = require('vm');
var path = require('path');

// Load the browser script into an isolated context. Its top level is only
// var/function declarations, so evaluating it runs no DOM-touching code.
var code = fs.readFileSync(path.join(__dirname, '..', 'assets', 'js', 'oauth-flow.js'), 'utf8');
var ctx = {};
vm.createContext(ctx);
vm.runInContext(code, ctx);

var failures = 0;
function check(label, actual, expected) {
	var ok = actual === expected;
	if (!ok) { failures++; }
	console.log((ok ? 'PASS ' : 'FAIL ') + label + (ok ? '' : ' (got ' + JSON.stringify(actual) + ', expected ' + JSON.stringify(expected) + ')'));
}

// Real landing query strings captured in the HAR (query part only, no leading '?').
var tripleQ = 'lgcnt=1&oauth=1&homeurl=https://wim.ets.fm/index.html&autherr=-1&db=OAuth_tester&loginerr=1627&guesten=0&hidelocalaccountentry=0?trackingID=123432&identifier=-1&hiddenemail=false&error=-1?trackingID=123432&identifier=-1&hiddenemail=false&error=-1';
var doubleQ = 'lgcnt=1&oauth=1&homeurl=https://wim.ets.fm/index.html&autherr=-1&db=OAuth_tester&loginerr=1627&guesten=0&hidelocalaccountentry=0?trackingID=123432&identifier=-1&hiddenemail=false&error=-1';
var success = 'trackingID=123432&identifier=ABCDEF0123456789TOKEN&error=';
var cleanError = 'trackingID=123432&identifier=-1&error=-1';

var t = ctx.parseOAuthResponse(tripleQ);
check('triple ? trackingID', t.trackingID, '123432');
check('triple ? identifier', t.identifier, '-1');
check('triple ? error', t.error, '-1');
check('triple ? loginerr', t.loginerr, '1627');
check('triple ? isError', ctx.isOAuthErrorResponse(t), true);

var d = ctx.parseOAuthResponse(doubleQ);
check('double ? trackingID', d.trackingID, '123432');
check('double ? loginerr', d.loginerr, '1627');
check('double ? isError', ctx.isOAuthErrorResponse(d), true);

var s = ctx.parseOAuthResponse(success);
check('success identifier', s.identifier, 'ABCDEF0123456789TOKEN');
check('success error', s.error, '');
check('success isError', ctx.isOAuthErrorResponse(s), false);

check('cleanError isError', ctx.isOAuthErrorResponse(ctx.parseOAuthResponse(cleanError)), true);

if (failures > 0) {
	console.log('\n' + failures + ' failure(s)');
	process.exit(1);
}
console.log('\nAll parser tests passed');
