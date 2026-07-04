/**
 * The three Claris WebDirect OAuth API primitives, adapted for the remote scenario:
 * every FMS-directed URL is absolute (https://<fmsDNS>...), and the OAuth return URL
 * points at this web server (webDNS) so the Claris X-FMS-Return-URL cross-origin fix
 * brings the user/popup back to our pages. See README.md and oauth-flow.js.
 */

function getProviderInfo(fmsDNS, callback) {
	var xhr = new XMLHttpRequest();
	var server = 'https://' + fmsDNS;
	xhr.onreadystatechange = function () {
		if (xhr.readyState == 4) {
			var providerInfo = null;
			if (xhr.status == 200 && xhr.responseText != null && xhr.responseText != '') {
				providerInfo = xhr.responseText;
			}
			if (callback) {
				callback(providerInfo);
			}
		}
	};
	xhr.open('GET', server + '/fmi/webd/oauthapi/oauthproviderinfo', true);
	xhr.send();
}

/**
 * Where FMS should send the user/popup once the IdP handshake is done.
 * Popup mode: our landing page on webDNS (writes localStorage; parent hears storage event).
 * Full-page mode: this page's own URL on webDNS (result arrives in the query string).
 */
function getOAuthReturnUrl() {
	if (OAUTH_CONFIG.useFullPageRedirect) {
		return window.location.origin + window.location.pathname;
	}
	return 'https://' + OAUTH_CONFIG.webDNS + '/oauth-landing.html';
}

function getOAuthURL(trackingId, fmsDNS, provider, callback) {
	var xhr, queryStr;
	var fmsUrl = 'https://' + fmsDNS;
	xhr = new XMLHttpRequest();
	xhr.onreadystatechange = function () {
		if (xhr.readyState == 4) {
			if (callback) {
				if (xhr.status == 200 && xhr.responseText != null && xhr.responseText != '') {
					callback(xhr.responseText, xhr.getResponseHeader('X-FMS-Request-ID'));
				} else {
					callback(null, null);
				}
			}
		}
	};
	queryStr = 'trackingID=' + trackingId + '&provider=' + provider + '&address=' + fmsDNS + '&X-FMS-OAuth-AuthType=2';
	xhr.open('GET', fmsUrl + '/fmi/webd/oauthapi/getoauthurl?' + queryStr, true);
	xhr.setRequestHeader('X-FMS-Application-Type', '8');
	xhr.setRequestHeader('X-FMS-Return-URL', getOAuthReturnUrl());
	xhr.send();
}

function doOAuthLogin(dbName, requestId, identifier, homeurl, autherr, fmsDNS) {
	var form, node, queryStr;
	var server = 'https://' + fmsDNS;

	form = document.createElement('form');
	form.style.display = 'none';
	form.action = server + '/fmi/webd/' + encodeURIComponent(dbName);
	form.method = 'POST';
	form.target = '_self';

	node = document.createElement('input');
	node.type = 'text';
	node.name = 'user';
	node.value = requestId;
	form.appendChild(node.cloneNode());

	node = document.createElement('input');
	node.type = 'text';
	node.name = 'pwd';
	node.value = identifier;
	form.appendChild(node.cloneNode());

	queryStr = 'lgcnt=1&oauth=1';
	if (homeurl != '') {
		queryStr += ('&homeurl=' + homeurl);
	}
	if (autherr != '') {
		queryStr += ('&autherr=' + autherr);
	}

	if (queryStr != '') {
		form.action += ('?' + queryStr);
	}

	document.body.appendChild(form);
	form.submit();
	document.body.removeChild(form);
}
