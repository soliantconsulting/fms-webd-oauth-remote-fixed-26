/**
 * Page glue for index.html: set logging, resume a full-page redirect if we are
 * returning from the IdP, otherwise render the Member Login button. Completes the
 * login by POSTing to FileMaker Server (fmsDNS) and sending the user home on this page's origin.
 */

var OAUTH_ERROR_MESSAGES = {
	'1627': 'You signed in with Microsoft, but this account isn’t authorized to open this database. Contact your administrator to confirm your access.',
	'default': 'Sign-in didn’t complete. Please try again, or contact your administrator if the problem continues.'
};

function oauthErrorMessage(result) {
	var code = result.loginerr || result.error;
	if (code && OAUTH_ERROR_MESSAGES[code]) {
		return OAUTH_ERROR_MESSAGES[code];
	}
	return OAUTH_ERROR_MESSAGES['default'];
}

function renderLoginButton(providerInfo) {
	if (document.getElementById('oauth-login-btn')) {
		return;
	}

	var oauthWrapper = document.getElementById('inner');
	var providerName = getIdentityProviderName();
	var button = document.createElement('button');

	button.id = 'oauth-login-btn';
	button.innerHTML = 'Member Login';
	button.style.width = '350px';
	button.style.height = '60px';
	button.style.textAlign = 'center';
	if (providerInfo) {
		button.dataset.provider = providerInfo;
	}
	button.onclick = function () {
		showOAuthLogin(providerName);
	};

	oauthWrapper.appendChild(button);
}

function showOAuthError(result) {
	var wrapper = document.getElementById('inner');
	var existing = document.getElementById('oauth-message');
	if (existing) {
		existing.parentNode.removeChild(existing);
	}

	var box = document.createElement('div');
	box.id = 'oauth-message';
	box.style.position = 'relative';
	box.style.margin = '1.5em auto';
	box.style.maxWidth = '600px';
	box.style.padding = '1em 2.5em 1em 1.25em';
	box.style.borderLeft = '4px solid #e8505b';
	box.style.background = 'rgba(232, 80, 91, 0.12)';
	box.style.textAlign = 'left';
	box.style.borderRadius = '4px';

	var close = document.createElement('button');
	close.type = 'button';
	close.setAttribute('aria-label', 'Dismiss');
	close.textContent = '×';
	close.style.position = 'absolute';
	close.style.top = '0.35em';
	close.style.right = '0.5em';
	close.style.width = '1.4em';
	close.style.height = '1.4em';
	close.style.padding = '0';
	close.style.lineHeight = '1';
	close.style.border = '0';
	close.style.background = 'transparent';
	close.style.color = 'inherit';
	close.style.fontSize = '1.4em';
	close.style.cursor = 'pointer';
	close.onclick = function () {
		if (box.parentNode) {
			box.parentNode.removeChild(box);
		}
	};
	box.appendChild(close);

	var msg = document.createElement('p');
	msg.style.margin = '0 0 0.5em 0';
	msg.textContent = oauthErrorMessage(result);
	box.appendChild(msg);

	var detailBits = [];
	if (result.loginerr) {
		detailBits.push('FileMaker error ' + result.loginerr);
	} else if (result.error) {
		detailBits.push('Error ' + result.error);
	}
	if (result.trackingID) {
		detailBits.push('Tracking ID ' + result.trackingID);
	}
	if (detailBits.length) {
		var detail = document.createElement('small');
		detail.style.opacity = '0.7';
		detail.textContent = detailBits.join(' · ');
		box.appendChild(detail);
	}

	wrapper.appendChild(box);
	renderLoginButton();
}

function completeIndexOAuth(result) {
	if (isOAuthErrorResponse(result)) {
		showOAuthError(result);
		return;
	}
	doOAuthLogin(
		OAUTH_CONFIG.dbName,
		result.requestId,
		result.identifier,
		// Home URL follows the origin this page is actually served from, so the same
		// files work under any allowed webDNS host (must be on the FMS OAuth Allow List).
		window.location.origin + '/index.html',
		result.error,
		OAUTH_CONFIG.fmsDNS
	);
}

function showOAuthLogin(providerName) {
	runOAuthLogin(providerName, completeIndexOAuth);
}

function initOAuth() {
	log.setLevel(OAUTH_CONFIG.logLevel);
	log.debug('config:', OAUTH_CONFIG);

	if (resumeOAuthAfterRedirect(completeIndexOAuth)) {
		return;
	}

	getProviderInfo(OAUTH_CONFIG.fmsDNS, function (providerInfo) {
		if (providerInfo != null && providerInfo != '') {
			renderLoginButton(providerInfo);

			if (shouldAutoStartOAuth()) {
				showOAuthLogin(getIdentityProviderName());
			}
		}
	});
}
