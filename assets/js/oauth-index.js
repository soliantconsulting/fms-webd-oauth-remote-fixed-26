/**
 * Page glue for index.html: set logging, resume a full-page redirect if we are
 * returning from the IdP, otherwise render the Member Login button. Completes the
 * login by POSTing to FileMaker Server (fmsDNS) and sending the user home on webDNS.
 */

function completeIndexOAuth(identifier, autherr, requestId) {
	doOAuthLogin(
		OAUTH_CONFIG.dbName,
		requestId,
		identifier,
		'https://' + OAUTH_CONFIG.webDNS + '/index.html',
		autherr,
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
			var button = document.createElement('button');
			var oauthWrapper = document.getElementById('inner');
			var providerName = getIdentityProviderName();

			button.innerHTML = 'Member Login';
			button.style.width = '350px';
			button.style.height = '60px';
			button.style.textAlign = 'center';
			button.dataset.provider = providerInfo;
			button.onclick = function () {
				showOAuthLogin(providerName);
			};

			oauthWrapper.appendChild(button);

			if (shouldAutoStartOAuth()) {
				showOAuthLogin(providerName);
			}
		}
	});
}
